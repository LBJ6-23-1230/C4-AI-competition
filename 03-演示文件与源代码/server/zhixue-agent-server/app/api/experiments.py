"""Anonymous experiment snapshot and event statistics API."""

from datetime import datetime, timezone
from typing import Any

from flask import Blueprint, jsonify

from app.repositories.json_repository import JsonRepository


experiments_api = Blueprint("experiments", __name__)
_repository: JsonRepository | None = None
SNAPSHOT_VERSION = "experiment-snapshot-v1"
_FORBIDDEN_REASONING_KEYS = {"chainOfThought", "reasoning"}


def configure_experiments_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _without_identity(value: Any) -> Any:
	if isinstance(value, dict):
		return {key: _without_identity(item) for key, item in value.items() if key != "userId"}
	if isinstance(value, list):
		return [_without_identity(item) for item in value]
	return value


def _anonymous_records(collection: str) -> list[dict]:
	if _repository is None:
		return []
	return [{"recordId": f"record-{index:04d}", "data": _without_identity(value)}
		for index, value in enumerate(_repository.list(collection), 1)]


def _contains_reasoning(value: Any) -> bool:
	if isinstance(value, dict):
		return any(
			key in _FORBIDDEN_REASONING_KEYS or _contains_reasoning(item)
			for key, item in value.items()
		)
	if isinstance(value, list):
		return any(_contains_reasoning(item) for item in value)
	return False


@experiments_api.get("/api/v1/experiments/snapshot")
def get_experiment_snapshot():
	traces = _anonymous_records("traces")
	submissions = _anonymous_records("submissions")
	evidences = _anonymous_records("evidences")
	plan_diffs = _anonymous_records("plan_histories")
	profiles = _anonymous_records("profiles")
	status_counts: dict[str, int] = {}
	event_counts: list[int] = []
	agents: set[str] = set()
	tools: set[str] = set()
	compliance_violations: list[str] = []
	for trace in traces:
		events = trace["data"].get("events", [])
		event_counts.append(len(events))
		if _contains_reasoning(trace["data"]):
			compliance_violations.append(trace["recordId"])
		for event in events:
			status = event.get("status", "unknown")
			status_counts[status] = status_counts.get(status, 0) + 1
			agent = event.get("agent")
			if isinstance(agent, str) and agent:
				agents.add(agent)
			tools.update(
				tool for tool in event.get("toolCalls", [])
				if isinstance(tool, str) and tool
			)
	mastery_deltas = []
	for submission in submissions:
		response = submission["data"].get("response") or {}
		mastery_update = response.get("masteryUpdate") or {}
		if "oldScore" in mastery_update and "newScore" in mastery_update:
			mastery_deltas.append(
				float(mastery_update["newScore"]) - float(mastery_update["oldScore"]))
	for profile in profiles:
		for history in profile["data"].get("history", []):
			if "oldScore" in history and "newScore" in history:
				mastery_deltas.append(
					float(history["newScore"]) - float(history["oldScore"]))
	trace_steps = sum(event_counts)
	# plan_histories 是重规划的事实源；submissions 仅作为分母的主口径。
	# 工作流路径在修复前不写 submissions，因此回退到 evidences，
	# 让历史数据与直接提交路径都能得到正确、可解释的统计结果。
	replan_count = len(plan_diffs)
	if submissions:
		replan_denominator = len(submissions)
		replan_rate_basis = "plan_histories/submissions"
	elif evidences:
		replan_denominator = len(evidences)
		replan_rate_basis = "plan_histories/evidences"
	else:
		replan_denominator = 0
		replan_rate_basis = "plan_histories/no_assessments"
	return jsonify({
		"snapshotVersion": SNAPSHOT_VERSION,
		"generatedAt": datetime.now(timezone.utc).isoformat(),
		"summary": {
			"traceCount": len(traces), "eventCount": sum(status_counts.values()),
			"submissionCount": len(submissions), "evidenceCount": len(evidences),
			"planDiffCount": len(plan_diffs), "eventStatusCounts": status_counts,
			"averageSteps": round(trace_steps / len(traces), 2) if traces else 0,
			"coveredAgentCount": len(agents),
			"coveredAgents": sorted(agents),
			"coveredToolCount": len(tools),
			"coveredTools": sorted(tools),
			"averageMasteryDelta": (
				round(sum(mastery_deltas) / len(mastery_deltas), 2)
				if mastery_deltas else 0
			),
			"replanCount": replan_count,
			"replanDenominator": replan_denominator,
			"replanRate": (
				round(replan_count / replan_denominator, 4)
				if replan_denominator else 0
			),
			"replanRateBasis": replan_rate_basis,
			"traceCompliant": not compliance_violations,
			"traceComplianceViolations": compliance_violations,
		},
		"traces": traces,
		"submissions": submissions,
		"evidences": evidences,
		"planDiffs": plan_diffs,
	})
