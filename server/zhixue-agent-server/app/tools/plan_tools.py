"""Deterministic plan version and diff helpers."""

from datetime import datetime, timezone
from typing import Any

from app.domain.plan import PlanHistory


_BASELINE_DURATIONS = {"task-postorder": 30, "task-graph": 30}
_FOCUS_BUMP_MINUTES = 15
_EASY_TASK_MINUTES = 15

#: 薄弱点任务的时长如何随得分变化。
#:
#: 为什么需要这组常量
#: ----------------
#: 原先的时长改动是**固定 ±15 分钟**，只看"掌握度是否低于阈值"，
#: **完全没读 assessmentScore**。实测四种正确率：
#:
#:     全对   100.00  → [30, 30]      （不触发重规划）
#:     对2错1  66.67  → [45, 15]
#:     对1错2  33.33  → [45, 15]      ← 与上一行完全相同
#:     全错     0.00  → [45, 15]      ← 也一样
#:
#: 即"只要不是全对，结果都一样"。由前端同学实测发现，属真实缺陷：
#: 重规划没有按错误程度给薄弱点**分级**加时。
#:
#: 现在改成：得分越低，薄弱点任务分到越多，另一任务相应减少。
#: 两个端点不是随手取的 —— 它们让**演示基线保持不变**：
#:
#:     得分 66.67 → 薄弱点 40 + (80−66.67)/80 × 15 = 42.5 → 43 分钟
#:                 另一任务 60 − 43 = 17 分钟
#:
#: ⚠️ 但基线要求是 **[45, 15]**（文档与 PPT 都引用它），
#: 所以专门让 66.67 落在 45 上（见下方 _WEAK_AT_BASELINE）。
#: 这样既修好了"不随得分变化"，又不打破既有基线。
_WEAK_MIN_AT_LOW_SCORE = 55.0    # 得分 0 时薄弱点拿到的分钟数
_WEAK_MIN_AT_ZERO_GAP = 40.0     # 得分 80（触发重规划的临界）时的分钟数
_WEAK_AT_BASELINE = 45.0         # 得分 66.67（演示基线）时的分钟数 —— 必须与旧行为一致
_BASELINE_SCORE = 66.67
_SCORE_TRIGGER = 80.0            # assessmentScore < 80 才算 repeatedError


def _weak_minutes_for_score(score: float) -> float:
	"""按得分算薄弱点该分多少分钟。

	分段线性：
	    · score >= 80（不触发重规划的区间）→ 40
	    · 66.67（演示基线）               → **45**（与旧行为一致，保住基线）
	    · 0                               → 55

	在 [0, 66.67] 与 [66.67, 80] 两段各自线性插值，保证单调。
	"""
	if score >= _SCORE_TRIGGER:
		return _WEAK_MIN_AT_ZERO_GAP
	if score >= _BASELINE_SCORE:
		# 66.67 → 80 区间：45 → 40
		ratio = (score - _BASELINE_SCORE) / (_SCORE_TRIGGER - _BASELINE_SCORE)
		return _WEAK_AT_BASELINE + ratio * (_WEAK_MIN_AT_ZERO_GAP - _WEAK_AT_BASELINE)
	# 0 → 66.67 区间：55 → 45
	ratio = score / _BASELINE_SCORE
	return _WEAK_MIN_AT_LOW_SCORE + ratio * (_WEAK_AT_BASELINE - _WEAK_MIN_AT_LOW_SCORE)


def should_replan(state: dict[str, Any]) -> dict[str, Any]:
	reasons: list[str] = []
	if state.get("masteryScore") is not None and float(state["masteryScore"]) < 60:
		reasons.append("mastery_below_threshold")
	if state.get("incompleteTasks", 0) > 0:
		reasons.append("incomplete_tasks")
	if state.get("repeatedError", False):
		reasons.append("repeated_error")
	return {"needReplan": bool(reasons), "reasons": reasons}


def _distribute_durations(tasks: list[dict[str, Any]], target_id: Any,
						  score: float | None) -> dict[str, int] | None:
	"""按得分把时间在「薄弱点任务」与「另一待办任务」之间重新分配。

	返回 {taskId: 新时长}；条件不满足时返回 None（调用方回退到固定 ±15）。

	设计约束（三条都要满足）：
	  1. **演示基线不变** —— S=66.67 必须仍然得到 [45, 15]，否则文档与 PPT 对不上
	  2. **错得越多，薄弱点拿越多** —— 这是原先缺失的那一维
	  3. **薄弱点的时间不被另一任务挤掉** —— 见下方注释

	⚠️ 这里踩过一个坑：最初写成"总时长固定 60，strong 触底 15 后回算 weak"，
	结果得分 0 时 weak 算出来是 75、strong 触底 15，**回算又把 weak 压回 45** ——
	三种得分全变成 [45, 15]，看起来和没修一样。现在改为
	**先按得分定 weak，再让另一任务取剩余**，总时长允许增长，就不再互相挤。
	"""
	if score is None:
		return None
	weak = next((t for t in tasks if t.get("knowledgePointId") == target_id), None)
	strong = next((t for t in tasks
				   if t is not weak and t.get("status") == "pending"), None)
	if weak is None or strong is None:
		return None

	weak_id, strong_id = weak.get("taskId"), strong.get("taskId")
	if weak_id is None or strong_id is None or weak_id == strong_id:
		return None

	weak_baseline = _BASELINE_DURATIONS.get(weak_id, weak.get("durationMinutes", 30))
	strong_baseline = _BASELINE_DURATIONS.get(strong_id, strong.get("durationMinutes", 30))

	# ① 薄弱点：按得分算（得分越低拿越多）
	weak_minutes = int(round(_weak_minutes_for_score(float(score))))
	weak_minutes = max(weak_baseline, weak_minutes)

	# ② 另一任务：把"薄弱点多拿的部分"从它身上扣
	extra = weak_minutes - weak_baseline
	strong_minutes = max(_EASY_TASK_MINUTES, strong_baseline - extra)
	return {weak_id: weak_minutes, strong_id: strong_minutes}


def replan_learning_path(old_plan: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
	decision = should_replan(state)
	if not decision["needReplan"]:
		return {"plan": dict(old_plan), "changedTasks": [], "decision": decision}
	tasks = [dict(task) for task in old_plan.get("tasks", [])]
	target_id = state.get("knowledgePointId")
	score = state.get("assessmentScore")

	# 优先走「按得分重新分配总时长」。条件不满足时回退到固定 ±15 的老逻辑。
	distribution = _distribute_durations(tasks, target_id, score)
	changed: list[dict[str, Any]] = []
	for task in tasks:
		task_id = task.get("taskId")
		if distribution is not None and task_id in distribution:
			task["durationMinutes"] = distribution[task_id]
			changed.append(dict(task))
			continue
		baseline = _BASELINE_DURATIONS.get(task_id, task.get("durationMinutes", 30))
		if task.get("knowledgePointId") == target_id:
			new_duration = baseline + _FOCUS_BUMP_MINUTES
		elif task.get("status") == "pending":
			new_duration = max(_EASY_TASK_MINUTES, baseline - _FOCUS_BUMP_MINUTES)
		else:
			new_duration = baseline
		if task.get("durationMinutes") != new_duration:
			task["durationMinutes"] = new_duration
			changed.append(dict(task))

	reasons = ";".join(decision["reasons"])
	if distribution is not None and score is not None:
		reasons = "%s;score_%s" % (reasons, ("%.2f" % float(score)).rstrip("0").rstrip("."))
	new_plan = dict(old_plan, version=old_plan.get("version", 1) + 1, tasks=tasks,
			reason=reasons)
	return {"plan": new_plan, "changedTasks": changed, "decision": decision}


def build_plan_diff(old_plan: dict[str, Any], new_plan: dict[str, Any]) -> dict[str, Any]:
	"""Return task changes between two plan versions."""
	old_tasks = {task.get("taskId", task.get("knowledgePointId")): task for task in old_plan.get("tasks", [])}
	changed_tasks = [
		dict(task) for task in new_plan.get("tasks", [])
		if old_tasks.get(task.get("taskId", task.get("knowledgePointId"))) != task
	]
	return {
		"planId": new_plan.get("planId"),
		"oldVersion": old_plan.get("version"),
		"newVersion": new_plan.get("version"),
		"changedTasks": changed_tasks,
	}


def create_plan_history(
	old_plan: dict[str, Any],
	new_plan: dict[str, Any],
	reason: str,
	evidence_ids: list[str],
) -> dict[str, Any]:
	"""Build the canonical persisted PlanHistory payload."""
	diff = build_plan_diff(old_plan, new_plan)
	history = PlanHistory(
		old_version=diff["oldVersion"],
		new_version=diff["newVersion"],
		changed_tasks=diff["changedTasks"],
		reason=reason,
		evidence_ids=evidence_ids,
		timestamp=datetime.now(timezone.utc),
	)
	return history.to_dict()
