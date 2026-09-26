from flask import Blueprint, jsonify, request

from app.agent.proactive import proactive_decision
from app.repositories.json_repository import JsonRepository

proactive_api = Blueprint("proactive", __name__)
_repository: JsonRepository | None = None


def configure_proactive_repository(repository: JsonRepository) -> None:
    global _repository
    _repository = repository


def _weakest_knowledge(user_id: str) -> dict | None:
    """取该身份画像里**最薄弱**的知识点（掌握度最低的一条）。

    返回 `{"masteryScore": float, "knowledgePointId": str, "knowledgePointName": str}`；
    查不到画像或画像为空时返回 None。

    为什么要连**知识点名字**一起取：决策引擎此前把任务名与知识点名**写死成
    "二叉树后序遍历"**（见 `app/agent/proactive.py`），于是无论用户真实薄弱点是什么
    （例如刚诊断出"哈希表"），首页/学习页的卡片文案永远写"二叉树后序遍历" ——
    实测反馈里的「这里就有哈希了，但是上面的不能一味的写二叉树后序遍历，要具体看题目」。
    """
    if _repository is None:
        return None
    profile = _repository.get("profiles", user_id)
    if not isinstance(profile, dict):
        return None
    mastery = profile.get("mastery")
    if not isinstance(mastery, list):
        return None
    best: dict | None = None
    for item in mastery:
        if not isinstance(item, dict):
            continue
        try:
            score = float(item.get("masteryScore"))
        except (TypeError, ValueError):
            continue
        if best is None or score < best["masteryScore"]:
            best = {
                "masteryScore": score,
                "knowledgePointId": str(item.get("knowledgePointId") or ""),
                "knowledgePointName": str(item.get("knowledgePointName") or ""),
            }
    return best


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
    if "masteryScore" not in context or "taskName" not in context:
        weakest = _weakest_knowledge(str(data.get("userId") or "demo-user"))
        if weakest is not None:
            if "masteryScore" not in context:
                context["masteryScore"] = weakest["masteryScore"]
            # 任务名/知识点也按**真实薄弱点**给，避免引擎回落到写死的"二叉树后序遍历"。
            if "taskName" not in context and weakest["knowledgePointName"]:
                context["taskName"] = weakest["knowledgePointName"]
            if "knowledgePointId" not in context and weakest["knowledgePointId"]:
                context["knowledgePointId"] = weakest["knowledgePointId"]
    payload = dict(data)
    payload["context"] = context
    result = proactive_decision(payload)
    return jsonify(result)
