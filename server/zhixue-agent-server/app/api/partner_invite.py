# -*- coding: utf-8 -*-
"""学习搭子邀请 —— 真正跨账号的「发起 → 收到 → 接受 / 不接受 / 无视」。

## 为什么要有这个模块

实测反馈原话：「在学习搭子这个功能这里有发起邀请，我想知道如果被邀请的用户能否
接受到，并且以怎样的途径同意，并且使两个人联系起来呢？」

当时的答案是**不能**。查证如下：

* 后端 `app/api/partner_match.py` 只有一个算分接口 `POST /api/v1/agent/partner-match`，
  全仓库 `grep invite|邀请` 在 Python 侧 **0 命中** —— 没有任何邀请实体；
* 前端那个「向该搭子发起学习邀请」按钮**不调任何接口**，它只是往本机的
  `AppState.weeklyPlan` 里插一条协同任务（`PartnerMatch.ets` 的 `confirmPartner`）。

也就是说，"邀请"从来没有离开过发起人的手机：没有收件人、没有收件箱、没有状态。
本模块把这条链路补成真的。

## 接口

    POST   /api/v1/agent/partner-invitations               发起邀请
    GET    /api/v1/agent/partner-invitations?box=inbox     收件箱（默认）
    GET    /api/v1/agent/partner-invitations?box=outbox    发件箱
    POST   /api/v1/agent/partner-invitations/<id>/accept   接受
    POST   /api/v1/agent/partner-invitations/<id>/decline  不接受
    POST   /api/v1/agent/partner-invitations/<id>/dismiss  叉掉（无视）

## 四条纪律

1. **身份一律走 `resolve_user_id(None)`** —— 已登录时忽略请求体里的 `userId`。
   否则带甲的 token 就能给乙发邀请、甚至替乙点"接受"（见 `app/api/identity.py`）。
2. **只有收件人能改变邀请状态**。发起人想撤回，那是另一件事（本版不做），
   但绝不能替对方"已接受" —— 那会让"两个人联系起来"变成单方面宣称。
3. **不编造**。目标账号不存在就如实 404，不假装已经发出去了。
4. **演示同学要如实标注**。候选人里的 `u002`/`u003` 是 `chat/mock_candidates.json`
   里的**演示数据，不是真实账号**，没人能登录他们。这类邀请照常记录（发起方看得到），
   但响应里带 `targetKind: "demo"`，前端据此如实说明"对方是演示同学，不会真的回复" ——
   而不是让用户以为邀请已经送达了。
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from typing import Any

from flask import Blueprint, jsonify, request

from app.agent.chat_llm import _load_json
from app.api.identity import resolve_user_id
from app.api.validation import MAX_ID_CHARS, bad_request, bounded_str, json_object

partner_invite_api = Blueprint("partner_invite", __name__)

#: 邀请落库的集合名（`data/repository.json` 的顶层键）。
COLLECTION = "invitations"

PENDING = "pending"
ACCEPTED = "accepted"
DECLINED = "declined"
DISMISSED = "dismissed"

#: 只有 `pending` 会出现在收件箱的"待处理"里。
_TERMINAL = (ACCEPTED, DECLINED, DISMISSED)

#: 一次最多回多少条，避免收件箱无限膨胀（按创建时间倒序取最新的）。
MAX_LIST = 50

_repository = None


def configure_partner_invite_repository(repository) -> None:
	global _repository
	_repository = repository


# --------------------------------------------------------------------------- 工具
def _now() -> str:
	return datetime.now(timezone.utc).isoformat()


def _invitation_id(sender: str, target: str) -> str:
	"""邀请主键：发起人 + 收件人 + 时间戳摘要。

	为什么把发起人和收件人都摘要进去：只按时间戳生成的话，同一秒内的两次邀请
	会撞主键（后写的覆盖先写的，用户看到"我发了两次却只有一条"）；
	只按双方生成的话，A 给 B 发第二次会**覆盖**第一次的接受/拒绝记录。
	两者都摘要，再带上微秒级时间，既唯一又不会覆盖历史。
	"""
	seed = f"{sender}:{target}:{datetime.now(timezone.utc).isoformat()}"
	return "inv-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]


def _active_user(user_id: str) -> dict[str, Any] | None:
	"""按 userId 取**有效**账号；不存在或已注销返回 None。"""
	if _repository is None or not user_id:
		return None
	record = _repository.get("users", user_id)
	if not isinstance(record, dict):
		return None
	if record.get("status") != "active":
		return None
	return record


def _known_candidate_ids() -> set[str]:
	"""演示候选人的 userId 集合（`u002` / `u003` …）。"""
	items = _load_json("mock_candidates.json", [])
	if not isinstance(items, list):
		return set()
	return {str(item.get("userId")) for item in items
		if isinstance(item, dict) and item.get("userId")}


def _display_name(user_id: str) -> str:
	record = _active_user(user_id)
	if record is not None:
		name = record.get("nickname")
		if isinstance(name, str) and name.strip():
			return name.strip()
	for item in _load_json("mock_candidates.json", []):
		if not isinstance(item, dict) or str(item.get("userId")) != user_id:
			continue
		info = item.get("basicInfo")
		if isinstance(info, dict) and isinstance(info.get("name"), str):
			return info["name"].strip()
	return user_id


def _public(invitation: dict[str, Any]) -> dict[str, Any]:
	"""对外字段白名单 —— 只回前端要用的，不把内部结构整个抖出去。"""
	return {
		"invitationId": invitation.get("invitationId", ""),
		"fromUserId": invitation.get("fromUserId", ""),
		"fromName": invitation.get("fromName", ""),
		"toUserId": invitation.get("toUserId", ""),
		"toName": invitation.get("toName", ""),
		"message": invitation.get("message", ""),
		"status": invitation.get("status", PENDING),
		# `account` = 真实账号（对方登录就能看到并能回复）；
		# `demo`    = 演示候选同学（没有账号，不会真的回复）。前端据此如实说明。
		"targetKind": invitation.get("targetKind", "account"),
		"createdAt": invitation.get("createdAt", ""),
		"respondedAt": invitation.get("respondedAt", ""),
	}


def _list_all() -> list[dict[str, Any]]:
	if _repository is None:
		return []
	items = [item for item in _repository.list(COLLECTION) if isinstance(item, dict)]
	# 新的在前：收件箱第一眼要看到最近那条。
	items.sort(key=lambda item: str(item.get("createdAt", "")), reverse=True)
	return items


def _load(invitation_id: str) -> dict[str, Any] | None:
	if _repository is None:
		return None
	record = _repository.get(COLLECTION, invitation_id)
	return record if isinstance(record, dict) else None


def _respond(invitation_id: str, responder: str, status: str):
	"""收件人改状态。三个动作（接受 / 不接受 / 无视）共用这一条路径。"""
	invitation = _load(invitation_id)
	if invitation is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "邀请不存在", "details": None}), 404
	# ⚠️ 只有收件人能改。少了这一条，任何人拿到 invitationId 就能把别人的邀请
	# 标成"已接受"——"两个人联系起来"就成了单方面宣称。
	if invitation.get("toUserId") != responder:
		return jsonify({
			"errorCode": "FORBIDDEN",
			"message": "只有被邀请的人可以处理这条邀请",
			"details": None,
		}), 403
	if invitation.get("status") != PENDING:
		return jsonify({
			"errorCode": "CONFLICT",
			"message": f"这条邀请已经处理过了（{invitation.get('status')}）",
			"details": {"status": invitation.get("status")},
		}), 409

	invitation["status"] = status
	invitation["respondedAt"] = _now()
	if _repository is not None:
		_repository.save(COLLECTION, invitation_id, invitation)

	# 「两个人联系起来」的落地：接受之后，双方各自的 `contacts` 集合里都写一条
	# 对方的信息，这样"我的搭子"不再是发起方本机的一个内存变量。
	# 注意这是**双向**写 —— 只写发起方那侧的话，被邀请的人点完"接受"什么都看不到。
	if status == ACCEPTED:
		_pair_up(invitation["fromUserId"], invitation["toUserId"], invitation_id)

	return jsonify({"invitation": _public(invitation)})


def _pair_up(left: str, right: str, invitation_id: str) -> None:
	"""接受之后把两人互相登记为搭子（双方各存一条，幂等）。"""
	if _repository is None:
		return
	for owner, other in ((left, right), (right, left)):
		contact_id = f"{owner}:{other}"
		_repository.save("contacts", contact_id, {
			"contactId": contact_id,
			"userId": owner,
			"partnerUserId": other,
			"partnerName": _display_name(other),
			"invitationId": invitation_id,
			"pairedAt": _now(),
		})


# --------------------------------------------------------------------------- 接口
@partner_invite_api.post("/api/v1/agent/partner-invitations")
def create_invitation():
	data, error = json_object()
	if error is not None:
		return error

	sender = resolve_user_id(None)
	if not sender:
		return bad_request("无法确定发起人身份")

	target, error = bounded_str(data.get("toUserId"), "toUserId", MAX_ID_CHARS)
	if error is not None:
		return error
	if target == sender:
		return bad_request("不能邀请自己")

	# 目标必须**要么是有效账号、要么是名单里的演示候选人**。
	# 不做这个校验的话，随手编一个 userId 也能"发出成功"，而对面永远不存在 ——
	# 那是本工程明令禁止的"静默假成功"。
	target_account = _active_user(target)
	if target_account is None and target not in _known_candidate_ids():
		return jsonify({
			"errorCode": "NOT_FOUND",
			"message": "找不到这个用户，无法发起邀请",
			"details": {"toUserId": target},
		}), 404

	message, error = bounded_str(data.get("message"), "message", 200,
		required=False, allow_empty=True)
	if error is not None:
		return error

	invitation_id = _invitation_id(sender, target)
	invitation = {
		"invitationId": invitation_id,
		"fromUserId": sender,
		"fromName": _display_name(sender),
		"toUserId": target,
		"toName": _display_name(target),
		"message": message,
		"status": PENDING,
		"targetKind": "account" if target_account is not None else "demo",
		"createdAt": _now(),
		"respondedAt": "",
	}
	if _repository is not None:
		_repository.save(COLLECTION, invitation_id, invitation)
	return jsonify({"invitation": _public(invitation)}), 201


@partner_invite_api.get("/api/v1/agent/partner-invitations")
def list_invitations():
	me = resolve_user_id(request.args.get("userId"))
	box = (request.args.get("box") or "inbox").strip().lower()
	items = _list_all()
	if box == "outbox":
		mine = [item for item in items if item.get("fromUserId") == me]
	else:
		# 收件箱**只回待处理的**：已经处理过的（接受/不接受/无视）留在记录里，
		# 但不该继续占着"需要你回应"的位置 —— 否则用户处理完还得再点一次关掉。
		mine = [item for item in items
			if item.get("toUserId") == me and item.get("status") == PENDING]
	return jsonify({
		"box": box,
		"userId": me,
		"invitations": [_public(item) for item in mine[:MAX_LIST]],
		"pendingCount": len([item for item in mine if item.get("status") == PENDING])
			if box == "outbox" else len(mine),
	})


@partner_invite_api.post("/api/v1/agent/partner-invitations/<invitation_id>/accept")
def accept_invitation(invitation_id: str):
	return _respond(invitation_id, resolve_user_id(None), ACCEPTED)


@partner_invite_api.post("/api/v1/agent/partner-invitations/<invitation_id>/decline")
def decline_invitation(invitation_id: str):
	return _respond(invitation_id, resolve_user_id(None), DECLINED)


@partner_invite_api.post("/api/v1/agent/partner-invitations/<invitation_id>/dismiss")
def dismiss_invitation(invitation_id: str):
	"""叉掉 —— 用户实测反馈里的"这个消息可以叉掉代表无视"。

	与「不接受」分开是因为语义不同：不接受是**明确回复对方**，
	叉掉只是**自己不想再看到**。本版两者都不通知发起方（没有消息推送渠道），
	但状态分开记，以后要接通知时不用改数据模型。
	"""
	return _respond(invitation_id, resolve_user_id(None), DISMISSED)


@partner_invite_api.get("/api/v1/agent/partner-contacts")
def list_contacts():
	"""接受之后真正"联系起来"的那份名单（双向各存一条，只回当前身份的）。"""
	me = resolve_user_id(request.args.get("userId"))
	if _repository is None:
		return jsonify({"userId": me, "contacts": []})
	items = [item for item in _repository.list("contacts")
		if isinstance(item, dict) and item.get("userId") == me]
	items.sort(key=lambda item: str(item.get("pairedAt", "")), reverse=True)
	return jsonify({
		"userId": me,
		"contacts": [{
			"partnerUserId": item.get("partnerUserId", ""),
			"partnerName": item.get("partnerName", ""),
			"pairedAt": item.get("pairedAt", ""),
		} for item in items],
	})
