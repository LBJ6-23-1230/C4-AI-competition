"""Deterministic secretary decisions with optional model output."""

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class WorkflowDecision:
	step: str
	reason: str
	used_fallback: bool = True


_VALID_STEPS = {"diagnosis", "planner", "exercise", "assessment", "finish"}


def _is_actionable(step: str, state: Mapping[str, Any]) -> bool:
	if step == "diagnosis":
		return "profile" not in state or state.get("profile") is None
	if step == "planner":
		return ("plan" not in state or state.get("plan") is None
			or bool(state.get("needReplan")))
	if step == "exercise":
		return ("plan" in state and state.get("plan") is not None
			and not state.get("pendingSubmission") and not state.get("awaitingAnswers"))
	if step == "assessment":
		return bool(state.get("pendingSubmission"))
	if step == "finish":
		return "assessment" in state and not state.get("pendingSubmission")
	return False


def fallback_decision(state: Mapping[str, Any]) -> WorkflowDecision:
	"""Choose the next owner from observable state, never from hidden model text."""
	if "profile" not in state or state.get("profile") is None:
		return WorkflowDecision("diagnosis", "profile is missing")
	if "assessment" in state and state.get("needReplan"):
		return WorkflowDecision("planner", "assessment requires replanning")
	if "plan" not in state or state.get("plan") is None:
		return WorkflowDecision("planner", "plan is missing")
	if state.get("pendingSubmission"):
		return WorkflowDecision("assessment", "submission is waiting for grading")
	if state.get("assessment"):
		return WorkflowDecision("finish", "assessment completed")
	return WorkflowDecision("exercise", "plan has an available exercise step")


def decide_next_step(state: Mapping[str, Any], model_decider: Callable[[Mapping[str, Any]], Any] | None = None) -> WorkflowDecision:
	"""Accept only a valid structured model decision; otherwise use the fallback."""
	if model_decider is not None:
		try:
			result = model_decider(state)
			step = result.get("step") if isinstance(result, Mapping) else None
			if step in _VALID_STEPS and _is_actionable(step, state):
				return WorkflowDecision(step, str(result.get("reason", "model decision")), False)
		except Exception:
			pass
	return fallback_decision(state)
