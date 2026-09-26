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
from app.api.identity import DEMO_USER_ID, resolve_user_id
from app.repositories.json_repository import JsonRepository

chat_api = Blueprint("chat", __name__)

# 与 app/__init__.py 保持同一契约版本
CONTRACT_VERSION = "api-contract-v0.3"

_MAX_IMAGE_CHARS = 5_000_000

_repository: JsonRepository | None = None


def _apply_profile_updates(user_id: str | None, updates: dict) -> list[str]:
    """把"更新档案"意图解析出的 `updates.user` 落到 `profiles` 集合。

    返回**实际写入成功的字段名**（中文名，直接用于回复文案），
    这样"已更新"就有据可依 —— 见 `chat_llm._handle_update_profile` 的说明。

    ## 为什么只处理这几个字段

    后端 `profiles` 的 schema 是 `{userId, goal, examDate, freeTimeSlots,
    profileVersion, mastery}`。prompt 里的 `updates.user.basicInfo`
    （姓名/年级/专业）与 `updates.user.knowledge`（薄弱点/强项）
    **在后端没有对应存储**，属于前端本地 AppState 的字段 —— 硬写进来
    只会写到一个没人读的地方，那正是本次要消灭的"假成功"。
    所以这里只写 `goal` / `examDate` / `freeTimeSlots`，其余交给前端。
    """
    if _repository is None:
        return []
    owner = (user_id or "").strip() or "demo-user"
    profile = _repository.get("profiles", owner)
    if profile is None:
        return []
    user_block = updates.get("user")
    if not isinstance(user_block, dict):
        return []

    changed: list[str] = []

    # 学习目标：prompt 的 learningGoal.goal（也容忍直接给字符串）
    learning_goal = user_block.get("learningGoal")
    if isinstance(learning_goal, dict):
        goal = learning_goal.get("goal")
        if isinstance(goal, str) and goal.strip() and goal.strip() != profile.get("goal"):
            profile["goal"] = goal.strip()[:200]
            changed.append("学习目标")
    elif isinstance(learning_goal, str) and learning_goal.strip():
        if learning_goal.strip() != profile.get("goal"):
            profile["goal"] = learning_goal.strip()[:200]
            changed.append("学习目标")

    # 空闲时间：prompt 的 time.freeTime，元素形如 "20:00-22:00"
    time_block = user_block.get("time")
    if isinstance(time_block, dict):
        free_time = time_block.get("freeTime")
        if isinstance(free_time, list):
            slots = [s.strip() for s in free_time
                     if isinstance(s, str) and s.strip()]
            if slots and slots != profile.get("freeTimeSlots"):
                profile["freeTimeSlots"] = slots[:20]
                changed.append("空闲时间")

    # 考试日期：prompt 把它放在 updates.course[].exam.date，
    # 但用户也可能只在 user 块里说"考试改到 X 号"，两个位置都认。
    exam_date = user_block.get("examDate")
    if isinstance(exam_date, str) and exam_date.strip():
        if exam_date.strip() != profile.get("examDate"):
            profile["examDate"] = exam_date.strip()[:40]
            changed.append("考试日期")

    if not changed:
        return []

    # 版本号递增：画像变了，下游（计划/优先级）据此判断是否需要重算
    try:
        profile["profileVersion"] = int(profile.get("profileVersion", 1)) + 1
    except (TypeError, ValueError):
        profile["profileVersion"] = 2
    _repository.save("profiles", owner, profile)
    return changed


def configure_chat_repository(repository: JsonRepository) -> None:
    """注入仓储，并把画像落盘钩子注册给对话层。

    钩子的存在意义：`app/agent/chat_llm.py` 是**纯对话层**，不应依赖持久化边界；
    而"更新档案"要真的落盘又必须有仓储。用钩子把两者解耦。
    """
    global _repository
    _repository = repository
    chat_llm.set_profile_update_hook(_apply_profile_updates)


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


def _user_context_for(user_id: str) -> dict:
    """按**当前身份**组装喂给模型的「用户信息」块。

    ⚠️ 此前 `chat_llm._user_data()` 永远读 `chat/mock_users.json`（u001 / 小明 /
    薄弱点写死 `['二叉树遍历','递归理解']`），**与当前登录是谁无关** —— 于是模型
    照着"小明"的画像回话：称呼用户"小明"、张口就是"二叉树遍历"。
    实测反馈里的「怎么一直在小明」「默认不要直接说我掌握了二叉树遍历」就是这条。

    现在：真实账号用**自己的昵称 + 自己的画像**（薄弱点由掌握度排序推出）；
    游客/查无此人/无仓储时才回落演示数据（返回空 dict 即回落）。
    """
    if _repository is None or user_id == DEMO_USER_ID:
        return {}
    user = _repository.get("users", user_id)
    profile = _repository.get("profiles", user_id)
    if not isinstance(user, dict) and not isinstance(profile, dict):
        return {}

    nickname = user.get("nickname") if isinstance(user, dict) else ""
    grade = user.get("grade") if isinstance(user, dict) else ""

    weak: list[str] = []
    strong: list[str] = []
    scored: list[dict] = []
    mastery = profile.get("mastery") if isinstance(profile, dict) else None
    if isinstance(mastery, list):
        scored = [item for item in mastery
                  if isinstance(item, dict) and isinstance(item.get("masteryScore"), (int, float))]
        scored.sort(key=lambda item: item["masteryScore"])
        for item in scored:
            name = str(item.get("knowledgePointName") or item.get("knowledgePointId") or "").strip()
            if not name:
                continue
            if item["masteryScore"] < 60:
                weak.append(name)
            elif item["masteryScore"] >= 80:
                strong.append(name)

    context: dict = {
        "userId": user_id,
        "basicInfo": {"name": nickname or "同学", "grade": grade, "major": ""},
        # 掌握度低的是薄弱点、高的是强项 —— **由真实数据推出，不是写死的**。
        "knowledge": {"weakness": weak[:5], "strength": strong[:5]},
        # 逐条掌握度：用户自称"我掌握了 X"时，对话层要拿**真实数字**对一遍，
        # 而不是照单全收（见 `chat_llm._mastery_claim_gate`）。
        "mastery": [
            {"knowledgePointName": str(item.get("knowledgePointName") or ""),
             "knowledgePointId": str(item.get("knowledgePointId") or ""),
             "masteryScore": item["masteryScore"]}
            for item in scored
        ],
    }
    if isinstance(profile, dict):
        if profile.get("goal"):
            context["learningGoal"] = {"course": "", "goal": profile["goal"]}
        if profile.get("freeTimeSlots"):
            context["time"] = {"freeTime": profile["freeTimeSlots"]}
    return context


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

    _identity: str = _chat_identity()
    result = chat_llm.chat(
        message=message,
        image_base64=image if isinstance(image, str) and image else None,
        frontend_data=frontend_data,
        user_id=_identity,
        # 把**当前身份的真实资料**传给对话层：没有它，模型只会照着
        # mock 的 u001/小明 回话（见 `_user_context_for` 的说明）。
        user_context=_user_context_for(_identity),
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
    # `profileUpdates`：仅"更新档案"意图下非空。
    # 为什么必须下发：后端 `profiles` 集合只持有 goal/examDate/freeTimeSlots/mastery，
    # **课程与任务是前端本地数据**。prompt 让模型返回 updates 而不是最终文案，
    # 本意就是要调用方去应用；此前这整份 updates 在 chat_llm 里被丢弃，
    # 于是"已帮你更新信息"是一句无据可依的假成功。现在前后端各应用自己那部分。
    # 与 llmUsed 同理：缺失该字段时老前端不受影响（`AgentBridge` 容错读取）。
    profile_updates = result.get("profileUpdates")
    if isinstance(profile_updates, dict) and profile_updates:
        payload["profileUpdates"] = profile_updates
    # `wrongAnalysis`：仅"错题分析"意图下可能非空，携带识别出的**结构化知识点**。
    # 为什么必须下发：前端据此把"拍一道错题"接到"针对这个知识点练"——
    # 知识点在自然语言答复里，程序没法用。识别不出时不下发该字段，
    # 前端如实回落（不编造知识点）。与 llmUsed 同理：老前端不受影响。
    wrong_analysis = result.get("wrongAnalysis")
    if isinstance(wrong_analysis, dict) and wrong_analysis:
        payload["wrongAnalysis"] = wrong_analysis
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
    identity: str = _chat_identity()
    data = chat_llm._user_data(None, _user_context_for(identity))  # noqa: SLF001 - 自用只读快照
    return jsonify({
        "users": data.get("users", {}),
        "courses": data.get("courses", {}),
        "candidates": chat_llm._load_json("mock_candidates.json", []),  # noqa: SLF001
        "wrong_questions": _wrong_questions_for(identity),
    })


def _wrong_questions_for(user_id: str) -> list:
    """当前身份可见的错题（最多最近 10 条）。

    ⚠️ 原实现是 `_load_json(...)[-10:]` —— **完全不按身份过滤**，直接取文件最后
    10 条。后果已实测复现：一个**刚注册、零错题**的新账号调这个接口，拿到的是
    `u001` 的 10 条错题。项目的身份隔离闸门（`check_identity_isolation.py`
    22 项、`check_logged_in_flows.py` 越权检查）恰好都没覆盖这个端点。

    演示身份额外认 `u001`：历史种子数据的 userId 就是它（随包那份已清理为
    `demo-user`，这里保留兼容，避免旧运行库看不到演示错题）。
    """
    rows = chat_llm._load_json("mock_wrong_questions.json", [])  # noqa: SLF001
    if not isinstance(rows, list):
        return []
    accepted = {user_id}
    if user_id == DEMO_USER_ID:
        accepted.add("u001")
    own = [row for row in rows
           if isinstance(row, dict) and str(row.get("userId") or "") in accepted]
    return own[-10:]
