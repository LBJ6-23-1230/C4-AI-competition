"""Assessment domain models."""

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class AssessmentResult:
	"""Structured grading output consumed by mastery and replanning tools."""

	score: float
	per_knowledge_accuracy: dict[str, float]
	error_types: list[str] = field(default_factory=list)
	old_mastery: int | float = 0
	suggested_new_mastery: int | float = 0
	exercise_result_id: str | None = None
	#: 按**知识点**分别算出的建议掌握度：`{knowledgePointId: newScore}`。
	#:
	#: 为什么需要它：`suggested_new_mastery` 是按**整卷总分**算的一个标量，
	#: 而一次提交可能覆盖多个知识点。若把标量写给全部知识点，
	#: "掌握度更新"就会写到与本次作答无关的知识点上（实测：
	#: 提交 graph-algorithm 的题集，响应却称 binary-tree-postorder 42→46，
	#: 而画像里该知识点仍是 42 —— 响应与落盘互相矛盾）。
	#: 落盘时优先用本字段；为空则回退标量，保证既有调用方行为不变。
	per_knowledge_mastery: dict[str, int | float] = field(default_factory=dict)

	def __post_init__(self) -> None:
		if not 0 <= self.score <= 100:
			raise ValueError("score must be between 0 and 100")
		if not 0 <= self.old_mastery <= 100:
			raise ValueError("old_mastery must be between 0 and 100")
		if not 0 <= self.suggested_new_mastery <= 100:
			raise ValueError("suggested_new_mastery must be between 0 and 100")
		for point, value in self.per_knowledge_mastery.items():
			if not 0 <= value <= 100:
				raise ValueError(
					f"per_knowledge_mastery[{point}] must be between 0 and 100")

	def dominant_knowledge_point(self) -> str:
		"""被判分题量最多的知识点；并列时取字典序最小，保证确定性。

		用于给"本次提交主要练的是哪个知识点"一个**可解释**的答案，
		取代原先硬编码的 `"binary-tree-postorder"`。
		没有任何被判分题时返回 `"unknown"`。
		"""
		if not self.per_knowledge_accuracy:
			return "unknown"
		return sorted(
			self.per_knowledge_accuracy.items(),
			key=lambda item: (-item[1], item[0]),
		)[0][0]

	def to_dict(self) -> dict[str, Any]:
		# 刻意**不**输出 `per_knowledge_mastery`：它是内部写入用数据，
		# 契约 `AssessmentResult` 未声明该字段，多输出会破坏契约一致性。
		return {
			"score": self.score,
			"perKnowledgeAccuracy": dict(self.per_knowledge_accuracy),
			"errorTypes": list(self.error_types),
			"oldMastery": self.old_mastery,
			"suggestedNewMastery": self.suggested_new_mastery,
			"exerciseResultId": self.exercise_result_id,
		}
