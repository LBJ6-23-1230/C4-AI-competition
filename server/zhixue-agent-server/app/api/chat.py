# -*- coding: utf-8 -*-
"""自然语言交互接口（聊天层）。

联调收敛后，`/api/agent/*` 与 `/api/v1/**` 由**同一个进程**提供：

* `/api/agent/chat`   —— LLM 意图识别 + 6 路子 Agent（本文件的 `agent_chat`）
* `/api/agent/health` —— 连通性与 LLM 就绪状态（前端 ApiEnvironment 页使用）
* `/api/v1/**`        —— 真 Agent 循环 / 确定性判分 / 决策引擎（见 `app/api/` 其余模块）

这样前端只需要**一个 baseUrl**，不再出现"chat 打 B1、结构化流打 B2"的双后端不同源问题。
"""

from __future__ import annotations

import json

from flask import Blueprint, jsonify, request

from app.agent import chat_llm
from app.api.identity import resolve_user_id

chat_api = Blueprint("chat", __name__)

# 与 app/__init__.py 保持同一契约版本
CONTRACT_VERSION = "api-contract-v0.3"

_MAX_IMAGE_CHARS = 5_000_000


def _chat_identity() -> str:
    """聊天层的身份解析（对话历史 / 错题落盘都要用）。

    走项目统一的 `resolve_user_id()`：**已登录身份 > 显式 `userId` > 演示身份**。
    聊天端点同时接受请求体与 query 上的 `userId`（历史端点只有 query），
    因此两处都取一次，谁先有值用谁。
    """
    supplied = None
    body = request.get_json(silent=True)
    if isinstance(body, dict) and isinstance(body.get("userId"), str):
        supplied = body["userId"]
    if not supplied:
        supplied = request.args.get("userId")
    return resolve_user_id(supplied)


def _payload() -> dict:
    """宽松地取出请求体 JSON。

    `request.get_json(silent=True)` 在 `Content-Type` 带参数时会返回 None——
    例如 PowerShell 的 `Invoke-RestMethod -ContentType 'application/json'` 实际发出的是
    `application/json; charset=utf-8`。若只依赖 get_json，这类客户端的中文消息会被当成空消息，
    意图识别静默退化成 get_suggestion，**表现为"聊天接口答非所问"**。

    这里补一层显式解析：**先取原始字节，再按 UTF-8 解码**。
    注意不能用 `get_data(as_text=True)`——它会按猜测的字符集解码，在带 `charset=utf-8` 的
    Content-Type 下可能按 latin-1 解成乱码，导致中文意图全部丢失。
    """
    data = request.get_json(silent=True)
    if isinstance(data, dict):
        return data

    raw_bytes = request.get_data() or b""
    if not raw_bytes.strip():
        return {}
    for encoding in ("utf-8", "utf-8-sig"):
        try:
            parsed = json.loads(raw_bytes.decode(encoding))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(parsed, dict):
            return parsed
    return {}


def _contract_version_mismatch():
    supplied = request.headers.get("X-API-Contract-Version", "")
    if supplied and supplied != CONTRACT_VERSION:
        return jsonify({
            "errorCode": "CONTRACT_VERSION_MISMATCH",
            "message": f"请使用 X-API-Contract-Version: {CONTRACT_VERSION}",
            "details": None,
        }), 409
    return None


@chat_api.get("/api/agent/health")
def agent_health():
    """前端 API 环境页的连通性探针。

    注意：`/api/agent/health` 不做契约版本校验，否则前端在版本不匹配时会误判为"后端不可用"。
    """
    return jsonify({
        "status": "ok",
        "llm_ready": chat_llm.llm_ready(),
        "provider": "qwen",
        "model": chat_llm.llm_model(),
        "baseUrl": chat_llm.llm_base_url(),
        "contractVersion": CONTRACT_VERSION,
    })


@chat_api.post("/api/agent/chat")
def agent_chat():
    """统一对话接口。

    request::

        {"message": "今天我应该先学什么？", "image": "<base64，可选>", "history": [...],
         "user_data": {"isDataImported": true, "courses": [...], "homeworkDDLs": [...]}}

    response::

        {"reply": "...", "intent": "get_suggestion", "card": {...} | null}
    """
    mismatch = _contract_version_mismatch()
    if mismatch is not None:
        return mismatch

    data = _payload()
    message = str(data.get("message") or data.get("user_message") or "").strip()
    image = data.get("image")
    if image is not None and (not isinstance(image, str) or len(image) > _MAX_IMAGE_CHARS):
        return jsonify({
            "errorCode": "BAD_REQUEST",
            "message": "image 必须是字符串且不超过 5MB",
            "details": None,
        }), 400

    if not message and not image:
        return jsonify({
            "reply": "请告诉我你需要什么帮助？",
            "intent": "unknown",
            "card": None,
            "llmUsed": False,
        })

    frontend_data = data.get("user_data")
    if not isinstance(frontend_data, dict):
        frontend_data = None

    result = chat_llm.chat(
        message=message,
        image_base64=image if isinstance(image, str) and image else None,
        frontend_data=frontend_data,
        user_id=_chat_identity(),
    )

    # 响应结构：契约基线三字段 { reply, intent, card } + 可选 llmUsed。
    #
    # 为什么补 llmUsed：`app/agent/chat_llm.py` 一直返回它，前端
    # `AgentBridge.parseResponse()` 也一直解析它、`ChatMain` 据此显示
    # 「大模型生成 / 本地规则兜底」——**但此前这里没透传，字段在 HTTP 层被丢掉**，
    # 于是前端那个标签永远不显示，后端的诚实降级设计等于白做。
    #
    # 安全性：`AgentBridge` 对缺失字段是容错的（undefined 则不渲染标签），
    # 所以新增该字段不会让老前端崩溃；契约已同步声明（见 contracts/openapi.json）。
    payload: dict = {
        "reply": result["reply"],
        "intent": result["intent"],
        "card": result["card"],
        "llmUsed": bool(result.get("llmUsed", False)),
    }
    if data.get("sessionId"):
        payload["sessionId"] = str(data["sessionId"])
    return jsonify(payload)


@chat_api.get("/api/agent/history")
def chat_history():
    """读取**当前身份**的对话历史。

    历史原先是一份全局数组，任何人不带凭据就能读到所有人的聊天记录、
    并且 `DELETE` 会清空所有人 —— 聊天记录属个人信息，这是真实越权（审计已报）。
    现按 `userId` 分桶（见 `chat_llm` 的"对话历史"小节），身份用项目统一的
    `resolve_user_id()` 解析：**已登录身份 > 显式 `?userId=` > 演示身份**。
    """
    return jsonify({"history": chat_llm.get_history(_chat_identity()),
                    "userId": _chat_identity()})


@chat_api.delete("/api/agent/history")
def chat_history_clear():
    """只清空**当前身份**的历史，不再波及其他用户。"""
    identity = _chat_identity()
    chat_llm.clear_history(identity)
    return jsonify({"status": "cleared", "userId": identity})


@chat_api.get("/api/agent/user-data")
def user_data_snapshot():
    data = chat_llm._user_data(None)  # noqa: SLF001 - 自用只读快照
    return jsonify({
        "users": data.get("users", {}),
        "courses": data.get("courses", {}),
        "candidates": chat_llm._load_json("mock_candidates.json", []),  # noqa: SLF001
        "wrong_questions": chat_llm._load_json("mock_wrong_questions.json", [])[-10:],  # noqa: SLF001
    })
