from flask import Blueprint, jsonify, request

from app.agent.chat_llm import _load_json
from app.agent.partner_match import match_partners


partner_match_api = Blueprint("partner_match", __name__)


@partner_match_api.post("/api/v1/agent/partner-match")
def post_partner_match():
	data = request.get_json(silent=True) or {}
	user = data.get("user") or {"userId": data.get("userId", "demo-user")}
	candidates = data.get("candidates")
	if not isinstance(user, dict) or (candidates is not None and not isinstance(candidates, list)):
		return jsonify({"errorCode": "BAD_REQUEST", "message": "user/candidates 格式错误", "details": None}), 400
	if candidates is None:
		candidates = _load_json("mock_candidates.json", [])
	return jsonify(match_partners(user, [item for item in candidates if isinstance(item, dict)]))