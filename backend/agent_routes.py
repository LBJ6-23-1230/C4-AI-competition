# -*- coding: utf-8 -*-
"""
知学搭子 Agent 后端服务
- 意图识别：LLM (MainAgentPrompt)
- 6意图处理：各子Prompt + LLM生成回复
- 对话历史管理
- 用户/课程/错题数据管理
- 支持文本、语音（转文字后）、图片（Qwen-VL或文字描述）
"""
import os
import json
import time
import uuid
from datetime import datetime
from flask import Blueprint, request, jsonify
from dotenv import load_dotenv
from v1_routes import CONTRACT_VERSION

# 加载 .env 文件
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

# ===== LLM Config =====
LLM_API_KEY = os.getenv("DASHSCOPE_API_KEY", "")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen-plus")

# 如果使用 DeepSeek 或其他 OpenAI 兼容 API，修改以上环境变量即可
# DeepSeek: base_url=https://api.deepseek.com/v1, model=deepseek-chat

agent_bp = Blueprint('agent', __name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ===== File Paths =====
def _prompt_path(filename):
    return os.path.join(BASE_DIR, "prompts", filename)

def _data_path(filename):
    return os.path.join(BASE_DIR, filename)

# ===== LLM Client =====
def _get_llm_client():
    """延迟导入，避免未安装 openai 包时启动失败"""
    import openai
    return openai.OpenAI(api_key=LLM_API_KEY, base_url=LLM_BASE_URL)

def _call_llm(system_prompt, user_prompt, temperature=0.7, max_tokens=800, response_json=False):
    """通用 LLM 调用"""
    client = _get_llm_client()
    kwargs = {
        "model": LLM_MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if response_json:
        kwargs["response_format"] = {"type": "json_object"}
    response = client.chat.completions.create(**kwargs)
    return response.choices[0].message.content

def _call_llm_with_image(system_prompt, user_prompt, image_base64=None, image_url=None):
    """
    带图片的 LLM 调用（Qwen-VL 多模态）
    如果 API Key 未就绪，回退到纯文本模式
    """
    if not LLM_API_KEY:
        # 回退：将图片标记为"用户上传了图片"，让纯文本模型尽力处理
        return _call_llm(system_prompt, user_prompt + "\n\n[用户上传了一张图片，但目前图片分析功能暂未启用。请基于文字信息给出分析，并提示用户图片功能即将上线。]")

    client = _get_llm_client()
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": []}
    ]

    user_content = messages[1]["content"]
    if image_base64:
        user_content.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}
        })
    elif image_url:
        user_content.append({
            "type": "image_url",
            "image_url": {"url": image_url}
        })

    user_content.append({"type": "text", "text": user_prompt})

    image_model: str = LLM_MODEL
    if "qwen" in LLM_MODEL.lower():
        image_model = "qwen-vl-plus"  # Qwen系列用VL模型看图
    response = client.chat.completions.create(
        model=image_model,
        messages=messages,
        temperature=0.7,
        max_tokens=800,
    )
    return response.choices[0].message.content

# ===== Data Loading =====
# 前端传过来的真实数据覆盖
_frontend_override_data = None

def load_user_data():
    """加载用户数据（优先使用前端传来的真实数据）"""
    global _frontend_override_data
    if _frontend_override_data and _frontend_override_data.get("isDataImported"):
        courses = _frontend_override_data.get("courses", [])
        ddls = _frontend_override_data.get("homeworkDDLs", [])
        # 把前端数据转成后端格式
        if courses:
            return {"users": _load_json("mock_users.json"), "courses": _format_frontend_courses(courses, ddls)}
    return {"users": _load_json("mock_users.json"), "courses": _load_json("mock_courses.json")}

def _format_frontend_courses(courses, ddls):
    """把前端 CourseInfo[] + HomeworkDDL[] 转成后端 Prompt 可用的格式"""
    result = []
    for c in courses:
        if not isinstance(c, dict):
            continue
        course_name = c.get("courseName", "")
        # 前端 CourseInfo.exam 是 {date, daysLeft}
        exam = c.get("exam", {}) or {}
        exam_date = exam.get("date", "") if isinstance(exam, dict) else ""
        exam_days = exam.get("daysLeft", 0) if isinstance(exam, dict) else 0
        # 前端 CourseInfo.recentStatus 是 {studyHours, status}
        rs = c.get("recentStatus", {}) or {}
        study_hours = rs.get("studyHours", 0) if isinstance(rs, dict) else 0
        status = rs.get("status", "") if isinstance(rs, dict) else ""
        priority = c.get("priority", "中")

        # 找这个课程对应的 DDL
        tasks = []
        if isinstance(ddls, list):
            for d in ddls:
                if isinstance(d, dict) and d.get("courseName", "") == course_name:
                    tasks.append({
                        "taskname": d.get("title", ""),
                        "deadline": d.get("dueDate", "")
                    })

        result.append({
            "courseName": course_name,
            "exam": {"date": exam_date, "daysLeft": exam_days},
            "priority": priority,
            "recentStatus": {"studyHours": study_hours, "status": status},
            "tasks": tasks
        })
    return result if result else _load_json("mock_courses.json")

def load_candidate_data():
    """加载候选搭子数据"""
    return _load_json("mock_candidates.json")

def load_wrong_questions():
    """加载错题列表"""
    return _load_json("mock_wrong_questions.json", default=[])

def save_wrong_questions(questions):
    """保存错题列表"""
    _save_json("mock_wrong_questions.json", questions)

def _load_json(filename, default=None):
    path = _data_path(filename)
    if not os.path.exists(path):
        return default if default is not None else {}
    with open(path, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except json.JSONDecodeError:
            return default if default is not None else {}

def _save_json(filename, data):
    path = _data_path(filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def load_prompt_file(filename):
    """加载 Prompt 模板文件"""
    path = _prompt_path(filename)
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()

# ===== History Management =====
def get_history():
    history_path = _data_path("history.json")
    if not os.path.exists(history_path):
        return []
    with open(history_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            return []
    return data if isinstance(data, list) else []

def save_history_entry(user_input, bot_response):
    history_path = _data_path("history.json")
    history = get_history()
    history.append({
        "user_input": user_input,
        "bot_response": bot_response,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    })
    # 只保留最近 50 条
    if len(history) > 50:
        history = history[-50:]
    with open(history_path, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=2)

def format_history(num_entries=10):
    """格式化历史对话为文本"""
    history = get_history()
    formatted = ""
    for entry in history[-num_entries:]:
        formatted += f"用户: {entry.get('user_input', '')}\n知学搭子: {entry.get('bot_response', '')}\n"
    return formatted

# ===== Intent Detection =====
def detect_intent(user_message):
    """通过 LLM 识别用户意图"""
    system_prompt = load_prompt_file("MainAgentPrompt.txt")
    if not system_prompt:
        # 回退：关键词匹配
        return _keyword_intent(user_message)

    try:
        result = _call_llm(
            system_prompt,
            f"现在请分析用户输入，直接返回一个纯 JSON 对象，不要加任何 markdown 标记或解释文字：\n用户输入：{user_message}",
            temperature=0,
            max_tokens=100,
            response_json=False  # MaaS 端点可能不支持 json_object mode
        )
        intent_data = _extract_json(result)
        return intent_data.get("intent", "unknown") if intent_data else "unknown"
    except Exception as e:
        print(f"意图识别失败，使用关键词回退: {e}")
        return _keyword_intent(user_message)

def _keyword_intent(message):
    """关键词回退（当 LLM 不可用时）"""
    msg = message.lower()
    if any(w in msg for w in ['搭子', '匹配', '伙伴', '搭档', '一起学', '组队']):
        return 'match_partner'
    if any(w in msg for w in ['这道题', '错题', '为什么错', '图片', '拍照']):
        return 'analyze_wrong'
    if any(w in msg for w in ['添加', '设置', '修改', '更新', '删除', '记录', '我掌握了']):
        return 'update_profile'
    if any(w in msg for w in ['任务', '作业', 'ddl', '待办', '要交', '安排', '有什么']):
        return 'query_tasks'
    if any(w in msg for w in ['建议', '推荐', '学什么', '计划', '复习', '优先']):
        return 'get_suggestion'
    if any(w in msg for w in ['薄弱', '短板', '诊断', '弱', '查漏补缺', '哪里不好']):
        return 'analyze_weakness'
    return 'get_suggestion'  # 默认

def _extract_json(content):
    """从 LLM 回复中提取 JSON（处理 Markdown 代码块包裹）"""
    # 去掉 Markdown 代码块包裹
    text = content.strip()
    if text.startswith("```"):
        # 找到第一个换行后的内容
        first_newline = text.find("\n")
        if first_newline != -1:
            text = text[first_newline + 1:]
        # 去掉结尾的 ```
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                return None
    return None

# ===== Data Formatting =====
def format_task_lines(courses):
    """格式化任务列表"""
    current_date = datetime.now().date()
    task_lines = []
    course_items = courses if isinstance(courses, list) else [courses]
    for course in course_items:
        if not isinstance(course, dict):
            continue
        course_name = course.get("courseName", "未知课程")
        for idx, task in enumerate(course.get("tasks", []), start=1):
            deadline = task.get("deadline", "")
            if deadline:
                try:
                    dl_date = datetime.strptime(deadline, "%Y-%m-%d").date()
                    days_diff = (dl_date - current_date).days
                    status = "今天截止" if days_diff == 0 else f"倒计时{days_diff}天" if days_diff > 0 else f"已过期{abs(days_diff)}天"
                except:
                    status = "未知"
            else:
                status = "未知"
            task_lines.append(
                f"{idx}. {course_name}：{task.get('taskname', '未知任务')}（DDL: {deadline}，{status}）"
            )
    return task_lines

def build_context_prompt(user_message, extra_context=None):
    """构建包含用户数据上下文的 Prompt"""
    user_data = load_user_data()
    candidate_data = load_candidate_data()
    task_lines = format_task_lines(user_data.get("courses", {}))
    history_text = format_history(10)

    prompt = f"""对话历史：{history_text}
用户输入：{user_message}
当前日期：{time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())}
用户信息：{json.dumps(user_data.get('users', {}), ensure_ascii=False)}
课程信息：{json.dumps(user_data.get('courses', {}), ensure_ascii=False)}
任务列表：{chr(10).join(task_lines) if task_lines else '暂无任务'}"""

    if extra_context:
        prompt += f"\n{extra_context}"

    return prompt

def build_partner_prompt(user_message):
    """构建搭子匹配专用 Prompt"""
    user_data = load_user_data()
    candidate_data = load_candidate_data()
    history_text = format_history(10)
    users = user_data.get('users', {})

    return f"""对话历史：{history_text}
用户输入：{user_message}
当前日期：{time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())}
用户信息：{json.dumps(users, ensure_ascii=False)}
用户学习目标：{json.dumps(users.get('learningGoal', {}), ensure_ascii=False)}
用户空闲时间：{json.dumps(users.get('time', {}), ensure_ascii=False)}
用户知识情况：{json.dumps(users.get('knowledge', {}), ensure_ascii=False)}
候选人列表：{json.dumps(candidate_data, ensure_ascii=False)}"""

# ===== Intent Handlers =====
def handle_query_tasks(user_message, **kwargs):
    prompt = build_context_prompt(user_message)
    reply = _call_llm(
        load_prompt_file("QueryTasksPrompt.txt"),
        prompt
    )
    return reply, {"type": "tasks", "targetPage": "pages/CourseImport"}

def handle_analyze_weakness(user_message):
    prompt = build_context_prompt(user_message)
    reply = _call_llm(
        load_prompt_file("AnalyzeWeaknessPrompt.txt"),
        prompt
    )
    return reply, {"type": "weakness", "targetPage": "pages/StudyTags"}

def handle_get_suggestion(user_message):
    prompt = build_context_prompt(user_message)
    reply = _call_llm(
        load_prompt_file("GetSuggestionPrompt.txt"),
        prompt
    )
    return reply, {"type": "suggestion", "targetPage": "pages/StudySuggestion"}

def handle_match_partner(user_message):
    prompt = build_partner_prompt(user_message)
    reply = _call_llm(
        load_prompt_file("MatchPartnerPrompt.txt"),
        prompt
    )
    return reply, {"type": "partner", "targetPage": "pages/PartnerMatch"}

def handle_analyze_wrong(user_message, image_base64=None):
    """错题分析 - 支持图片（Qwen-VL）或纯文本"""
    prompt = build_context_prompt(user_message)

    if image_base64 and LLM_API_KEY:
        # 使用 Qwen-VL 多模态分析
        system_prompt = "你是一个专业的错题分析助手。根据用户提供的错题图片和文字信息，深入分析错误原因，定位知识点薄弱处，并给出可执行的补强建议。"
        reply = _call_llm_with_image(system_prompt, prompt, image_base64=image_base64)
    else:
        # 纯文本模式：详细的 Prompt 文件作为 system prompt
        system_prompt = load_prompt_file("AnalyzeWrongPrompt.txt")
        reply = _call_llm(
            system_prompt,
            prompt,
            response_json=True
        )
        # 尝试解析 JSON 回复
        result = _extract_json(reply)
        if result:
            reply = result.get("reply", reply)
            analysis = result.get("analysis", {})
            if analysis:
                # 保存错题记录
                questions = load_wrong_questions()
                analysis.setdefault("questionId", str(uuid.uuid4()))
                analysis.setdefault("userId", "u001")
                analysis.setdefault("createdAt", datetime.now().isoformat())
                questions.append(analysis)
                save_wrong_questions(questions)

    return reply, {"type": "wrong", "targetPage": "pages/StudyTags"}

def handle_update_profile(user_message):
    """更新个人信息"""
    prompt = build_context_prompt(user_message)
    reply = _call_llm(
        load_prompt_file("UpdateProfilePrompt.txt"),
        prompt,
        response_json=True
    )
    result = _extract_json(reply) or {}
    return result.get("reply", "已帮你更新信息。"), None

# ===== Intent Router =====
INTENT_HANDLERS = {
    'query_tasks': handle_query_tasks,
    'analyze_weakness': handle_analyze_weakness,
    'get_suggestion': handle_get_suggestion,
    'match_partner': handle_match_partner,
    'analyze_wrong': handle_analyze_wrong,
    'update_profile': handle_update_profile,
}

# ===== API Routes =====
@agent_bp.route('/api/agent/chat', methods=['POST'])
def agent_chat():
    """
    统一对话接口
    POST body: {
        "message": "用户输入的文字",
        "image": "base64图片（可选）",
        "history": [...]
    }
    返回: {
        "reply": "Agent的回复",
        "intent": "识别的意图",
        "card": {"type": "...", "targetPage": "..."}（可选）
    }
    """
    supplied_version = request.headers.get("X-API-Contract-Version", "")
    if supplied_version != CONTRACT_VERSION:
        return jsonify({
            "code": "CONTRACT_VERSION_MISMATCH",
            "message": f"请使用 X-API-Contract-Version: {CONTRACT_VERSION}",
            "recoverable": False,
        }), 409

    data = request.get_json(silent=True) or {}
    user_message = (data.get("message") or data.get("user_message") or "").strip()
    image_base64 = data.get("image")
    frontend_data = data.get("user_data", {})  # 前端传来的真实课程数据

    if not user_message and not image_base64:
        return jsonify({"reply": "请告诉我你需要什么帮助？", "intent": "unknown"})

    # 如果只有图片没有文字，给一个默认文字
    if not user_message and image_base64:
        user_message = "帮我分析这道题"

    # 如果前端传了真实数据，设为全局变量供 handler 使用
    if frontend_data and frontend_data.get("isDataImported"):
        global _frontend_override_data
        _frontend_override_data = frontend_data

    # 1. 意图识别
    intent = detect_intent(user_message)
    print(f"[Agent] 意图: {intent} | 消息: {user_message[:50]}...")

    # 2. 调用对应的处理器
    handler = INTENT_HANDLERS.get(intent, handle_get_suggestion)

    try:
        if intent == 'analyze_wrong' and image_base64:
            reply, card = handler(user_message, image_base64=image_base64)
        else:
            reply, card = handler(user_message)
    except Exception as e:
        print(f"[Agent] 处理失败: {e}")
        # 回退到通用回复
        reply = f"我理解你的问题，但处理时遇到了一些问题。请稍后重试。"
        card = None

    # 3. 保存历史
    if reply and intent != 'unknown':
        save_history_entry(user_message, reply)

    response_payload = {
        "reply": reply,
        "intent": intent,
    }
    if card is not None:
        response_payload["card"] = card
    return jsonify(response_payload)

@agent_bp.route('/api/agent/health', methods=['GET'])
def health_check():
    """健康检查"""
    return jsonify({
        "status": "ok",
        "llm_ready": bool(LLM_API_KEY),
        "model": LLM_MODEL,
    })

@agent_bp.route('/api/agent/history', methods=['GET'])
def get_chat_history():
    """获取对话历史"""
    return jsonify({"history": get_history()})

@agent_bp.route('/api/agent/history', methods=['DELETE'])
def clear_chat_history():
    """清除对话历史"""
    history_path = _data_path("history.json")
    with open(history_path, "w", encoding="utf-8") as f:
        json.dump([], f)
    return jsonify({"status": "cleared"})

@agent_bp.route('/api/agent/user-data', methods=['GET'])
def get_user_data():
    """获取用户数据快照"""
    user_data = load_user_data()
    candidates = load_candidate_data()
    wrong_questions = load_wrong_questions()
    return jsonify({
        "users": user_data.get("users", {}),
        "courses": user_data.get("courses", {}),
        "candidates": candidates,
        "wrong_questions": wrong_questions[-10:] if isinstance(wrong_questions, list) else [],
    })
