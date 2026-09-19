"""Learner profile domain models."""

from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any


def _parse_date(value: date | str | None) -> date | None:
	if value is None or isinstance(value, date):
		return value
	if isinstance(value, str):
		try:
			return date.fromisoformat(value)
		except ValueError as exc:
			raise ValueError("exam_date must be an ISO date") from exc
	raise TypeError("exam_date must be a date, ISO date string, or None")


def _parse_datetime(value: datetime | str) -> datetime:
	if isinstance(value, datetime):
		return value
	if isinstance(value, str):
		try:
			return datetime.fromisoformat(value)
		except ValueError as exc:
			raise ValueError("last_updated must be an ISO datetime") from exc
	raise TypeError("last_updated must be a datetime or ISO datetime string")


@dataclass
class KnowledgeMastery:
	"""掌握度快照；实际修改应由 update_mastery 工具完成。"""

	knowledge_point_id: str
	mastery_score: int | float
	confidence: int | float
	last_updated: datetime
	knowledge_point_name: str = ""

	def __post_init__(self) -> None:
		if not self.knowledge_point_id:
			raise ValueError("knowledge_point_id is required")
		if not self.knowledge_point_name:
			self.knowledge_point_name = self.knowledge_point_id
		if not 0 <= self.mastery_score <= 100:
			raise ValueError("mastery_score must be between 0 and 100")
		if not 0 <= self.confidence <= 100:
			raise ValueError("confidence must be between 0 and 100")
		self.last_updated = _parse_datetime(self.last_updated)

	def to_dict(self) -> dict[str, Any]:
		return {
			"knowledgePointId": self.knowledge_point_id,
			"knowledgePointName": self.knowledge_point_name,
			"masteryScore": self.mastery_score,
			"confidence": self.confidence,
			"lastUpdated": self.last_updated.isoformat(),
		}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "KnowledgeMastery":
		return cls(
			knowledge_point_id=data["knowledgePointId"],
			knowledge_point_name=data.get("knowledgePointName", data["knowledgePointId"]),
			mastery_score=data["masteryScore"],
			confidence=data["confidence"],
			last_updated=data["lastUpdated"],
		)


@dataclass
class LearnerProfile:
	user_id: str
	goal: str
	exam_date: date | None
	free_time_slots: list[str] = field(default_factory=list)
	profile_version: int = 1
	mastery: list[KnowledgeMastery] = field(default_factory=list)

	def __post_init__(self) -> None:
		if not self.user_id:
			raise ValueError("user_id is required")
		if not self.goal:
			raise ValueError("goal is required")
		if self.profile_version < 1:
			raise ValueError("profile_version must be positive")
		self.exam_date = _parse_date(self.exam_date)

	def advance_version(self) -> int:
		self.profile_version += 1
		return self.profile_version

	def to_dict(self) -> dict[str, Any]:
		return {
			"userId": self.user_id,
			"goal": self.goal,
			"examDate": self.exam_date.isoformat() if self.exam_date else None,
			"freeTimeSlots": list(self.free_time_slots),
			"profileVersion": self.profile_version,
			"mastery": [item.to_dict() for item in self.mastery],
		}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "LearnerProfile":
		return cls(
			user_id=data["userId"],
			goal=data["goal"],
			exam_date=data.get("examDate"),
			free_time_slots=list(data.get("freeTimeSlots", [])),
			profile_version=data.get("profileVersion", 1),
			mastery=[KnowledgeMastery.from_dict(item) for item in data.get("mastery", [])],
		)
