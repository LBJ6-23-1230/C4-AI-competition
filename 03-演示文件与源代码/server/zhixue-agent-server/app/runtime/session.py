"""Durable workflow session state."""

from dataclasses import dataclass, field
from typing import Any


@dataclass
class WorkflowSession:
	session_id: str
	goal: str
	user_id: str = "demo-user"
	status: str = "running"
	current_step: str = "diagnosis"
	state_version: int = 1
	max_steps: int = 6
	final_action: str | None = None
	state: dict[str, Any] = field(default_factory=dict)

	def __post_init__(self) -> None:
		if not self.session_id or not self.goal.strip():
			raise ValueError("session_id and goal are required")
		if self.state_version < 1 or self.max_steps < 1:
			raise ValueError("session version and max_steps must be positive")

	def advance(self, step: str, state: dict[str, Any] | None = None,
				status: str = "running", final_action: str | None = None) -> None:
		self.current_step = step
		self.status = status
		self.final_action = final_action
		self.state_version += 1
		if state:
			self.state.update(state)

	def to_dict(self) -> dict[str, Any]:
		return {
			"sessionId": self.session_id, "goal": self.goal, "userId": self.user_id,
			"status": self.status, "currentStep": self.current_step,
			"currentAgent": self.current_step, "stateVersion": self.state_version,
			"maxSteps": self.max_steps, "finalAction": self.final_action,
			"state": dict(self.state),
		}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "WorkflowSession":
		return cls(data["sessionId"], data["goal"], data.get("userId", "demo-user"),
				data.get("status", "running"), data.get("currentStep", "diagnosis"),
				data.get("stateVersion", 1), data.get("maxSteps", 6), data.get("finalAction"),
				dict(data.get("state", {})))
