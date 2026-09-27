"""Transparent five-factor learning priority engine."""

from dataclasses import dataclass
from typing import Any

from config import PRIORITY_WEIGHTS


@dataclass(frozen=True)
class PriorityResult:
	knowledge_point_id: str
	total_score: float
	factors: dict[str, dict[str, float]]
	reason: str
	# 知识点**中文名**。计划任务的展示名取自它。
	#
	# ⚠️ 为什么必须显式带着它：`to_dict()` 一旦缺这个字段，`PlannerAgent` 里那句
	# `item.get("knowledgePointName") or item["knowledgePointId"]` 就会**静默回落到 id**
	# —— 于是计划页出现 `binary-tree-traversal`、`graph-algorithm` 这类**内部英文标识**。
	# 题库命中（用映射表匹配到的）知识点 id 都是英文，只有兜底分支拿课程名当 id
	# 的那几个才**碰巧**是中文，所以这个缺陷以前一直没暴露。
	# 与「内部英文标识不该直接给用户看」是同一条纪律。
	knowledge_point_name: str = ""

	def to_dict(self) -> dict[str, Any]:
		factor_list = [
			{"name": name, **values}
			for name, values in self.factors.items()
		]
		return {
			"knowledgePointId": self.knowledge_point_id,
			"knowledgePointName": self.knowledge_point_name,
			"score": self.total_score,
			"totalScore": self.total_score,
			"factors": dict(self.factors),
			"factorDetails": factor_list,
			"reason": self.reason,
		}


def _number(value: Any, default: float = 0) -> float:
	try:
		return max(0.0, min(100.0, float(value)))
	except (TypeError, ValueError):
		return default


def calculate_learning_priority(knowledge_points: list[dict[str, Any]],
							context: dict[str, Any] | None = None) -> list[dict[str, Any]]:
	"""Rank knowledge points using mastery, errors, importance, urgency and prerequisites."""
	context = context or {}
	days_left = _number(context.get("daysLeft", 30), 30)
	urgency = max(0.0, min(100.0, (30 - days_left) / 30 * 100))
	# 因子键 → 用户看得懂的名字。
	#
	# ⚠️ 下面的 `reason` 会**直接显示在计划页 / 首页**上。原实现把内部键名
	# （`urgency`、`errorIntensity` …）原样拼进句子，用户看到的是
	# 「urgency 因子值为 0.83，应优先安排针对性练习」—— 内部英文标识不该给用户看
	# （实测反馈：「有的东西不要写给用户直接看」）。
	factor_labels = {
		"mastery": "掌握度",
		"errorIntensity": "错误强度",
		"importance": "课程重要性",
		"urgency": "时间紧迫度",
		"prerequisiteImpact": "先修影响",
	}
	results: list[PriorityResult] = []
	for item in knowledge_points:
		mastery = _number(item.get("masteryScore", 0))
		factor_values = {
			"mastery": round((100 - mastery) / 100, 4),
			"errorIntensity": round(_number(item.get("errorIntensity", item.get("errorRate", 0))) / 100, 4),
			"importance": round(_number(item.get("importance", 50)) / 100, 4),
			"urgency": round(_number(item.get("urgency", urgency)) / 100, 4),
			"prerequisiteImpact": round(_number(item.get("prerequisiteImpact", 0)) / 100, 4),
		}
		factors = {
			name: {
				"value": value,
				"weight": PRIORITY_WEIGHTS[name],
				"contribution": round(value * PRIORITY_WEIGHTS[name], 4),
			}
			for name, value in factor_values.items()
		}
		score = round(sum(item["contribution"] for item in factors.values()), 4)
		strongest = max(factor_values, key=factor_values.get)
		reason = (f"{factor_labels.get(strongest, strongest)} 因子值为 "
			f"{factor_values[strongest]:.2f}，应优先安排针对性练习")
		# 名字必须一路带到 `to_dict()` —— 见 `PriorityResult.knowledge_point_name` 的说明。
		results.append(PriorityResult(item["knowledgePointId"], score, factors, reason,
			str(item.get("knowledgePointName") or "")))
	return [result.to_dict() for result in sorted(results, key=lambda value: value.total_score, reverse=True)]