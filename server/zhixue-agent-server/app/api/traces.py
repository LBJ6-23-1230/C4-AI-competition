from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
from app.repositories.json_repository import JsonRepository


traces_api = Blueprint("traces", __name__)
_repository: JsonRepository | None = None


def configure_traces_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _trace_owner(trace_id: str, trace: dict | None) -> str | None:
	"""尽力确定一条 trace 的归属；无法确定时返回 None。

	新数据直接带 `userId`。老数据没有该字段，就通过"哪个工作流持有这个 traceId"
	反查（`workflows` 里每条都记了 `traceId` 与 `userId`）。
	两者都拿不到时返回 None —— **不阻止读取**，以免把没有归属概念的
	历史数据（如旧的直提交路径）一并打死。
	"""
	if isinstance(trace, dict):
		owner = trace.get("userId")
		if isinstance(owner, str) and owner:
			return owner
	for workflow in (_repository.list("workflows") if _repository else []):
		if isinstance(workflow, dict) and workflow.get("traceId") == trace_id:
			owner = workflow.get("userId")
			if isinstance(owner, str) and owner:
				return owner
	return None


@traces_api.get("/api/v1/traces/<trace_id>")
def get_trace(trace_id: str):
	trace = _repository.get("traces", trace_id) if _repository else None
	if trace is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "trace not found", "details": {"traceId": trace_id}}), 404
	# ⚠️ 归属校验：trace 的 inputSummary/outputSummary 会暴露用户的学习内容，
	# 原来任何人知道 traceId 就能读。与 workflows 同样返回 404（不泄漏存在性）。
	owner = _trace_owner(trace_id, trace)
	if owner is not None and owner != resolve_user_id(request.args.get("userId")):
		return jsonify({"errorCode": "NOT_FOUND", "message": "trace not found", "details": {"traceId": trace_id}}), 404
	return jsonify(trace)
