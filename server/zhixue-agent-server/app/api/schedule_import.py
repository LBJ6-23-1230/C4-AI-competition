# -*- coding: utf-8 -*-
"""课表截图识别接口：图片 → Qwen-VL → 可确认的课程列表。"""

from __future__ import annotations

import base64
import binascii
from datetime import date, datetime
from typing import Any

from flask import Blueprint, jsonify

from app.agent import chat_llm
from app.api.validation import bad_request, json_object

schedule_import_api = Blueprint("schedule_import", __name__)

_MAX_IMAGE_BYTES = 5 * 1024 * 1024


def _days_left(raw: str) -> int:
    try:
        target = datetime.strptime(raw, "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return 30
    return max(0, (target - date.today()).days)


def _normalize_course(row: Any, index: int) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    name = str(row.get("courseName") or row.get("name") or "").strip()
    if not name:
        return None
    exam_date = str(row.get("examDate") or "").strip()
    priority = str(row.get("priority") or "").strip()
    if priority not in {"高", "中", "低"}:
        priority = "中"
    try:
        study_hours = max(0.0, float(row.get("studyHours") or 0))
    except (TypeError, ValueError):
        study_hours = 0.0
    status = str(row.get("status") or "").strip() or "待建立复习记录"
    return {
        "courseId": f"ocr-{int(datetime.now().timestamp())}-{index}",
        "courseName": name[:80],
        "exam": {"date": exam_date or "未设置", "daysLeft": _days_left(exam_date)},
        "priority": priority,
        "recentStatus": {"studyHours": study_hours, "status": status[:80]},
    }


@schedule_import_api.post("/api/v1/import/schedule-image")
def recognize_schedule_image():
    data, error = json_object()
    if error is not None:
        return error
    image = data.get("imageBase64")
    if not isinstance(image, str) or not image.strip():
        return bad_request("imageBase64 不能为空", {"field": "imageBase64"})
    try:
        raw = base64.b64decode(image, validate=True)
    except (binascii.Error, ValueError):
        return bad_request("imageBase64 不是合法的 base64", {"field": "imageBase64"})
    if len(raw) > _MAX_IMAGE_BYTES:
        return bad_request("课表图片不能超过 5MB", {"limitBytes": _MAX_IMAGE_BYTES})
    if not chat_llm.llm_ready():
        return jsonify({
            "errorCode": "LLM_NOT_CONFIGURED",
            "message": "课表图片识别需要配置 DASHSCOPE_API_KEY；也可以先用 CSV/JSON 导入。",
            "details": None,
        }), 503

    system_prompt = (
        "你是课表截图识别助手。只提取图片中真实可见的课程，不得补造。"
        "只输出 JSON，不要 markdown。无法识别的考试日期留空。"
    )
    user_prompt = (
        "请识别全部课程，输出 {\"courses\":[{\"courseName\":\"课程名\","
        "\"examDate\":\"YYYY-MM-DD 或空字符串\",\"priority\":\"高/中/低\","
        "\"studyHours\":0,\"status\":\"待建立复习记录\"}]}。"
        "同一课程只保留一条；看不清的课程不要输出。"
    )
    try:
        response = chat_llm._call_llm_with_image(  # noqa: SLF001 - 复用统一 VL 客户端
            system_prompt, user_prompt, image, response_json=True)
        parsed = chat_llm.extract_json(response) or {}
    except Exception as exc:  # noqa: BLE001 - 模型失败转为可读 API 错误
        # 详细异常只留服务端日志，避免把上游地址、请求细节等内部信息回显给用户。
        print(f"[schedule-import] 课表图片识别失败: {exc}")
        return jsonify({
            "errorCode": "SCHEDULE_OCR_FAILED",
            "message": "课表图片识别服务暂时不可用，请稍后重试或改用 CSV/JSON 导入。",
            "details": None,
        }), 502

    rows = parsed.get("courses")
    if not isinstance(rows, list):
        return jsonify({
            "errorCode": "SCHEDULE_OCR_INVALID_RESPONSE",
            "message": "模型没有返回可用的课程列表，请换一张更清晰的课表截图。",
            "details": None,
        }), 502
    courses = [course for index, row in enumerate(rows)
               if (course := _normalize_course(row, index)) is not None]
    if not courses:
        return jsonify({
            "errorCode": "SCHEDULE_OCR_EMPTY",
            "message": "没有从图片中识别到课程，请裁剪到课表区域后重试。",
            "details": None,
        }), 422
    return jsonify({
        "courses": courses,
        "recognizedCount": len(courses),
        "model": chat_llm.llm_vl_model(),
        "recognizedAt": datetime.now().isoformat(),
    })
