"""Observe/decide/act/write-back workflow loop."""

from collections.abc import Callable, Mapping
from typing import Any

from app.runtime.orchestrator import decide_next_step
from app.runtime.session import WorkflowSession


def run_workflow(session: WorkflowSession, observe: Callable[[], Mapping[str, Any]],
				act: Callable[[str, Mapping[str, Any]], Mapping[str, Any] | None],
				model_decider: Callable[[Mapping[str, Any]], Any] | None = None,
				trace_recorder: Callable[..., Any] | None = None) -> WorkflowSession:
	"""Run bounded state transitions and keep every transition versioned."""
	for _ in range(session.max_steps):
		if session.status != "running":
			break
		state = dict(observe())
		decision = decide_next_step(state, model_decider)
		input_version = session.state_version
		if decision.step == "finish":
			session.advance("finish", {"reason": decision.reason}, "completed", "学习流程已完成")
			if trace_recorder:
				trace_recorder(agent="secretary", tool_calls=[], input_summary=decision.reason,
					output_summary="学习流程已完成", evidence_ids=[], state_version=session.state_version,
					status="completed", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		result = dict(act(decision.step, state) or {})
		if result.get("status") == "waiting":
			session.advance(decision.step, result, "running", result.get("nextAction"))
			if trace_recorder:
				trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
					input_summary=decision.reason, output_summary=result.get("nextAction", "waiting"),
					evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
					status="waiting", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		if result.get("status") == "error":
			session.advance("error", result, "error", result.get("message", "workflow step failed"))
			if trace_recorder:
				trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
					input_summary=decision.reason, output_summary=result.get("message", "workflow step failed"),
					evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
					status="error", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		session.advance(decision.step, result)
		if trace_recorder:
			trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
				input_summary=decision.reason, output_summary=str(result),
				evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
				status="completed", session_id=session.session_id, step_id=f"step-{input_version}",
				input_state_version=input_version, output_state_version=session.state_version)
	else:
		session.advance("max_steps", {}, "error", "已达到工作流步数上限")
		if trace_recorder:
			trace_recorder(agent="secretary", tool_calls=[], input_summary="工作流步数上限",
				output_summary="已达到工作流步数上限", evidence_ids=[], state_version=session.state_version,
				status="error", session_id=session.session_id, step_id=f"step-{session.state_version}",
				input_state_version=session.state_version - 1,
				output_state_version=session.state_version)
	return session
