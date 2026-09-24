from flask import Blueprint, jsonify

from app.agent.chat_llm import _load_json
from app.agent.partner_match import match_partners
from app.api.validation import json_object, bad_request


partner_match_api = Blueprint("partner_match", __name__)


@partner_match_api.post("/api/v1/agent/partner-match")
def post_partner_match():
	# 非对象 JSON（[1,2,3] / "hello" / 123 / true）原先会因 data.get 抛
	# AttributeError 变成 500（实测这 4 类输入稳定复现）。
	# `app/api/proactive.py` 一开始就有正确的 isinstance 护栏，可作模板；
	# 这里统一走 `app/api/validation.py`。
	data, error = json_object()
	if error is not None:
		return error

	user = data.get("user") or {"userId": data.get("userId", "demo-user")}
	candidates = data.get("candidates")
	if not isinstance(user, dict) or (candidates is not None and not isinstance(candidates, list)):
		return bad_request("user/candidates 格式错误")
	if candidates is None:
		candidates = _load_json("mock_candidates.json", [])
	return jsonify(match_partners(user, [item for item in candidates if isinstance(item, dict)]))
