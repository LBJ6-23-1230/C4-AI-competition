"""Workflow trace event domain model."""

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from app.domain.profile import _parse_datetime


@dataclass
class TraceEvent:
	agent: str
	tool_calls: list[str]
	input_summary: str
	output_summary: str
	evidence_ids: list[str]
	state_version: int
	timestamp: datetime
	status: str
	session_id: str | None = None
	trace_id: str | None = None
	step_id: str | None = None
	input_state_version: int | None = None
	output_state_version: int | None = None

	def __post_init__(self) -> None:
		if not self.agent or self.state_version < 0 or not self.status:
			raise ValueError("trace event fields are invalid")
		if self.input_state_version is not None and self.input_state_version < 0:
			raise ValueError("input_state_version must be non-negative")
		if self.output_state_version is not None and self.output_state_version < 0:
			raise ValueError("output_state_version must be non-negative")
		self.timestamp = _parse_datetime(self.timestamp)

	def to_dict(self) -> dict[str, Any]:
		return {"agent": self.agent, "toolCalls": list(self.tool_calls), "inputSummary": self.input_summary,
				"outputSummary": self.output_summary, "evidenceIds": list(self.evidence_ids),
				"stateVersion": self.state_version, "timestamp": self.timestamp.isoformat(), "status": self.status,
				"sessionId": self.session_id, "traceId": self.trace_id, "stepId": self.step_id,
				"inputStateVersion": self.input_state_version, "outputStateVersion": self.output_state_version}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "TraceEvent":
		return cls(data["agent"], list(data.get("toolCalls", [])), data.get("inputSummary", ""),
				data.get("outputSummary", ""), list(data.get("evidenceIds", [])), data["stateVersion"],
				data["timestamp"], data["status"], data.get("sessionId"), data.get("traceId"),
				data.get("stepId"), data.get("inputStateVersion"), data.get("outputStateVersion"))
