from flask import Blueprint, jsonify

from app.repositories.json_repository import JsonRepository


traces_api = Blueprint("traces", __name__)
_repository: JsonRepository | None = None


def configure_traces_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@traces_api.get("/api/v1/traces/<trace_id>")
def get_trace(trace_id: str):
	trace = _repository.get("traces", trace_id) if _repository else None
	if trace is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "trace not found", "details": {"traceId": trace_id}}), 404
	return jsonify(trace)
