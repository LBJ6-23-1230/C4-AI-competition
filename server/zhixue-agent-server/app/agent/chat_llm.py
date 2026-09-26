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
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

_BASE_DIR = Path(__file__).resolve().parent
_CHAT_DIR = _BASE_DIR.parent.parent / "chat"
_PROMPT_DIR = _CHAT_DIR / "prompts"

# 对话历史是"读—改—写"整文件操作，而 Flask 默认多线程处理请求。
# 不加锁时两个并发 append 会各读一份旧内容、再各写一份，
# 后写的把先写的整段覆盖掉（丢历史）；更糟的是 `write_text` 不是原子操作，
# 并发写会写出**半截 JSON**，于是 `_load_json` 抛 JSONDecodeError 被吞成 `{}`，
# 该用户的历史**静默全部消失**。
# 实测：12 线程 × 4 次 append_history → 文件损坏、get_history 返回 0 条。
# 这里用模块级锁 + `os.replace` 原子落盘双管齐下：
#   锁 解决同一进程内的丢更新，`os.replace` 解决"写到一半被读到"。
_HISTORY_LOCK = threading.RLock()

#: 画像落盘钩子：由 `app/api/chat.py` 注册（那里才持有 repository）。
#:
#: 为什么用钩子而不是直接 import repository：本模块是**纯对话层**，
#: 不应依赖持久化边界（否则单元测试不得不构造仓库）。
#: 签名 `(user_id, updates) -> list[str]`，返回**实际写入成功的字段名列表**，
#: 供回复文案如实说明"改了什么"。未注册时按"无法落盘"处理（不再谎称成功）。
_PROFILE_UPDATE_HOOK: Any = None


def set_profile_update_hook(hook: Any) -> None:
    """注册画像落盘钩子（由 api 层在 create_app 时调用）。"""
    global _PROFILE_UPDATE_HOOK
    _PROFILE_UPDATE_HOOK = hook


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


# 意图 → (标题, 卡片描述, 兜底跳转页, 按钮文案)
#
# ⚠️ 第二个字段（卡片描述）是后补的。原先只有三元组，`build_card()` 也只输出
# `type/title/actionLabel/targetPage` —— 但前端 `AgentBridge.parseCard()`
# 一直在读 `card['summary']` 并渲染在卡片描述行上。字段不存在时
# `stringField()` 返回空串，于是**联机模式下卡片的描述行恒为空白**
# （离线 Fixture 的数据带 summary，呈现"离线好看、联机消失"的假象）。
# 详见审计报告的 P1-2。
INTENT_CARDS: dict[str, tuple[str, str, str, str]] = {
    "analyze_wrong": ("错题分析", "定位错因与薄弱知识点，给出补强建议",
                      "pages/WrongQuestion", "查看错题分析"),
    "query_tasks": ("今日任务", "按截止时间与优先级排好的待办清单",
                    "pages/StudyPlan", "查看任务清单"),
    "analyze_weakness": ("薄弱点诊断", "汇总错题证据，指出最该补的知识点",
                         "pages/StudyTags", "查看薄弱画像"),
    "match_partner": ("学习搭子", "按目标、时间与知识互补度匹配同伴",
                      "pages/PartnerMatch", "查看搭子详情"),
    "update_profile": ("学习画像", "目标、时间与掌握度的当前状态",
                       "pages/StudyTags", "查看学习画像"),
    "get_suggestion": ("学习建议", "结合考试倒计时给出的下一步行动",
                       "pages/StudySuggestion", "查看今日建议"),
}

# 前端 ChatModels 的 ChatIntent 取值（free_chat 为前端自有）
KNOWN_INTENTS = tuple(INTENT_CARDS.keys())

# LLM 允许返回的意图集合 = 6 个可落地意图 + unknown。
#
# ⚠️ 为什么必须单独加 unknown（否则是个会伪装成"模型故障"的坑）：
#   `MainAgentPrompt.txt` 明确要求模型「不属于上述 6 种就返回 {"intent":"unknown"}」
#   （见 prompt 第 84、127 行），`_LOCAL_REPLY` 也为 unknown 备了兜底文案。
#   但若 unknown 不在受理集合里，模型**依指令正确返回 unknown** 时会被判为
#   "意图识别失败" → 丢弃结果 → 退回关键词匹配 → `llm_used=False`
#   → 用户看到"本次大模型调用失败"，而模型其实刚刚成功响应过。
#   这是**对模型成功结果的误报**，违反本项目"诚实降级、不伪装"的原则。
LLM_ACCEPTED_INTENTS = KNOWN_INTENTS + ("unknown",)

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


def _call_llm_with_image(system_prompt: str, user_prompt: str, image_base64: str,
                         response_json: bool = False) -> str:
    """Qwen-VL 多模态调用：错题拍照识别链路。"""
    model = llm_vl_model()
    image_url = (
        f"data:{_image_mime_type(image_base64)};base64,{image_base64}")
    kwargs: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": [
                {"type": "image_url",
                 "image_url": {"url": image_url}},
                {"type": "text", "text": user_prompt},
            ]},
        ],
        "temperature": 0.7,
        "max_tokens": 800,
    }
    if response_json:
        kwargs["response_format"] = {"type": "json_object"}
    response = _client().chat.completions.create(**kwargs)
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
    """原子写盘：先写同目录临时文件，再 `os.replace` 覆盖目标。

    为什么不能直接 `write_text`：Flask 多线程下并发写同一个文件时，
    另一个线程可能读到"写了一半"的内容，`json.loads` 抛错后被降级成 `{}`，
    表现为**对话历史静默清空**（且没有任何日志线索）。
    `os.replace` 在同一文件系统内是原子的，读方要么看到旧内容、要么看到新内容。
    """
    path = _history_path()
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}.{threading.get_ident()}")
    with _HISTORY_LOCK:
        tmp.write_text(json.dumps(store, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)


def get_history(user_id: str | None = None) -> list[dict[str, Any]]:
    """读取**指定用户**的对话历史；`user_id` 缺省取演示身份。"""
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    with _HISTORY_LOCK:
        return _load_history_store().get(key, [])


def clear_history(user_id: str | None = None) -> None:
    """清空**指定用户**的历史，不动其他用户。"""
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    with _HISTORY_LOCK:
        store = _load_history_store()
        if key in store:
            store[key] = []
            _write_history_store(store)


def append_history(user_input: str, bot_response: str,
                   user_id: str | None = None) -> None:
    key = (user_id or DEFAULT_HISTORY_USER).strip() or DEFAULT_HISTORY_USER
    # 读—改—写必须在**同一把锁**内完成，否则并发 append 会互相覆盖（丢历史）。
    with _HISTORY_LOCK:
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


def _user_data(frontend_data: dict[str, Any] | None,
               user_context: dict[str, Any] | None = None) -> dict[str, Any]:
    """组装喂给模型的上下文。

    `users` 一节**优先用调用方传入的真实身份资料** `user_context`（由 API 层按
    当前登录身份组装）；只有在它为空的场景（游客 / 演示 / 直接调用对话层）才回落
    `chat/mock_users.json`。

    ⚠️ 为什么必须这样：原实现无条件读 mock_users.json，里面是写死的
    `u001 / 小明 / weakness: ['二叉树遍历','递归理解']` —— 于是**任何账号**聊天，
    模型都会把用户当成"小明"、张口就"二叉树遍历"。这是实测反馈
    「怎么一直在小明」「默认不要直接说我掌握了二叉树遍历」的根因。
    """
    users = (user_context if isinstance(user_context, dict) and user_context
             else _load_json("mock_users.json", {}))
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
        if intent in LLM_ACCEPTED_INTENTS:
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
    """搭子匹配：**分数一律由确定性代码算**，大模型只负责解释。

    ## 原缺陷

    `MatchPartnerPrompt.txt` 把整套打分规则（总分 100：目标 30 / 时间重叠 30 /
    知识互补 20 / 基础 10 / 稳定性 10）写进 prompt 让模型算分，而同一套规则在
    `app/agent/partner_match.py:62-81` 已有确定性实现。于是同一个问题在
    `/api/agent/chat`（模型给分，每次可能不同、可能算错时间重叠）与
    `/api/v1/agent/partner-match`（确定性给分）**会返回互相矛盾的分数**，
    直接违反项目纪律第 1 条："业务计算必须留在确定性代码里，不进入 prompt"。

    ## 修复

    先用 `score_partner` / `match_partners` 算出权威排名与分项得分，
    再把**结果**注入 prompt，让模型只做"用自然语言解释为什么是这个人"
    这件事。prompt 里的打分规则已删除（见 MatchPartnerPrompt.txt）。
    """
    authoritative = _authoritative_partner_scores(data)
    prompt = _partner_prompt(message, data, user_id)
    if authoritative:
        prompt = (
            f"{prompt}\n\n"
            f"【已由确定性引擎算好的匹配结果（**直接引用，不要自己重新算分**）】\n"
            f"{json.dumps(authoritative, ensure_ascii=False)}\n"
            f"请基于这份结果说明：为什么是这个人、哪几项匹配得好、建议怎么一起学。"
            f"若用户问分数，必须原样引用上面的总分与分项分，不得改动。"
        )
    return _call_llm(_load_prompt("MatchPartnerPrompt.txt"), prompt)


def _authoritative_partner_scores(data: dict[str, Any]) -> dict[str, Any]:
    """用确定性引擎算出搭子排名；数据不足时返回空 dict（不猜）。"""
    from app.agent.partner_match import match_partners  # 局部导入，避免循环依赖

    user = data.get("users")
    if not isinstance(user, dict) or not user:
        return {}
    candidates = _load_json("mock_candidates.json", [])
    if not isinstance(candidates, list) or not candidates:
        return {}
    valid = [item for item in candidates if isinstance(item, dict)]
    if not valid:
        return {}
    try:
        result = match_partners(user, valid)
    except Exception as error:  # noqa: BLE001 - 算分失败就退回纯自然语言解释
        print(f"[chat] 搭子确定性匹配失败: {error}")
        return {}
    best = result.get("matchedCandidate")
    if not isinstance(best, dict):
        return {}
    factors = best.get("factors") if isinstance(best.get("factors"), dict) else {}
    return {
        "总分": best.get("score"),
        "分项得分": factors,
        "被选中同学": (best.get("candidate") or {}).get("basicInfo")
            if isinstance(best.get("candidate"), dict) else None,
        "全部候选人排名": [
            {"score": item.get("score"),
             "name": ((item.get("candidate") or {}).get("basicInfo") or {}).get("name")
                if isinstance(item.get("candidate"), dict) else None}
            for item in (result.get("candidates") or [])
            if isinstance(item, dict)
        ],
    }


#: 用户"自称已掌握"的常见说法。命中后**不会**直接采信，先拿真实掌握度对一遍。
_MASTERY_CLAIM_VERBS = ("掌握了", "我学会", "学会了", "已经掌握", "学懂了", "搞懂了")


def _claimed_knowledge_name(text: str, rows: list) -> str:
    """从用户这句话里，找出他自称掌握的那个知识点在**画像里的名字**。

    匹配规则与 `exercises.py` 的知识点容错**同源**（先精确包含，再共同前缀 ≥2 字）：
    用户口语说"二叉树遍历"，而档案里写的是"二叉树后序遍历" ——
    两个名字**互不包含**，只有共同前缀能认出来。实测第一版就是卡在这里没生效。
    """
    names: list[str] = []
    for row in rows:
        if isinstance(row, dict):
            name = str(row.get("knowledgePointName") or "").strip()
            if len(name) >= 2:
                names.append(name)
    for name in names:
        if name in text:
            return name
    for name in names:
        for size in range(len(name), 1, -1):
            if name[:size] in text:
                return name
    return ""


def _mastery_claim_gate(message: str, data: dict[str, Any]) -> str | None:
    """用户自称"我掌握了 X"时，先拿**真实掌握度**对一遍，再决定认不认。

    实测反馈（原话）：「不能用户说自己掌握了你就直接更新画像，要你自己去看他的
    掌握程度，真的掌握了再进行更新，如果没有掌握就再次给用户提醒，练习相关题目」。

    返回一句**如实**的回复文案（调用方此时**不得**再宣称已更新掌握度）；
    判定不了、或不构成"自述掌握"时返回 None，按原流程走。

    依据是 `user_context.mastery`（由 API 层按**真实画像**组装，见
    `app/api/chat.py::_user_context_for`）—— 没有真实数据时不做任何断言。
    """
    text = message or ""
    if not any(verb in text for verb in _MASTERY_CLAIM_VERBS):
        return None
    users = data.get("users") if isinstance(data, dict) else None
    rows = users.get("mastery") if isinstance(users, dict) else None
    if not isinstance(rows, list) or not rows:
        return None

    name = _claimed_knowledge_name(text, rows)
    if not name:
        # 画像里对不上任何知识点 —— **同样不能凭一句话就认**。
        return ("这条我先不记成「已掌握」—— 学习档案里还没有这个知识点的练习记录，"
                "只凭一句话我不能改掌握度。\n"
                "建议先做几道相关题目，做完我会按**实际答题结果**更新掌握度。")

    score: float | None = None
    for row in rows:
        if isinstance(row, dict) and str(row.get("knowledgePointName") or "").strip() == name:
            value = row.get("masteryScore")
            if isinstance(value, (int, float)):
                score = float(value)
            break
    if score is None:
        return None
    if score >= 80:
        return (f"「{name}」在你的练习记录里已经是优势知识点（掌握度 {score:.0f}/100），"
                f"档案里本来就记着，不用再加一遍～")
    return (f"「{name}」我先不记成「已掌握」—— 你目前的练习记录显示它的掌握度是 "
            f"{score:.0f}/100，还不算真的掌握。\n"
            f"建议先做 3 道同类题验证一下：做完我会按**实际答题结果**更新掌握度，"
            f"真的达到水平就会自动进优势知识点。")


def _handle_update_profile(message: str, data: dict[str, Any],
             user_id: str | None = None) -> tuple[str, dict[str, Any]]:
    """解析画像更新意图，**真正落盘**后端拥有的字段，并如实区分"已改/未改"。

    ## 原缺陷

    实现只取 `reply`，把模型按 `UpdateProfilePrompt.txt` 返回的整个 `updates`
    对象**整份丢弃**，且 `chat()` 全链路没有任何 repository 写入口。
    于是用户说"把考试改到 28 号"会得到回复"已帮你更新信息。"——
    但 `profiles` / 课程数据一字未改。这是**静默 no-op + 假成功**：
    用户与评审都以为生效了。

    ## 修复思路（为什么不是"把 updates 全写进去"）

    数据结构上，后端 `profiles` 集合只拥有 `goal` / `examDate` /
    `freeTimeSlots` / `mastery` 四个字段；**课程与任务列表是前端本地数据**
    （`repository.json` 里根本没有 `courses` 集合，前端通过 `user_data` 传进来）。
    所以"课程/任务类更新"后端接不住，硬写只会写到一个没人读的地方。

    因此这里分两步：
      1. 用 `_apply_profile_updates()` 把**后端确实拥有**的字段落盘
      2. 其余（课程/任务）通过返回值交给**前端**去应用 —— 这也正是
         prompt 设计"返回 updates 而不是最终文案"的本意
    并把"实际改了什么"回传，让回复文案有据可依，而不是无条件宣称成功。
    """
    raw = _call_llm(_load_prompt("UpdateProfilePrompt.txt"), _context_prompt(message, data, user_id),
                    response_json=True)
    parsed = extract_json(raw) or {}
    reply = str(parsed.get("reply") or "").strip()
    updates = parsed.get("updates")
    if not isinstance(updates, dict):
        updates = {}

    # ★ 掌握度自述闸：用户说"我掌握了 X"**不能直接采信** —— 先拿真实掌握度对一遍。
    # 刻意**不在这里提前返回**：同一句话里其它可写字段（学习目标 / 空闲时间 / 考试日期）
    # 仍应正常生效，被拦下的只是"凭一句话就把知识点记成已掌握"这一件事。
    claim_reply = _mastery_claim_gate(message, data)

    applied: list[str] = []
    if updates and _PROFILE_UPDATE_HOOK is not None:
        try:
            applied = _PROFILE_UPDATE_HOOK(user_id, updates) or []
        except Exception as error:  # noqa: BLE001 - 落盘失败不能打断对话
            print(f"[chat] 画像更新落盘失败: {error}")

    # 课程/任务类更新后端接不住 —— 必须如实说明，不能默认"都改好了"
    course_updates = updates.get("course")
    has_course_updates = isinstance(course_updates, list) and len(course_updates) > 0
    user_updates = updates.get("user")
    has_user_updates = isinstance(user_updates, dict) and len(user_updates) > 0

    if applied:
        reply = (reply or "已更新。") + f"\n\n（已写入学习档案：{'、'.join(applied)}。）"
    elif has_user_updates and not has_course_updates:
        # 模型给了用户档案更新，但没有一个字段是后端拥有的（例如只改了姓名/专业）。
        # ⚠️ 原文案是"（这部分档案字段由 App 本地保存，服务端不持有。）" —— 那是
        # **内部实现说明**，实测反馈明确要求「有的东西不要写给用户直接看」，改写成人话。
        reply = (reply or "已记下。") + "\n\n这些信息只保存在本机 App 里。"
    if has_course_updates:
        reply += "\n\n课程与任务已同步到 App，请以 App 内显示为准。"

    if claim_reply is not None:
        # 掌握度自述不采信：回复以闸门文案为准（它已如实说明），
        # 并向用户交代同一句话里其它字段实际改了什么。
        tail = f"\n\n（另外已更新：{'、'.join(applied)}。）" if applied else ""
        return claim_reply + tail, updates

    return reply or "我理解你想更新档案，但没解析出可写入的字段，能再说具体一点吗？", updates


def _handle_analyze_wrong(message: str, data: dict[str, Any], image_base64: str | None,
                          user_id: str | None = None) -> str:
    if image_base64:
        # 走 Qwen-VL 多模态：现场拍照 → 真实识别知识点与错误类型。
        #
        # ⚠️ 改成**要 JSON**（原来只回一段自然语言）。原因：自然语言答复里
        # 的知识点没法被程序使用 —— 而"拍一道错题 → 针对这个知识点练"这条闭环
        # 需要把知识点**结构化地带出去**（前端拿它去请求对应题集 / 现场出题）。
        # 答复文本仍然照常返回（放在 `reply` 里），只是多带两个字段。
        system_prompt = (
            "你是一个专业的错题分析助手。根据用户提供的错题图片和文字信息，"
            "深入分析错误原因，定位知识点薄弱处，并给出可执行的补强建议。"
            "**只输出 JSON，不要任何解释性文字或 markdown 代码块。**"
        )
        user_prompt = (
            _context_prompt(message, data, user_id)
            + "\n\n请输出这样的 JSON："
              "{\"reply\":\"不超过 200 字的分析，先说结论再说建议\","
              "\"knowledgePoint\":\"这道题考查的知识点名称，4-12 个字，"
              "例如「哈希表」「二叉树遍历」「图算法」；图片看不清或判断不了就填空字符串\","
              "\"wrongType\":\"错误类型，例如「概念混淆」「顺序记反」「计算失误」；不确定填空字符串\"}"
        )
        raw = _call_llm_with_image(system_prompt, user_prompt, image_base64, response_json=True)
        parsed = extract_json(raw) or {}
        reply = str(parsed.get("reply") or raw or "").strip()
        point = str(parsed.get("knowledgePoint") or "").strip()
        wrong_type = str(parsed.get("wrongType") or "").strip()
        return reply, ({"knowledgePoint": point, "wrongType": wrong_type} if point else {})

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
    # 无图这条路径：从 `analysis` 里取知识点（模型按 prompt 返回的结构化结果）
    point = ""
    if isinstance(analysis, dict):
        raw_point = analysis.get("knowledgePoint") or analysis.get("knowledge") or ""
        if isinstance(raw_point, list):
            raw_point = raw_point[0] if raw_point else ""
        point = str(raw_point).strip()
    return reply, ({"knowledgePoint": point} if point else {})


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
    title, summary, target_page, action_label = template
    return {
        "type": intent,
        "title": title,
        # `summary` 必须输出：前端 `AgentBridge.parseCard()` 读它并渲染在
        # 卡片描述行；缺了就是一片空白（见 INTENT_CARDS 的注释）。
        "summary": summary,
        "actionLabel": action_label,
        "targetPage": target_page,
    }


def chat(message: str, image_base64: str | None = None,
         frontend_data: dict[str, Any] | None = None,
         user_id: str | None = None,
         user_context: dict[str, Any] | None = None) -> dict[str, Any]:
    """统一对话入口：返回 {reply, intent, card, llmUsed}。

    `llmUsed=False` 表示本次回复由本地确定性规则兜底（未配置 Key 或调用失败），
    调用方可据此在 API 环境页/日志里区分"真大模型"与"降级"，绝不静默伪装。

    `user_id` 用于**对话历史与上下文隔离**：不同用户的 `_format_history()`
    只看到自己的历史；缺省时退回演示身份（评委/curl 不带凭据也能跑通）。

    `user_context` 是**当前身份的真实资料**（昵称 / 年级 / 由掌握度推出的薄弱点与强项），
    由 API 层组装后传入。不传或为空时回落 `chat/mock_users.json` 的演示用户 ——
    那条回落路径此前被无条件使用，导致模型照着"小明 + 二叉树遍历"回话。
    """
    message = (message or "").strip()
    if not message and image_base64:
        message = "帮我分析这道题"

    data = _user_data(frontend_data, user_context)
    intent, llm_used = detect_intent(message, has_image=bool(image_base64))

    reply = ""
    profile_updates: dict[str, Any] = {}
    wrong_analysis: dict[str, Any] = {}
    llm_attempted = llm_used  # 模型的意图判定是否真的成功（后续据此决定能否说"调用失败"）
    if llm_used:
        try:
            if intent == "analyze_wrong":
                reply, wrong_analysis = _handle_analyze_wrong(message, data, image_base64, user_id)
            elif intent == "update_profile":
                # 该 handler 额外返回解析出的 updates（供前端应用课程/任务类改动），
                # 所以单独处理，不走 `_HANDLERS` 的"返回字符串"约定。
                reply, profile_updates = _handle_update_profile(message, data, user_id)
            else:
                handler = _HANDLERS.get(intent)
                if handler is not None:
                    reply = handler(message, data, user_id)
        except Exception as error:  # noqa: BLE001
            print(f"[chat] 子 Agent 调用失败，退回本地规则: {error}")
            llm_used = False
            llm_attempted = False
            reply = ""
            profile_updates = {}

    if not reply.strip():
        reply = _LOCAL_REPLY.get(intent, _LOCAL_REPLY["unknown"])
        if image_base64:
            reply = ("图片已收到。当前未接入多模态识别，请进入错题分析页手动确认知识点，"
                     "或在服务端配置 DASHSCOPE_API_KEY 后重试。")
            llm_attempted = False
        # ⚠️ 只有"模型调用确实失败"才把 llmUsed 置 False。
        # `unknown` 是模型**依 prompt 正确返回**的兜底意图（prompt 第 84/127 行），
        # 它没有对应子 Agent handler，因此 reply 为空、落到 `_LOCAL_REPLY["unknown"]`。
        # 若此处不加区分地置 False，`/api/agent/chat` 就会回复
        # "本次大模型调用失败" —— 而模型其实刚刚成功响应过，属于**对成功结果的误报**。
        llm_used = llm_attempted

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
        # 仅 `update_profile` 意图下非空。前端据此把**课程/任务**类改动应用到
        # 本地 AppState（后端不持有 courses 集合），使画像更新真正闭环。
        "profileUpdates": profile_updates,
        # 仅 `analyze_wrong` 意图下可能非空：错题分析识别出的**结构化**知识点。
        # 前端拿它去请求对应题集（题库命中就用题库，没命中就现场出题），
        # 从而把「拍一道错题 → 针对这个知识点练 → 判分反馈」接成闭环。
        # 识别不出时为空 dict —— 前端据此如实回落，不编造知识点。
        "wrongAnalysis": wrong_analysis,
    }
