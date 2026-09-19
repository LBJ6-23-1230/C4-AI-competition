"""Learning plan domain model."""

from dataclasses import dataclass, field
from typing import Any

from datetime import datetime

from app.domain.profile import _parse_datetime


@dataclass
class PlanHistory:
	old_version: int
	new_version: int
	changed_tasks: list[dict[str, Any]]
	reason: str
	evidence_ids: list[str]
	timestamp: datetime

	def __post_init__(self) -> None:
		if self.old_version < 1 or self.new_version < 1 or self.new_version <= self.old_version:
			raise ValueError("plan versions must increase")
		self.timestamp = _parse_datetime(self.timestamp)

	def to_dict(self) -> dict[str, Any]:
		return {"oldVersion": self.old_version, "newVersion": self.new_version,
				"changedTasks": [dict(task) for task in self.changed_tasks], "reason": self.reason,
				"evidenceIds": list(self.evidence_ids), "timestamp": self.timestamp.isoformat()}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "PlanHistory":
		return cls(data["oldVersion"], data["newVersion"], list(data.get("changedTasks", [])),
				data.get("reason", ""), list(data.get("evidenceIds", [])), data["timestamp"])


@dataclass
class LearningPlan:
	plan_id: str
	version: int
	tasks: list[dict[str, Any]] = field(default_factory=list)
	generated_from_profile_version: int = 1
	reason: str = ""

	def __post_init__(self) -> None:
		if not self.plan_id:
			raise ValueError("plan_id is required")
		if self.version < 1:
			raise ValueError("version must be positive")
		if self.generated_from_profile_version < 1:
			raise ValueError("generated_from_profile_version must be positive")
		if not isinstance(self.tasks, list):
			raise TypeError("tasks must be a list")
		if any(not isinstance(task, dict) for task in self.tasks):
			raise TypeError("each task must be a dictionary")

	def next_version(self) -> int:
		self.version += 1
		return self.version

	def to_dict(self) -> dict[str, Any]:
		return {
			"planId": self.plan_id,
			"version": self.version,
			"tasks": [dict(task) for task in self.tasks],
			"generatedFromProfileVersion": self.generated_from_profile_version,
			"reason": self.reason,
		}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "LearningPlan":
		return cls(
			plan_id=data["planId"],
			version=data["version"],
			tasks=list(data.get("tasks", [])),
			generated_from_profile_version=data["generatedFromProfileVersion"],
			reason=data.get("reason", ""),
		)
