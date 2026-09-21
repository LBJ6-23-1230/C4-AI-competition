"""Trace persistence helpers that keep internal model reasoning out of events."""

from datetime import datetime, timezone
from typing import Any

from app.domain.trace import TraceEvent
from app.repositories.repository import Repository


class EventStore:
	"""Append-only view over trace events backed by the repository boundary."""

	def __init__(self, repository: Repository) -> None:
		self.repository = repository

	def append(self, trace_id: str, event: TraceEvent) -> dict[str, Any]:
		trace = self.repository.get("traces", trace_id) or {"traceId": trace_id, "events": []}
		events = list(trace.get("events", []))
		events.append(event.to_dict())
		trace["traceId"] = trace_id
		trace["events"] = events
		self.repository.save("traces", trace_id, trace)
		return event.to_dict()

	def list(self, trace_id: str) -> list[dict[str, Any]]:
		trace = self.repository.get("traces", trace_id)
		return list(trace.get("events", [])) if trace else []


def append_trace_event(repository: Repository, trace_id: str, *, agent: str,
					 tool_calls: list[str], input_summary: str, output_summary: str,
					 evidence_ids: list[str], state_version: int, status: str,
					 session_id: str | None = None, step_id: str | None = None,
					 input_state_version: int | None = None,
					 output_state_version: int | None = None) -> dict[str, Any]:
	event = TraceEvent(agent, tool_calls, input_summary, output_summary, evidence_ids,
		state_version, datetime.now(timezone.utc), status, session_id, trace_id, step_id,
		input_state_version, output_state_version)
	return EventStore(repository).append(trace_id, event)
