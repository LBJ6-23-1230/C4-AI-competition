"""Deterministic plan version and diff helpers."""

from datetime import datetime, timezone
from typing import Any

from app.domain.plan import PlanHistory


_BASELINE_DURATIONS = {"task-postorder": 30, "task-graph": 30}
_FOCUS_BUMP_MINUTES = 15
_EASY_TASK_MINUTES = 15


def should_replan(state: dict[str, Any]) -> dict[str, Any]:
	reasons: list[str] = []
	if state.get("masteryScore") is not None and float(state["masteryScore"]) < 60:
		reasons.append("mastery_below_threshold")
	if state.get("incompleteTasks", 0) > 0:
		reasons.append("incomplete_tasks")
	if state.get("repeatedError", False):
		reasons.append("repeated_error")
	return {"needReplan": bool(reasons), "reasons": reasons}


def replan_learning_path(old_plan: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
	decision = should_replan(state)
	if not decision["needReplan"]:
		return {"plan": dict(old_plan), "changedTasks": [], "decision": decision}
	tasks = [dict(task) for task in old_plan.get("tasks", [])]
	target_id = state.get("knowledgePointId")
	changed: list[dict[str, Any]] = []
	for task in tasks:
		baseline = _BASELINE_DURATIONS.get(task.get("taskId"), task.get("durationMinutes", 30))
		if task.get("knowledgePointId") == target_id:
			new_duration = baseline + _FOCUS_BUMP_MINUTES
		elif task.get("status") == "pending":
			new_duration = max(_EASY_TASK_MINUTES, baseline - _FOCUS_BUMP_MINUTES)
		else:
			new_duration = baseline
		if task.get("durationMinutes") != new_duration:
			task["durationMinutes"] = new_duration
			changed.append(dict(task))
	new_plan = dict(old_plan, version=old_plan.get("version", 1) + 1, tasks=tasks,
			reason=";".join(decision["reasons"]))
	return {"plan": new_plan, "changedTasks": changed, "decision": decision}


def build_plan_diff(old_plan: dict[str, Any], new_plan: dict[str, Any]) -> dict[str, Any]:
	"""Return task changes between two plan versions."""
	old_tasks = {task.get("taskId", task.get("knowledgePointId")): task for task in old_plan.get("tasks", [])}
	changed_tasks = [
		dict(task) for task in new_plan.get("tasks", [])
		if old_tasks.get(task.get("taskId", task.get("knowledgePointId"))) != task
	]
	return {
		"planId": new_plan.get("planId"),
		"oldVersion": old_plan.get("version"),
		"newVersion": new_plan.get("version"),
		"changedTasks": changed_tasks,
	}


def create_plan_history(
	old_plan: dict[str, Any],
	new_plan: dict[str, Any],
	reason: str,
	evidence_ids: list[str],
) -> dict[str, Any]:
	"""Build the canonical persisted PlanHistory payload."""
	diff = build_plan_diff(old_plan, new_plan)
	history = PlanHistory(
		old_version=diff["oldVersion"],
		new_version=diff["newVersion"],
		changed_tasks=diff["changedTasks"],
		reason=reason,
		evidence_ids=evidence_ids,
		timestamp=datetime.now(timezone.utc),
	)
	return history.to_dict()
