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
	#: 计划归属。**必须随 `to_dict()` 一起落盘** —— 计划的重排是"整条覆盖"写回
	#: （`exercises.py` / `workflows.py` 都是 save 同一条 key），一旦 `to_dict()`
	#: 不带它，记录里的 `userId` 就会消失；而读侧 `plans.py` 用的是
	#: `plan.get("userId", "demo-user")` —— 键不存在时默认值生效，于是记录被
	#: 当成演示身份，**真实账号做完一次练习就读不到自己的计划**（GET /plans/current → 404）。
	#:
	#: 空串表示"未设置"，此时 `to_dict()` **不写该键**，让读侧的默认值口径保持不变
	#: （既有演示数据没有该键，不能被写成 `""` 而失配）。
	user_id: str = ""

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
		data = {
			"planId": self.plan_id,
			"version": self.version,
			"tasks": [dict(task) for task in self.tasks],
			"generatedFromProfileVersion": self.generated_from_profile_version,
			"reason": self.reason,
		}
		# 仅在确实有归属时才写该键：空串会让读侧的 `.get("userId", "demo-user")`
		# 拿到 `""` 而不是默认值，反而把演示身份也弄失配。
		if self.user_id:
			data["userId"] = self.user_id
		return data

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "LearningPlan":
		return cls(
			plan_id=data["planId"],
			version=data["version"],
			tasks=list(data.get("tasks", [])),
			generated_from_profile_version=data["generatedFromProfileVersion"],
			reason=data.get("reason", ""),
			user_id=data.get("userId", ""),
		)
