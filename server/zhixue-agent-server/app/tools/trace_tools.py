"""Trace persistence helpers that keep internal model reasoning out of events."""

import threading
from datetime import datetime, timezone
from typing import Any

from app.domain.trace import TraceEvent
from app.repositories.repository import Repository

# `EventStore.append` 是"读整个 trace → 追加一条 → 写回"，而 Flask 默认多线程。
# `JsonRepository` 的 `save()` 自己有写锁，但**锁不住这段读—改—写序列**：
# 两个并发 append 会各读一份旧 events、各追加一条、再各写一份，
# 后写的把先写的整条覆盖掉 —— 事件静默丢失。
# 实测：48 次并发 append 只留下 5 条事件。而 trace 是答辩里
# "Agent 决策可追溯"的核心证据，`/api/v1/experiments/snapshot` 的统计也基于它。
# 追加是纯内存 + 微秒级写盘，串行化的代价可忽略。
_TRACE_LOCK = threading.RLock()


class EventStore:
	"""Append-only view over trace events backed by the repository boundary."""

	def __init__(self, repository: Repository) -> None:
		self.repository = repository

	def append(self, trace_id: str, event: TraceEvent) -> dict[str, Any]:
		# 读—改—写必须在同一临界区内完成，否则并发追加会互相覆盖（丢事件）。
		with _TRACE_LOCK:
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
