"""Deterministic proactive reminder decision engine."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from app.decision.priority import calculate_learning_priority


def _as_float(value: Any, default: float = 0.0) -> float:
    """把输入安全地转成**有限**浮点数。

    ⚠️ 必须同时排除 `inf` / `-inf` / `nan`。

    `float("Infinity")` 这类字符串是能成功转换的，但下游会立刻炸：

    * `int(days_left)`        → `OverflowError: cannot convert float infinity to integer`
    * `f"{score:.0f}"`        → `ValueError: cannot convert float NaN to integer`

    两者都会冒泡成 HTTP 500。实测 `daysLeft` 传 `"Infinity"` / `"NaN"` / `1e400`
    都能稳定复现（JSON 不允许 Infinity 字面量，但**字符串**可以，
    且 `1e400` 这种超大数值在 Python 里就解析成 `inf`）。
    """
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if number != number or number in (float("inf"), float("-inf")):
        return default          # nan / ±inf 一律回退到默认值
    return number


def _parse_iso8601(value: Any) -> datetime | None:
    """宽松解析 ISO-8601 时间串；**任何非字符串输入都返回 None**，不抛异常。

    ⚠️ 原实现只捕 `ValueError`，对非字符串直接调 `.replace()` ——
    于是 `{"now": 1758530000}`（epoch 秒，客户端最常见的写法）
    会抛 `AttributeError: 'int' object has no attribute 'replace'`
    → 冒泡成 **HTTP 500**，而契约把这两个字段声明为 string/date-time，
    接口只声明了 200/400。类型不符应当被当成"信号缺失"处理，不是服务器故障。

    同时兜住 `TypeError`：`datetime.fromisoformat` 对某些畸形串会抛它。
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _pending_ddl_task(context: dict[str, Any], days_left: float) -> dict[str, Any] | None:
    tasks = context.get("pendingTasks")
    if not isinstance(tasks, list):
        return None
    due_tasks = []
    for index, task in enumerate(tasks):
        if not isinstance(task, dict):
            continue
        status = str(task.get("status", "pending")).lower()
        started = bool(task.get("started", False)) or status in {"in_progress", "completed"}
        task_days_left = _as_float(task.get("daysLeft", days_left), days_left)
        if not started and task_days_left <= 2:
            due_tasks.append((task_days_left, index, task))
    return min(due_tasks, key=lambda item: (item[0], item[1]))[2] if due_tasks else None


def _task_name(context: dict[str, Any], pending_task: dict[str, Any] | None) -> str:
    """当前该补什么（任务名 / 知识点名）。

    优先级：待办任务标题 → 调用方按画像算出的最薄弱知识点（`context.taskName`）
    → 中性占位。

    ⚠️ **绝不写死具体知识点**。原实现把任务名/知识点名硬编码成"二叉树后序遍历"，
    于是刚诊断出"哈希表"的用户，首页与学习页的卡片文案仍然是"二叉树后序遍历" ——
    实测反馈：「这里就有哈希了，但是上面的不能一味的写二叉树后序遍历，要具体看题目」。
    """
    if isinstance(pending_task, dict):
        title = str(pending_task.get("title") or "").strip()
        if title:
            return title
    return str(context.get("taskName") or "").strip() or "当前薄弱知识点"


def _task_card(context: dict[str, Any], days_left: float,
               pending_task: dict[str, Any] | None = None,
               duration: int = 45) -> dict[str, Any]:
    """卡片里的任务信息，按真实薄弱点填（见 `_task_name`）。"""
    point_id = ""
    if isinstance(pending_task, dict):
        point_id = str(pending_task.get("knowledgePointId") or "")
    point_id = point_id or str(context.get("knowledgePointId") or "")
    return {
        "taskName": _task_name(context, pending_task),
        "knowledgePointId": point_id,
        "durationMinutes": duration,
        "examCountdownDays": int(days_left),
        "hint": "",
    }


def proactive_decision(payload: dict[str, Any]) -> dict[str, Any]:
    """Return a deterministic proactive reminder payload for the current user context."""
    payload = payload if isinstance(payload, dict) else {}
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    user_id = payload.get("userId", "demo-user")
    if context.get("focusSessionActive"):
        return {
            "userId": user_id,
            "shouldNotify": False,
            "channel": "silent",
            "title": "",
            "body": "",
            "action": {"type": "none", "label": "", "targetPage": "", "preset": {}},
            "contextTags": [],
            "reason": "当前正处于专注会话，不打扰用户",
            "factors": [],
            "cardData": _task_card(context, 0.0),
        }

    mastery_score = _as_float(context.get("masteryScore", 58), 58.0)
    error_intensity = _as_float(context.get("errorIntensity", 67), 67.0)
    days_left = _as_float(context.get("daysLeft", 5), 5.0)
    importance = _as_float(context.get("importance", 90), 90.0)
    # ⚠️ `location` 必须显式判类型。
    # 原写法 `(context.get("location") or "unknown").strip()`：
    # 空值能被 `or` 兜住，但**非空非字符串**（数字/数组/对象）会穿透 ——
    # `{"location": 5}` 直接抛 `AttributeError: 'int' object has no attribute 'strip'`
    # → HTTP 500，而契约把 location 声明为 string（nullable）。
    raw_location = context.get("location")
    location = raw_location.strip() if isinstance(raw_location, str) else "unknown"
    location = location or "unknown"
    last_study_at = _parse_iso8601(context.get("lastStudyAt"))
    has_study_signal = "lastStudyAt" in context
    has_exam_signal = "daysLeft" in context and "masteryScore" in context
    now = _parse_iso8601(context.get("now"))
    if now is None:
        now = datetime.now()

    gap_days = 0
    if last_study_at is not None:
        gap_days = max(0, (now.date() - last_study_at.date()).days)
    if context.get("foreground") is True:
        return {
            "userId": user_id,
            "shouldNotify": False,
            "channel": "silent",
            "title": "",
            "body": "",
            "action": {"type": "none", "label": "", "targetPage": "", "preset": {}},
            "contextTags": [],
            "reason": "用户当前前台使用应用，暂不打扰",
            "factors": [],
            "cardData": _task_card(context, days_left),
        }

    priority = calculate_learning_priority([
        {
            "knowledgePointId": "binary-tree-postorder",
            "masteryScore": mastery_score,
            "errorIntensity": error_intensity,
            "importance": importance,
            "urgency": max(0.0, min(100.0, (30 - days_left) / 30 * 100)),
            "prerequisiteImpact": 20,
        }
    ], {"daysLeft": days_left})[0]

    tags = []
    if days_left <= 7:
        tags.append("exam_within_7d")
    if gap_days >= 2:
        tags.append("recent_gap_2d")
    if location and location != "unknown":
        tags.append(f"location_{location}")

    pending_task = _pending_ddl_task(context, days_left)
    ddl_due = pending_task is not None
    study_gap = has_study_signal and gap_days >= 2
    exam_weak = has_exam_signal and days_left <= 7 and mastery_score < 80
    trigger_reasons = []
    if ddl_due:
        trigger_reasons.append("pending_ddl_within_2d")
    if study_gap:
        trigger_reasons.append("no_study_for_2d")
    if exam_weak:
        trigger_reasons.append("exam_within_7d_low_mastery")
    should_notify = bool(trigger_reasons) and not context.get("focusSessionActive", False)
    # 任务 id 仍沿用演示计划里的 `task-postorder`：它是**计划条目的标识**，
    # 专注完成后要靠它回写计划进度（见 AppState.markPlanTaskStatus），
    # 不能跟着展示名一起变；展示名走 `_task_name()`，与真实薄弱点对齐。
    task_id = str(pending_task.get("taskId") or "task-postorder") if pending_task else "task-postorder"
    task_name = _task_name(context, pending_task)
    knowledge_point_id = str(
        pending_task.get("knowledgePointId") or context.get("knowledgePointId") or ""
    ) if pending_task else str(context.get("knowledgePointId") or "")
    action = {
        "type": "focus",
        "label": "开始 45 分钟专注",
        "targetPage": "pages/FocusSetup",
        "preset": {"taskId": task_id, "title": task_name, "durationMinutes": 45},
    }
    task_days_left = _as_float(pending_task.get("daysLeft", days_left), days_left) if pending_task else days_left
    if should_notify and pending_task:
        body = f"待办「{task_name}」将在 {int(max(0, task_days_left))} 天内截止，建议现在安排 45 分钟完成。"
        reason = f"待办「{task_name}」临近截止，且当前没有进行中的专注会话"
        title = f"待办「{task_name}」即将截止"
    else:
        # ⚠️ 两条修正：
        #   1. 不再编造"你上次只答对 2/3"这种**没有证据支撑**的具体数字 ——
        #      同一响应里没有任何答题记录可依据，属于凭空生成。
        #   2. 位置未知时**不再把 "unknown" 拼进句子**（此前输出
        #      "近 0 天未学习，当前在unknown适合深度专注"，中英混杂）。
        body = (
            f"「{task_name}」还没补上，要不要现在用 45 分钟？"
            if should_notify else f"建议在下一次复习时优先回顾「{task_name}」"
        )
        location_clause = "" if location in ("", "unknown") else f"，当前在{location}"
        reason = (
            f"考试剩 {int(days_left)} 天（紧迫度贡献 {priority['factors']['urgency']['contribution']:.3f}），"
            f"「{task_name}」掌握度 {mastery_score:.0f} 偏低（贡献 {priority['factors']['mastery']['contribution']:.3f}），"
            f"近 {gap_days} 天未学习{location_clause}，适合深度专注"
        )
        # 标题里的天数**必须用真实值**：原来写死"数据结构考试还有 5 天"，
        # 与同一响应 reason 里的真实天数互相打架（实测：导入 20 天后的考试，
        # 通知标题仍写"还有 5 天"）。
        title = f"考试还有 {int(days_left)} 天" if should_notify else ""

    factors = [
        {"name": "1-Mastery", "value": priority["factors"]["mastery"]["value"], "weight": priority["factors"]["mastery"]["weight"], "contribution": priority["factors"]["mastery"]["contribution"]},
        {"name": "ErrorIntensity", "value": priority["factors"]["errorIntensity"]["value"], "weight": priority["factors"]["errorIntensity"]["weight"], "contribution": priority["factors"]["errorIntensity"]["contribution"]},
        {"name": "Importance", "value": priority["factors"]["importance"]["value"], "weight": priority["factors"]["importance"]["weight"], "contribution": priority["factors"]["importance"]["contribution"]},
        {"name": "Urgency", "value": priority["factors"]["urgency"]["value"], "weight": priority["factors"]["urgency"]["weight"], "contribution": priority["factors"]["urgency"]["contribution"]},
        {"name": "PrerequisiteImpact", "value": priority["factors"]["prerequisiteImpact"]["value"], "weight": priority["factors"]["prerequisiteImpact"]["weight"], "contribution": priority["factors"]["prerequisiteImpact"]["contribution"]},
    ]

    return {
        "userId": user_id,
        "shouldNotify": should_notify,
        "channel": "reminder" if should_notify else "silent",
        "title": title,
        "body": body,
        "action": action if should_notify else {"type": "none", "label": "", "targetPage": "", "preset": {}},
        "contextTags": tags + trigger_reasons,
        "reason": reason,
        "factors": factors,
        "cardData": {
            "taskName": task_name,
            "knowledgePointId": knowledge_point_id,
            "durationMinutes": 45,
            "examCountdownDays": int(days_left),
            "hint": ("待办临近截止 · 建议优先处理" if pending_task
                     else "近期复习不足 · 2 项作业临近") if should_notify else "",
        },
    }
