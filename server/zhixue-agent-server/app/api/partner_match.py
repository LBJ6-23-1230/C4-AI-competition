# -*- coding: utf-8 -*-
"""学习搭子匹配接口。

⚠️ 候选人为什么优先使用真实账号
----------------------------------
原先候选人**只**来自 `chat/mock_candidates.json`，里面是写死的
`u002`(小红) / `u003`(小刚) —— 它们**不是账号，没人能登录**。

后果不只是"演示味重"，而是**整条协作链路是断的**：任何两个真实用户都永远
匹配不到彼此，于是「发起邀请」也就永远没有真实的收件人。实测反馈原话是
「我想知道如果被邀请的用户能否接受到，并且以怎样的途径同意，并且使两个人
联系起来呢？」—— 在那个实现下，答案是"不能"。

把注册账号作为唯一候选人之后，A 能在匹配结果里看到 B，邀请才发得出去、
B 登录后才收得到（收件箱见 `app/api/partner_invite.py`）。在线模式不再回退
任何演示候选人；没有其他真实账号时就如实返回空结果。
"""

from __future__ import annotations

from typing import Any

from flask import Blueprint, jsonify

from app.agent import chat_llm
from app.agent.partner_match import match_partners
from app.api.identity import resolve_user_id
from app.api.validation import bad_request, json_object

partner_match_api = Blueprint("partner_match", __name__)

#: 与 `app/api/chat.py` 的 `_user_context_for` 同源的掌握度分档阈值。
#: 两处若各写一套，同一个人会在聊天里显示一个薄弱点、在搭子页显示另一个。
_WEAK_BELOW = 60
_STRONG_FROM = 80

_repository = None


def configure_partner_match_repository(repository) -> None:
	global _repository
	_repository = repository
	chat_llm.set_partner_match_hook(_rank_for_identity)


def _mastery_names(profile: dict[str, Any], weak: bool) -> list[str]:
	"""从画像里挑出薄弱 / 强项知识点名（阈值与聊天层同一套）。"""
	rows = profile.get("mastery")
	if not isinstance(rows, list):
		return []
	names: list[str] = []
	for row in rows:
		if not isinstance(row, dict):
			continue
		score = row.get("masteryScore")
		name = str(row.get("knowledgePointName") or "").strip()
		if not name or not isinstance(score, (int, float)):
			continue
		if (score < _WEAK_BELOW) if weak else (score >= _STRONG_FROM):
			names.append(name)
	return names


def _real_candidates(exclude: str) -> list[dict[str, Any]]:
	"""把**真实注册账号**转成与 `mock_candidates.json` 同构的候选人结构。"""
	if _repository is None:
		return []
	candidates: list[dict[str, Any]] = []
	for record in _repository.list("users"):
		if not isinstance(record, dict):
			continue
		user_id = str(record.get("userId") or "").strip()
		# 排除自己（给自己发邀请毫无意义），排除已注销账号。
		if not user_id or user_id == exclude or record.get("status") != "active":
			continue
		profile = _repository.get("profiles", user_id)
		if not isinstance(profile, dict):
			profile = {}
		slots = profile.get("freeTimeSlots")
		candidates.append({
			"userId": user_id,
			"basicInfo": {
				"name": str(record.get("nickname") or user_id),
				"grade": str(record.get("grade") or ""),
				"major": str(record.get("major") or ""),
			},
			"learningGoal": {
				"course": "",
				"goal": str(profile.get("goal") or ""),
			},
			"time": {"freeTime": slots if isinstance(slots, list) else []},
			"knowledge": {
				"weakness": _mastery_names(profile, weak=True),
				"strength": _mastery_names(profile, weak=False),
			},
			# 前端据此如实标注"这是一位真实同学，邀请对方登录后能看到"。
			"accountKind": "account",
		})
	return candidates


def _real_user_profile(user_id: str) -> dict[str, Any] | None:
	"""读取一个真实账号的权威匹配画像，与候选人转换规则完全一致。"""
	if _repository is None:
		return None
	record = _repository.get("users", user_id)
	if not isinstance(record, dict) or record.get("status") != "active":
		return None
	profile = _repository.get("profiles", user_id)
	if not isinstance(profile, dict):
		profile = {}
	slots = profile.get("freeTimeSlots")
	return {
		"userId": user_id,
		"basicInfo": {
			"name": str(record.get("nickname") or user_id),
			"grade": str(record.get("grade") or ""),
			"major": str(record.get("major") or ""),
		},
		"learningGoal": {"course": "", "goal": str(profile.get("goal") or "")},
		"time": {"freeTime": slots if isinstance(slots, list) else []},
		"knowledge": {
			"weakness": _mastery_names(profile, weak=True),
			"strength": _mastery_names(profile, weak=False),
		},
		"accountKind": "account",
	}


def _rank_for_identity(user_id: str) -> dict[str, Any]:
	"""聊天与详情页共用的唯一排名入口，只使用真实注册账号。"""
	user = _real_user_profile(user_id)
	if user is None:
		return {"userId": user_id, "matchedCandidate": None, "candidates": []}
	return match_partners(user, _real_candidates(user_id))


@partner_match_api.post("/api/v1/agent/partner-match")
def post_partner_match():
	# 非对象 JSON（[1,2,3] / "hello" / 123 / true）原先会因 data.get 抛
	# AttributeError 变成 500（实测这 4 类输入稳定复现）。
	# `app/api/proactive.py` 一开始就有正确的 isinstance 护栏，可作模板；
	# 这里统一走 `app/api/validation.py`。
	data, error = json_object()
	if error is not None:
		return error

	# 已登录时忽略请求体里的 userId，避免"带甲的 token 拿到乙的匹配结果"。
	me = resolve_user_id(data.get("userId"))
	# 真实登录账号必须使用仓储画像，不能信任前端临时对象；否则聊天与详情页
	# 即使候选池相同，也会因“当前用户画像”不同而算出不同排名。
	user = _real_user_profile(me) or data.get("user") or {"userId": me}
	candidates = data.get("candidates")
	if not isinstance(user, dict) or (candidates is not None and not isinstance(candidates, list)):
		return bad_request("user/candidates 格式错误")
	if candidates is None:
		# 联机模式只匹配真实注册账号。没有其他账号就返回空候选，绝不再回退
		# “小红/小刚”等预置人物；离线演示由前端 Fixture 自己负责。
		candidates = _real_candidates(me)
	valid = [item for item in candidates if isinstance(item, dict)]
	result = match_partners(user, valid)
	result["candidateSources"] = {
		"accounts": len([item for item in valid if item.get("accountKind") == "account"]),
		"demo": len([item for item in valid if item.get("accountKind") != "account"]),
	}
	return jsonify(result)
