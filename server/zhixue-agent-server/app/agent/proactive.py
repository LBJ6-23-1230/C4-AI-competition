"""Deterministic proactive reminder decision engine."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from app.decision.priority import calculate_learning_priority


def _as_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _pending_ddl_due(context: dict[str, Any], days_left: float) -> bool:
    tasks = context.get("pendingTasks")
    if not isinstance(tasks, list):
        return False
    for task in tasks:
        if not isinstance(task, dict):
            continue
        status = str(task.get("status", "pending")).lower()
        started = bool(task.get("started", False)) or status in {"in_progress", "completed"}
        task_days_left = _as_float(task.get("daysLeft", days_left), days_left)
        if not started and task_days_left <= 2:
            return True
    return False


def proactive_decision(payload: dict[str, Any]) -> dict[str, Any]:
    """Return a deterministic proactive reminder payload for the current user context."""
    context = payload.get("context") or {}
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
            "cardData": {"taskName": "二叉树后序遍历", "knowledgePointId": "binary-tree-postorder",
                          "durationMinutes": 45, "examCountdownDays": 0, "hint": ""},
        }

    mastery_score = _as_float(context.get("masteryScore", 58), 58.0)
    error_intensity = _as_float(context.get("errorIntensity", 67), 67.0)
    days_left = _as_float(context.get("daysLeft", 5), 5.0)
    importance = _as_float(context.get("importance", 90), 90.0)
    location = (context.get("location") or "unknown").strip() or "unknown"
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
            "cardData": {"taskName": "二叉树后序遍历", "knowledgePointId": "binary-tree-postorder",
                          "durationMinutes": 45, "examCountdownDays": int(days_left), "hint": ""},
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

    ddl_due = _pending_ddl_due(context, days_left)
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
    action = {
        "type": "focus",
        "label": "开始 45 分钟专注",
        "targetPage": "pages/FocusSetup",
        "preset": {"taskId": "task-postorder", "durationMinutes": 45},
    }
    body = (
        "你上次后序遍历只答对 2/3，建议先补这个。要不要现在用 45 分钟？"
        if should_notify else "建议在下一次复习时优先回顾二叉树后序遍历"
    )
    reason = (
        f"考试剩 {int(days_left)} 天（紧迫度贡献 {priority['factors']['urgency']['contribution']:.3f}），"
        f"后序遍历掌握度 {mastery_score:.0f} 偏低（贡献 {priority['factors']['mastery']['contribution']:.3f}），"
        f"近 {gap_days} 天未学习，当前在{location}适合深度专注"
    )

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
        "title": "数据结构考试还有 5 天" if should_notify else "",
        "body": body,
        "action": action if should_notify else {"type": "none", "label": "", "targetPage": "", "preset": {}},
        "contextTags": tags + trigger_reasons,
        "reason": reason,
        "factors": factors,
        "cardData": {
            "taskName": "二叉树后序遍历",
            "knowledgePointId": "binary-tree-postorder",
            "durationMinutes": 45,
            "examCountdownDays": int(days_left),
            "hint": "近期复习不足 · 2 项作业临近" if should_notify else "",
        },
    }
