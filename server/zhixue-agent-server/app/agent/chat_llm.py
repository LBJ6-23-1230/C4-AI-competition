# -*- coding: utf-8 -*-
"""自然语言交互层（从原 B1 `backend/agent_routes.py` 合并而来）。

职责边界（联调收敛后的单一真源架构）::

    /api/agent/chat   → 本模块：LLM 意图识别 + 6 路子 Agent + 多模态识图（自然语言层）
    /api/v1/**        → app/api/*：真 Agent 循环 + 确定性判分 + 决策引擎（结构化工作流层）

设计纪律：
1. LLM 只负责"生成自然语言回复 / 识别意图"；所有业务计算（判分、掌握度、优先级、重规划）
   一律留在 `app/tools` 与 `app/decision` 的确定性代码里，不进入 prompt。
2. 未配置 `DASHSCOPE_API_KEY` 时**不得伪装成真实 LLM 结果**：意图识别退回关键词匹配，
   回复文案明确标注为本地规则兜底。
3. 任何异常都不抛出到路由层，统一转成可读的中文回复，保证聊天链路不 500。
"""

from __future__ import annotations

import base64
import json
import os
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

_BASE_DIR = Path(__file__).resolve().parent
_CHAT_DIR = _BASE_DIR.parent.parent / "chat"
_PROMPT_DIR = _CHAT_DIR / "prompts"


def _var_dir() -> Path:
    """**可写**数据的目录，支持 `ZHIXUE_CHAT_DIR` 重定向。

    为什么需要：`data/repository.json` 早就支持 `ZHIXUE_REPOSITORY` 重定向，
    联调因此不会污染交付包。但 `chat/history.json` 走的是写死的 `_CHAT_DIR`，
    **没被重定向** —— 每跑一次联调就往交付包的历史文件里塞进
    `probe-a` / `probe-b` 之类的测试分桶。

    实测证据：队友交付的 `chat/history.json` 是 **18,162 B / 5 个分桶**
    （`demo-user` / `user-a` / `user-b` / `probe-a` / `probe-b`），
    而干净状态只需 `demo-user` 一个桶。

    只重定向**可写**文件（`history.json`）；`prompts/` 与 mock 数据是只读资源，
    仍从 `_CHAT_DIR` 读取，保持交付包自足。
    """
    override = (os.getenv("ZHIXUE_CHAT_DIR") or "").strip()
    return Path(override) if override else _CHAT_DIR


# 意图 → (标题, 兜底跳转页, 按钮文案)
INTENT_CARDS: dict[str, tuple[str, str, str]] = {
    "analyze_wrong": ("错题分析", "pages/WrongQuestion", "查看错题分析"),
    "query_tasks": ("今日任务", "pages/StudyPlan", "查看任务清单"),
    "analyze_weakness": ("薄弱点诊断", "pages/StudyTags", "查看薄弱画像"),
    "match_partner": ("学习搭子", "pages/PartnerMatch", "查看搭子详情"),
    "update_profile": ("学习画像", "pages/StudyTags", "查看学习画像"),
    "get_suggestion": ("学习建议", "pages/StudySuggestion", "查看今日建议"),
}

# 前端 ChatModels 的 ChatIntent 取值（free_chat 为前端自有）
KNOWN_INTENTS = tuple(INTENT_CARDS.keys())

# 无 LLM 时的本地规则回复
_LOCAL_REPLY: dict[str, str] = {
    "query_tasks": "我已按当前课程与作业 DDL 整理出任务优先级，你可以打开学习计划查看。",
    "analyze_weakness": "我已读取当前学习画像与错题证据，你可以查看薄弱知识点与掌握度明细。",
    "get_suggestion": "我已按课程紧迫度、近期复习状态与薄弱点算好今日建议，先从最高优先级任务开始。",
    "match_partner": "我已按课程、目标、知识互补与空闲时间完成搭子匹配，可以查看匹配因子明细。",
    "analyze_wrong": "请上传或选择一道错题，我会给出知识点、错误类型与补强建议。",
    "update_profile": "你可以直接说明要更新的信息，例如「我掌握了二叉树遍历」。",
    "unknown": "你可以问我今日建议、薄弱点、学习计划，也可以上传错题或匹配学习搭子。",
}

_LOCAL_NOTICE = (
    "\n\n（提示：当前未配置 DASHSCOPE_API_KEY，"
    "以上回复由本地确定性规则生成，不是大模型输出。）"
)


# --------------------------------------------------------------------------- 文件与配置
def _load_prompt(filename: str) -> str:
    path = _PROMPT_DIR / filename
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


def _load_json(filename: str, default: Any = None) -> Any:
    """读 mock / 可变数据。

    **优先看重定向目录**（`ZHIXUE_CHAT_DIR`），没有才回落包内 ——
    因为 `mock_wrong_questions.json` 是**会被写入**的（`_handle_analyze_wrong`
    会 append 一条分析结果）。若只读包内、写重定向目录，就会出现
    "写进去的读不回来"，而且包内那份仍会被来回覆盖。

    读顺序：重定向目录 → 包内 `chat/`（首次运行时后者提供初始内容）。
    """
    for directory in (_var_dir(), _CHAT_DIR):
        path = directory / filename
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
    return default if default is not None else {}


def _mutable_path(filename: str) -> Path:
    """**会被写入**的数据文件路径（可经 `ZHIXUE_CHAT_DIR` 重定向）。

    首次写入前若重定向目录里还没有该文件，先从包内复制一份作为初值 ——
    这样"演示数据"与"运行期新增"能正确合并，而不是把演示数据丢掉。
    """
    directory = _var_dir()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / filename
    if not target.exists():
        seed = _CHAT_DIR / filename
        if seed.exists() and seed.resolve() != target.resolve():
            try:
                target.write_text(seed.read_text(encoding="utf-8"), encoding="utf-8")
            except OSError:
                pass
    return target


def _history_path() -> Path:
    """对话历史文件路径（可经 `ZHIXUE_CHAT_DIR` 重定向，见 `_var_dir()`）。"""
    directory = _var_dir()
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "history.json"


def llm_ready() -> bool:
    return bool(os.getenv("DASHSCOPE_API_KEY", "").strip())


def llm_model() -> str:
    return os.getenv("LLM_MODEL", "qwen-vl-plus")


def llm_vl_model() -> str:
    return os.getenv("LLM_VL_MODEL", "").strip() or llm_model()


def llm_base_url() -> str:
    return os.getenv("LLM_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")


def llm_timeout_seconds() -> float:
    try:
        return max(1.0, float(os.getenv("LLM_TIMEOUT_SECONDS", "30")))
    except ValueError:
        return 30.0


# --------------------------------------------------------------------------- LLM 调用
def _client():
    import openai  # 延迟导入：未安装 openai 时不影响确定性接口
    return openai.OpenAI(
        api_key=os.getenv("DASHSCOPE_API_KEY", "").strip(), base_url=llm_base_url(),
        timeout=llm_timeout_seconds())


def _call_llm(system_prompt: str, user_prompt: str, temperature: float = 0.7,
              max_tokens: int = 800, response_json: bool = False) -> str:
    kwargs: dict[str, Any] = {
        "model": llm_model(),
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if response_json:
        kwargs["response_format"] = {"type": "json_object"}
    response = _client().chat.completions.create(**kwargs)
    return response.choices[0].message.content or ""


def _image_mime_type(image_base64: str) -> str:
    """从 base64 文件头识别图片类型，避免把 PNG 误标成 JPEG。"""
    try:
        raw = base64.b64decode((image_base64 or "")[:128], validate=False)
    except (ValueError, TypeError):
        return "image/jpeg"
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if raw.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if raw.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if raw.startswith(b"RIFF") and raw[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


def _call_llm_with_image(system_prompt: str, user_prompt: str, image_base64: str) -> str:
    """Qwen-VL 多模态调用：错题拍照识别链路。"""
    model = llm_vl_model()
    image_url = (
        f"data:{_image_mime_type(image_base64)};base64,{image_base64}")
    response = _client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": [
                {"type": "image_url",
                 "image_url": {"url": image_url}},
                {"type": "text", "text": user_prompt},
            ]},
        ],
        temperature=0.7,
        max_tokens=800,
    )
    return response.choices[0].message.content or ""


# --------------------------------------------------------------------------- 对话历史
#
# 历史文件的结构演进
# ------------------
# 原先是**一个全局的 JSON 数组**，所有用户的对话混在同一条流里：
#
#     [ {"user_input": ..., "bot_response": ..., "timestamp": ...}, ... ]
#
# 后果（审计实测）：`GET /api/agent/history` 返回的是**所有人的聊天记录**，
# 且 `DELETE` 会**清空所有人**的历史 —— 聊天记录属个人信息，这是真实的越权。
#
# 现在改为**按 userId 分桶**：
#
#     { "demo-user": [ {...}, ... ], "u-xxxx": [ {...}, ... ] }
#
# 读取时对旧的数组格式做**一次性兼容迁移**（把整条流归给 `demo-user`），
# 因此旧数据不会报错、也不会丢，演示基线不受影响。

#: 分桶格式下的默认身份，与 `app/api/identity.DEMO_USER_ID` 保持一致。
DEFAULT_HISTORY_USER = "demo-user"

#: 每个用户保留的最大对话轮数。
HISTORY_MAX_ENTRIES = 50


def _load_history_store() -> dict[str, list[dict[str, Any]]]:
    """读取整个历史文件，并把旧的扁平数组格式迁成按用户分桶。"""
    path = _history_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    if isinstance(data, dict):
        return {str(key): value for key, value in data.items() if isinstance(value, list)}
    if isinstance(data, list):
        # 旧格式：整条流没有归属信息，统一归给演示身份。
        return {DEFAULT_HISTORY_USER: data} if data else {}
    return {}


def _write_history_store(store: dict[str, list[dict[str, Any]]]) -> None:
    _history_path().write_text(
        json.dumps(store, ensure_ascii=False, indent=2), encoding="utf-8")


def get_history(user_id: str | None = None) -> list[dict[str, Any]]:
    """读取**指定用户**的对话历史；`user_id` 缺省取演示身份。"""
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    return _load_history_store().get(key, [])


def clear_history(user_id: str | None = None) -> None:
    """清空**指定用户**的历史，不动其他用户。"""
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    store = _load_history_store()
    if key in store:
        store[key] = []
        _write_history_store(store)


def append_history(user_input: str, bot_response: str,
                   user_id: str | None = None) -> None:
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    store = _load_history_store()
    bucket = store.get(key, [])
    bucket.append({
        "user_input": user_input,
        "bot_response": bot_response,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()),
    })
    store[key] = bucket[-HISTORY_MAX_ENTRIES:]
    _write_history_store(store)


def _format_history(num_entries: int = 10, user_id: str | None = None) -> str:
    lines = []
    for entry in get_history(user_id)[-num_entries:]:
        lines.append(
            f"用户: {entry.get('user_input', '')}\n知学Mate: {entry.get('bot_response', '')}")
    return "\n".join(lines)


# --------------------------------------------------------------------------- 用户上下文
def _format_frontend_courses(courses: list[Any], ddls: list[Any]) -> list[dict[str, Any]]:
    """把前端注入的 CourseInfo[] + HomeworkDDL[] 转成 Prompt 可读的结构。"""
    result: list[dict[str, Any]] = []
    for course in courses:
        if not isinstance(course, dict):
            continue
        course_name = course.get("courseName", "")
        exam = course.get("exam") if isinstance(course.get("exam"), dict) else {}
        recent = course.get("recentStatus") if isinstance(course.get("recentStatus"), dict) else {}
        tasks = [
            {"taskname": item.get("title", ""), "deadline": item.get("dueDate", "")}
            for item in (ddls or [])
            if isinstance(item, dict) and item.get("courseName", "") == course_name
        ]
        result.append({
            "courseName": course_name,
            "exam": {"date": exam.get("date", ""), "daysLeft": exam.get("daysLeft", 0)},
            "priority": course.get("priority", "中"),
            "recentStatus": {
                "studyHours": recent.get("studyHours", 0),
                "status": recent.get("status", ""),
            },
            "tasks": tasks,
        })
    return result or _load_json("mock_courses.json", [])


def _user_data(frontend_data: dict[str, Any] | None) -> dict[str, Any]:
    users = _load_json("mock_users.json", {})
    if frontend_data and frontend_data.get("isDataImported"):
        courses = _format_frontend_courses(
            frontend_data.get("courses") or [], frontend_data.get("homeworkDDLs") or [])
    else:
        courses = _load_json("mock_courses.json", [])
    return {"users": users, "courses": courses}


def _task_lines(courses: Any) -> list[str]:
    today = datetime.now().date()
    lines: list[str] = []
    for course in (courses if isinstance(courses, list) else [courses]):
        if not isinstance(course, dict):
            continue
        for index, task in enumerate(course.get("tasks", []), start=1):
            deadline = task.get("deadline", "")
            status = "未知"
            if deadline:
                try:
                    days = (datetime.strptime(deadline, "%Y-%m-%d").date() - today).days
                    status = "今天截止" if days == 0 else (
                        f"倒计时{days}天" if days > 0 else f"已过期{abs(days)}天")
                except ValueError:
                    status = "未知"
            lines.append(f"{index}. {course.get('courseName', '未知课程')}："
                         f"{task.get('taskname', '未知任务')}（DDL: {deadline}，{status}）")
    return lines


def _context_prompt(user_message: str, data: dict[str, Any],
                    user_id: str | None = None) -> str:
    return (
        f"对话历史：{_format_history(user_id=user_id)}\n"
        f"用户输入：{user_message}\n"
        f"当前日期：{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}\n"
        f"用户信息：{json.dumps(data.get('users', {}), ensure_ascii=False)}\n"
        f"课程信息：{json.dumps(data.get('courses', {}), ensure_ascii=False)}\n"
        f"任务列表：{chr(10).join(_task_lines(data.get('courses', {}))) or '暂无任务'}"
    )


def _partner_prompt(user_message: str, data: dict[str, Any],
                    user_id: str | None = None) -> str:
    users = data.get("users", {})
    profile = users if isinstance(users, dict) else {}
    return (
        f"对话历史：{_format_history(user_id=user_id)}\n"
        f"用户输入：{user_message}\n"
        f"当前日期：{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}\n"
        f"用户信息：{json.dumps(users, ensure_ascii=False)}\n"
        f"用户学习目标：{json.dumps(profile.get('learningGoal', {}), ensure_ascii=False)}\n"
        f"用户空闲时间：{json.dumps(profile.get('time', {}), ensure_ascii=False)}\n"
        f"用户知识情况：{json.dumps(profile.get('knowledge', {}), ensure_ascii=False)}\n"
        f"候选人列表：{json.dumps(_load_json('mock_candidates.json', []), ensure_ascii=False)}"
    )


# --------------------------------------------------------------------------- JSON 提取
def extract_json(content: str) -> dict[str, Any] | None:
    """从 LLM 回复里提取 JSON，容忍 ```json 包裹与前后缀说明文字。"""
    text = (content or "").strip()
    if text.startswith("```"):
        first_newline = text.find("\n")
        if first_newline != -1:
            text = text[first_newline + 1:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            try:
                parsed = json.loads(text[start:end + 1])
                return parsed if isinstance(parsed, dict) else None
            except json.JSONDecodeError:
                return None
    return None


# --------------------------------------------------------------------------- 意图识别
def keyword_intent(message: str) -> str:
    """关键词意图回退。

    ⚠️ 规则顺序 = 优先级，**必须把具体意图排在笼统意图前面**。
    `get_suggestion` 的关键词（"计划""今天""复习""优先"）覆盖面很广，
    如果排在前面会把"帮我分析错题"这类消息抢走。原 B1 的顺序同样如此
    （错题/搭子 → 更新 → 任务 → 建议 → 薄弱），此处保持一致。
    """
    text = (message or "").lower()
    rules: list[tuple[str, tuple[str, ...]]] = [
        ("match_partner", ("搭子", "匹配", "伙伴", "搭档", "一起学", "组队")),
        ("analyze_wrong", ("这道题", "错题", "为什么错", "图片", "拍照")),
        ("update_profile", ("添加", "设置", "修改", "更新", "删除", "记录", "我掌握了", "学会了")),
        ("query_tasks", ("任务", "作业", "ddl", "待办", "要交", "安排", "有什么")),
        ("analyze_weakness", ("薄弱", "短板", "诊断", "弱", "查漏补缺", "哪里不好", "没掌握")),
        ("get_suggestion", ("建议", "推荐", "学什么", "计划", "复习", "优先", "今天")),
    ]
    for intent, words in rules:
        if any(word in text for word in words):
            return intent
    return "get_suggestion"


def detect_intent(message: str, has_image: bool = False) -> tuple[str, bool]:
    """返回 (意图, 是否由 LLM 判定)。LLM 不可用时退回关键词匹配。

    `has_image=True` 时**直接判定为 analyze_wrong**，不调用 LLM：

    用户上传了错题图片，他的意图毫无歧义就是"分析这道题"。
    此前这里只看文本，而文本往往是占位句（API 层把"只有图片没有文字"
    替换为「帮我分析这道题」），关键词表里没有"分析这道题"这个词，
    于是意图落到 `get_suggestion`，**`_call_llm_with_image()` 这条
    Qwen-VL 多模态链路永远不会被执行**——OCR 识图功能形同虚设。

    带图即错题，既省一次模型调用，又让多模态路径真正可达。
    """
    if has_image:
        return "analyze_wrong", True

    system_prompt = _load_prompt("MainAgentPrompt.txt")
    if not system_prompt or not llm_ready():
        return keyword_intent(message), False
    try:
        raw = _call_llm(
            system_prompt,
            "现在请分析用户输入，直接返回一个纯 JSON 对象，不要加任何 markdown 标记或解释文字：\n"
            f"用户输入：{message}",
            temperature=0,
            max_tokens=100,
        )
        parsed = extract_json(raw) or {}
        intent = str(parsed.get("intent", "")).strip()
        if intent in KNOWN_INTENTS:
            return intent, True
    except Exception as error:  # noqa: BLE001 - 聊天层必须降级而非抛错
        print(f"[chat] 意图识别失败，退回关键词匹配: {error}")
    return keyword_intent(message), False


# --------------------------------------------------------------------------- 子 Agent
def _handle_query_tasks(message: str, data: dict[str, Any],
             user_id: str | None = None) -> str:
    return _call_llm(_load_prompt("QueryTasksPrompt.txt"), _context_prompt(message, data, user_id))


def _handle_analyze_weakness(message: str, data: dict[str, Any],
             user_id: str | None = None) -> str:
    return _call_llm(_load_prompt("AnalyzeWeaknessPrompt.txt"), _context_prompt(message, data, user_id))


def _handle_get_suggestion(message: str, data: dict[str, Any],
             user_id: str | None = None) -> str:
    return _call_llm(_load_prompt("GetSuggestionPrompt.txt"), _context_prompt(message, data, user_id))


def _handle_match_partner(message: str, data: dict[str, Any],
             user_id: str | None = None) -> str:
    return _call_llm(_load_prompt("MatchPartnerPrompt.txt"), _partner_prompt(message, data, user_id))


def _handle_update_profile(message: str, data: dict[str, Any],
             user_id: str | None = None) -> str:
    raw = _call_llm(_load_prompt("UpdateProfilePrompt.txt"), _context_prompt(message, data, user_id),
                    response_json=True)
    return str((extract_json(raw) or {}).get("reply") or "已帮你更新信息。")


def _handle_analyze_wrong(message: str, data: dict[str, Any], image_base64: str | None,
                          user_id: str | None = None) -> str:
    if image_base64:
        # 走 Qwen-VL 多模态：现场拍照 → 真实识别知识点与错误类型
        system_prompt = (
            "你是一个专业的错题分析助手。根据用户提供的错题图片和文字信息，"
            "深入分析错误原因，定位知识点薄弱处，并给出可执行的补强建议。"
            "请用中文回答，控制在 200 字以内，先说结论再说建议。"
        )
        return _call_llm_with_image(system_prompt, _context_prompt(message, data, user_id), image_base64)

    raw = _call_llm(_load_prompt("AnalyzeWrongPrompt.txt"), _context_prompt(message, data, user_id),
                    response_json=True)
    parsed = extract_json(raw) or {}
    reply = str(parsed.get("reply") or raw or "").strip()
    analysis = parsed.get("analysis")
    if isinstance(analysis, dict) and analysis:
        analysis.setdefault("questionId", str(uuid.uuid4()))
        analysis.setdefault("userId", user_id or "demo-user")
        analysis.setdefault("createdAt", datetime.now().isoformat())
        questions = _load_json("mock_wrong_questions.json", [])
        if isinstance(questions, list):
            questions.append(analysis)
            # 必须走 `_mutable_path` 而不是 `_CHAT_DIR` —— 否则每跑一次测试/联调
            # 就往交付包这份文件里追加一条（队友那份实测累积到 26 项，
            # 比基线多出 11 项 `u001_UUID` 之类的测试数据）。
            _mutable_path("mock_wrong_questions.json").write_text(
                json.dumps(questions, ensure_ascii=False, indent=2), encoding="utf-8")
    return reply


_HANDLERS = {
    "query_tasks": _handle_query_tasks,
    "analyze_weakness": _handle_analyze_weakness,
    "get_suggestion": _handle_get_suggestion,
    "match_partner": _handle_match_partner,
    "update_profile": _handle_update_profile,
}


def build_card(intent: str) -> dict[str, Any] | None:
    template = INTENT_CARDS.get(intent)
    if template is None:
        return None
    title, target_page, action_label = template
    return {
        "type": intent,
        "title": title,
        "actionLabel": action_label,
        "targetPage": target_page,
    }


def chat(message: str, image_base64: str | None = None,
         frontend_data: dict[str, Any] | None = None,
         user_id: str | None = None) -> dict[str, Any]:
    """统一对话入口：返回 {reply, intent, card, llmUsed}。

    `llmUsed=False` 表示本次回复由本地确定性规则兜底（未配置 Key 或调用失败），
    调用方可据此在 API 环境页/日志里区分"真大模型"与"降级"，绝不静默伪装。

    `user_id` 用于**对话历史与上下文隔离**：不同用户的 `_format_history()`
    只看到自己的历史；缺省时退回演示身份（评委/curl 不带凭据也能跑通）。
    """
    message = (message or "").strip()
    if not message and image_base64:
        message = "帮我分析这道题"

    data = _user_data(frontend_data)
    intent, llm_used = detect_intent(message, has_image=bool(image_base64))

    reply = ""
    if llm_used:
        try:
            if intent == "analyze_wrong":
                reply = _handle_analyze_wrong(message, data, image_base64, user_id)
            else:
                handler = _HANDLERS.get(intent)
                if handler is not None:
                    reply = handler(message, data, user_id)
        except Exception as error:  # noqa: BLE001
            print(f"[chat] 子 Agent 调用失败，退回本地规则: {error}")
            llm_used = False
            reply = ""

    if not reply.strip():
        reply = _LOCAL_REPLY.get(intent, _LOCAL_REPLY["unknown"])
        if image_base64:
            reply = ("图片已收到。当前未接入多模态识别，请进入错题分析页手动确认知识点，"
                     "或在服务端配置 DASHSCOPE_API_KEY 后重试。")
        llm_used = False

    if not llm_used and llm_ready():
        # LLM 已配置但本次调用失败：诚实说明，不伪装成模型输出
        reply += "\n\n（提示：本次大模型调用失败，已降级为本地确定性规则回复。）"
    elif not llm_ready():
        reply += _LOCAL_NOTICE

    if message:
        try:
            append_history(message, reply, user_id)
        except OSError:
            pass

    return {
        "reply": reply,
        "intent": intent,
        "card": build_card(intent),
        "llmUsed": llm_used,
    }
