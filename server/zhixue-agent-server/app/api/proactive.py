from flask import Blueprint, jsonify, request

from app.agent.proactive import proactive_decision

proactive_api = Blueprint("proactive", __name__)


@proactive_api.post("/api/v1/agent/proactive")
def post_proactive():
    data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        return jsonify({
            "errorCode": "BAD_REQUEST",
            "message": "request body must be an object",
            "details": None,
        }), 400
    context = data.get("context")
    if context is not None and not isinstance(context, dict):
        return jsonify({
            "errorCode": "BAD_REQUEST",
            "message": "context must be an object",
            "details": {"field": "context"},
        }), 400
    pending_tasks = context.get("pendingTasks") if isinstance(context, dict) else None
    if pending_tasks is not None and (
            not isinstance(pending_tasks, list)
            or any(not isinstance(item, dict) for item in pending_tasks)):
        return jsonify({
            "errorCode": "BAD_REQUEST",
            "message": "context.pendingTasks must be an array of objects",
            "details": {"field": "context.pendingTasks"},
        }), 400
    result = proactive_decision(data)
    return jsonify(result)
