from flask import Blueprint, jsonify, request

from app.agent.proactive import proactive_decision
from app.repositories.json_repository import JsonRepository

proactive_api = Blueprint("proactive", __name__)
_repository: JsonRepository | None = None


def configure_proactive_repository(repository: JsonRepository) -> None:
    global _repository
    _repository = repository


def _profile_mastery(user_id: str) -> float | None:
    """Return the weakest persisted mastery for this identity, when available."""
    if _repository is None:
        return None
    profile = _repository.get("profiles", user_id)
    if not isinstance(profile, dict):
        return None
    mastery = profile.get("mastery")
    if not isinstance(mastery, list):
        return None
    scores: list[float] = []
    for item in mastery:
        if not isinstance(item, dict):
            continue
        try:
            scores.append(float(item.get("masteryScore")))
        except (TypeError, ValueError):
            continue
    return min(scores) if scores else None


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
    # App 首页与画像请求并发启动。首次进入新账号时，客户端缓存尚未拿到画像，
    # 因而不会传 masteryScore。此前决策引擎会回退到演示常量 58，造成
    # “服务端画像是 0，首页却写 58”的跨身份错觉。缺失时以 userId 查询真画像；
    # 调用方显式传值时仍以调用方为准，便于情景模拟与测试。
    context = dict(context) if isinstance(context, dict) else {}
    if "masteryScore" not in context:
        persisted_mastery = _profile_mastery(str(data.get("userId") or "demo-user"))
        if persisted_mastery is not None:
            context["masteryScore"] = persisted_mastery
    payload = dict(data)
    payload["context"] = context
    result = proactive_decision(payload)
    return jsonify(result)
