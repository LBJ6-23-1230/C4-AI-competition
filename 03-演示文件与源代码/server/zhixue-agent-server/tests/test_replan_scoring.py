# -*- coding: utf-8 -*-
"""回归测试：重规划的时长必须随得分分级变化。

## 背景（真实缺陷，2026-09-23 由前端同学实测发现）

原先 `replan_learning_path` 的时长改动是**固定 ±15 分钟**，
只看"掌握度是否低于阈值"，**完全没读 assessmentScore**。实测四种正确率：

    全对   100.00  → [30, 30]      （不触发重规划）
    对2错1  66.67  → [45, 15]
    对1错2  33.33  → [45, 15]      ← 与上一行完全相同
    全错     0.00  → [45, 15]      ← 也一样

即"只要不是全对，结果都一样" —— 重规划没有按错误程度给薄弱点分级加时。

修复后要求：
  · 薄弱点任务时长随得分单调变化（得分越低越长）
  · **演示基线不变**：得分 66.67 仍然得到 [45, 15]
  · 全对不触发重规划

这个测试同时锁住"基线不变"与"分级生效"两件事 ——
只锁前者会放过原缺陷，只锁后者会打破文档与 PPT 引用的基线。
"""
from __future__ import annotations

from app.tools.plan_tools import _distribute_durations, replan_learning_path

PLAN = {
	"planId": "plan-demo-001",
	"version": 1,
	"tasks": [
		{"taskId": "task-postorder", "knowledgePointId": "binary-tree-postorder",
		 "status": "pending", "durationMinutes": 30},
		{"taskId": "task-graph", "knowledgePointId": "graph-algorithm",
		 "status": "pending", "durationMinutes": 30},
	],
}


def _durations(score: float) -> list[int]:
	result = replan_learning_path(dict(PLAN), {
		"masteryScore": 58, "knowledgePointId": "binary-tree-postorder",
		"repeatedError": score < 80, "assessmentScore": score})
	return [t["durationMinutes"] for t in result["plan"]["tasks"]]


def test_demo_baseline_durations_unchanged():
	"""演示基线：得分 66.67 → [45, 15]（文档与 PPT 引用这个值）。"""
	assert _durations(66.67) == [45, 15]


def test_durations_scale_with_score():
	"""得分越低，薄弱点任务分到越多（这是原先缺失的那一维）。

	注意方向：下面的 scores 是**递减**的（66.67 → 0），
	所以对应的 weak 时长应当是**递增**的（45 → 55）。
	"""
	scores = (66.67, 50.0, 33.33, 20.0, 0.0)
	weak = [_durations(s)[0] for s in scores]
	assert weak == sorted(weak), "薄弱点时长应随得分下降而上升，实际 %s" % weak
	assert weak[0] < weak[-1], "全错时的薄弱点时长必须大于 2 对 1 错时"
	# 至少要有 3 种不同结果，否则等于"不管错多少都一样"
	assert len(set(weak)) >= 3, "不同得分应产生多种时长，实际只有 %s" % sorted(set(weak))


def test_other_task_keeps_floor():
	"""另一任务不能被压到 _EASY_TASK_MINUTES 以下。"""
	for score in (66.67, 50.0, 33.33, 0.0):
		assert _durations(score)[1] >= 15


def test_perfect_score_does_not_replan():
	"""全对不触发重规划：时长与版本都不变。"""
	result = replan_learning_path(dict(PLAN), {
		"masteryScore": 71, "knowledgePointId": "binary-tree-postorder",
		"repeatedError": False, "assessmentScore": 100.0})
	assert result["changedTasks"] == []
	assert result["plan"]["version"] == 1
	assert [t["durationMinutes"] for t in result["plan"]["tasks"]] == [30, 30]


def test_missing_score_falls_back_to_fixed_bump():
	"""不传 assessmentScore 时回退到固定 ±15（保持向后兼容）。"""
	result = replan_learning_path(dict(PLAN), {
		"masteryScore": 58, "knowledgePointId": "binary-tree-postorder",
		"repeatedError": True})
	assert [t["durationMinutes"] for t in result["plan"]["tasks"]] == [45, 15]


def test_distribution_returns_none_when_not_applicable():
	"""找不到"一弱一强"两个可分配任务时返回 None，交给调用方回退。"""
	assert _distribute_durations(PLAN["tasks"], "not-a-knowledge-point", 66.67) is None
	one_task = [{"taskId": "t1", "knowledgePointId": "kp", "status": "pending",
				 "durationMinutes": 30}]
	assert _distribute_durations(one_task, "kp", 66.67) is None
	assert _distribute_durations(PLAN["tasks"], "binary-tree-postorder", None) is None


def test_reason_records_score():
	"""reason 里要留下得分，便于排查与展示依据。"""
	result = replan_learning_path(dict(PLAN), {
		"masteryScore": 58, "knowledgePointId": "binary-tree-postorder",
		"repeatedError": True, "assessmentScore": 33.33})
	assert "score_33.33" in result["plan"]["reason"]
