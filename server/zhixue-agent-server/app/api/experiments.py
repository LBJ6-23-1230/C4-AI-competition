"""Anonymous experiment snapshot and event statistics API."""

from datetime import datetime, timezone
from typing import Any

from flask import Blueprint, jsonify

from app.repositories.json_repository import JsonRepository


experiments_api = Blueprint("experiments", __name__)
_repository: JsonRepository | None = None
SNAPSHOT_VERSION = "experiment-snapshot-v1"


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


@experiments_api.get("/api/v1/experiments/snapshot")
def get_experiment_snapshot():
	traces = _anonymous_records("traces")
	submissions = _anonymous_records("submissions")
	evidences = _anonymous_records("evidences")
	plan_diffs = _anonymous_records("plan_histories")
	status_counts: dict[str, int] = {}
	for trace in traces:
		for event in trace["data"].get("events", []):
			status = event.get("status", "unknown")
			status_counts[status] = status_counts.get(status, 0) + 1
	return jsonify({
		"snapshotVersion": SNAPSHOT_VERSION,
		"generatedAt": datetime.now(timezone.utc).isoformat(),
		"summary": {
			"traceCount": len(traces), "eventCount": sum(status_counts.values()),
			"submissionCount": len(submissions), "evidenceCount": len(evidences),
			"planDiffCount": len(plan_diffs), "eventStatusCounts": status_counts,
		},
		"traces": traces,
		"submissions": submissions,
		"evidences": evidences,
		"planDiffs": plan_diffs,
	})