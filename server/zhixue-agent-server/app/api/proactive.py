from flask import Blueprint, jsonify, request

from app.agent.proactive import proactive_decision

proactive_api = Blueprint("proactive", __name__)


@proactive_api.post("/api/v1/agent/proactive")
def post_proactive():
    data = request.get_json(silent=True) or {}
    result = proactive_decision(data)
    return jsonify(result)
