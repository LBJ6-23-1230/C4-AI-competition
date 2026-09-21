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

	def __post_init__(self) -> None:
		if not 0 <= self.score <= 100:
			raise ValueError("score must be between 0 and 100")
		if not 0 <= self.old_mastery <= 100:
			raise ValueError("old_mastery must be between 0 and 100")
		if not 0 <= self.suggested_new_mastery <= 100:
			raise ValueError("suggested_new_mastery must be between 0 and 100")

	def to_dict(self) -> dict[str, Any]:
		return {
			"score": self.score,
			"perKnowledgeAccuracy": dict(self.per_knowledge_accuracy),
			"errorTypes": list(self.error_types),
			"oldMastery": self.old_mastery,
			"suggestedNewMastery": self.suggested_new_mastery,
			"exerciseResultId": self.exercise_result_id,
		}
