"""Exercise domain models shared by the exercise tools and API."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass(frozen=True)
class Exercise:
	"""A question exposed to learners without its answer key."""

	exercise_id: str
	knowledge_point_id: str
	knowledge_point_name: str
	difficulty: str
	stem: str
	options: list[str] = field(default_factory=list)
	source: str = "demo"

	def __post_init__(self) -> None:
		if not self.exercise_id:
			raise ValueError("exercise_id is required")
		if not self.knowledge_point_id:
			raise ValueError("knowledge_point_id is required")
		if self.difficulty not in {"easy", "medium", "hard"}:
			raise ValueError("difficulty must be easy, medium, or hard")
		if not self.stem:
			raise ValueError("stem is required")
		if len(self.options) < 2:
			raise ValueError("options must contain at least two items")

	def to_dict(self) -> dict[str, Any]:
		return {
			"exerciseId": self.exercise_id,
			"knowledgePointId": self.knowledge_point_id,
			"knowledgePointName": self.knowledge_point_name,
			"difficulty": self.difficulty,
			"stem": self.stem,
			"options": list(self.options),
			"source": self.source,
		}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "Exercise":
		return cls(
			exercise_id=data["exerciseId"],
			knowledge_point_id=data["knowledgePointId"],
			knowledge_point_name=data.get("knowledgePointName", data["knowledgePointId"]),
			difficulty=data["difficulty"],
			stem=data["stem"],
			options=list(data.get("options", [])),
			source=data.get("source", "demo"),
		)


@dataclass(frozen=True)
class ExerciseSet:
	set_id: str
	exercises: list[Exercise] = field(default_factory=list)

	def __post_init__(self) -> None:
		if not self.set_id:
			raise ValueError("set_id is required")
		if not self.exercises:
			raise ValueError("exercises must not be empty")
		if len({exercise.exercise_id for exercise in self.exercises}) != len(self.exercises):
			raise ValueError("exercise ids must be unique")

	def to_dict(self) -> dict[str, Any]:
		return {"setId": self.set_id, "exercises": [item.to_dict() for item in self.exercises]}


@dataclass(frozen=True)
class ExerciseResult:
	result_id: str
	set_id: str
	answers: dict[str, str]
	score: float
	completed_at: datetime

	def __post_init__(self) -> None:
		if not self.result_id:
			raise ValueError("result_id is required")
		if not self.set_id:
			raise ValueError("set_id is required")
		if not 0 <= self.score <= 100:
			raise ValueError("score must be between 0 and 100")

	def to_dict(self) -> dict[str, Any]:
		return {
			"resultId": self.result_id,
			"setId": self.set_id,
			"answers": dict(self.answers),
			"score": self.score,
			"completedAt": self.completed_at.isoformat(),
		}
