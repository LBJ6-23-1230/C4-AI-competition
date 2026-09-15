# -*- coding: utf-8 -*-
"""Stateful contract-demo implementation for the /api/v1 learning flow."""

import copy
import json
import threading
from pathlib import Path

from flask import Blueprint, jsonify, request


CONTRACT_VERSION = "api-contract-v0.2"
DEMO_USER_ID = "demo-user"
DEMO_SESSION_ID = "session-demo-001"
DEMO_TRACE_ID = "trace-demo-001"
DEMO_SET_ID = "set-demo-binary-tree-001"
DEMO_PLAN_ID = "plan-demo-001"

v1_bp = Blueprint("learning_v1", __name__)
_fixture_dir = Path(__file__).resolve().parent.parent / "contracts" / "fixtures"
_state_lock = threading.Lock()
_state = {"submitted": False, "workflow_created": False, "submissions": {}}


def _fixture(name):
    with (_fixture_dir / name).open("r", encoding="utf-8") as fixture_file:
        return json.load(fixture_file)


def _response(name, status=200):
    return jsonify(copy.deepcopy(_fixture(name))), status


def _error(code, message, status, recoverable=False):
    return jsonify({"code": code, "message": message, "recoverable": recoverable}), status


@v1_bp.before_request
def require_contract_version():
    supplied = request.headers.get("X-API-Contract-Version", "")
    if supplied != CONTRACT_VERSION:
        return _error(
            "CONTRACT_VERSION_MISMATCH",
            f"请使用 X-API-Contract-Version: {CONTRACT_VERSION}",
            409,
        )
    return None


@v1_bp.post("/api/v1/workflows")
def create_workflow():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict) or not isinstance(payload.get("goal"), str) or not payload["goal"].strip():
        return _error("INVALID_REQUEST", "goal 必须是非空字符串。", 400)
    with _state_lock:
        _state["workflow_created"] = True
    return _response("workflow-created.json", 201)


@v1_bp.get("/api/v1/workflows/<session_id>")
def get_workflow(session_id):
    if session_id != DEMO_SESSION_ID:
        return _error("WORKFLOW_NOT_FOUND", "未找到对应工作流。", 404)
    with _state_lock:
        submitted = _state["submitted"]
    return _response("workflow-completed.json" if submitted else "workflow-running.json")


@v1_bp.get("/api/v1/profile/<user_id>")
def get_profile(user_id):
    if user_id != DEMO_USER_ID:
        return _error("PROFILE_NOT_FOUND", "未找到对应学习画像。", 404)
    with _state_lock:
        submitted = _state["submitted"]
    return _response("profile-v2.json" if submitted else "profile-v1.json")


@v1_bp.get("/api/v1/plans/current")
def get_current_plan():
    with _state_lock:
        submitted = _state["submitted"]
    return _response("plan-v2.json" if submitted else "plan-v1.json")


@v1_bp.get("/api/v1/exercises/<set_id>")
def get_exercise_set(set_id):
    if set_id != DEMO_SET_ID:
        return _error("EXERCISE_SET_NOT_FOUND", "未找到对应练习集。", 404)
    return _response("exercise-set.json")


@v1_bp.post("/api/v1/exercises/<set_id>/submit")
def submit_exercise(set_id):
    if set_id != DEMO_SET_ID:
        return _error("EXERCISE_SET_NOT_FOUND", "未找到对应练习集。", 404)
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return _error("INVALID_REQUEST", "请求正文必须是 JSON 对象。", 400)
    idempotency_key = payload.get("idempotencyKey")
    answers = payload.get("answers")
    if not isinstance(idempotency_key, str) or not idempotency_key.strip() or not isinstance(answers, list):
        return _error("INVALID_REQUEST", "idempotencyKey 和 answers 为必填字段。", 400)
    for answer in answers:
        if not isinstance(answer, dict):
            return _error("INVALID_REQUEST", "answers 中的每一项都必须是 JSON 对象。", 400)
        exercise_id = answer.get("exerciseId")
        answer_value = answer.get("answer")
        if not isinstance(exercise_id, str) or not exercise_id.strip() or not isinstance(answer_value, str):
            return _error("INVALID_REQUEST", "每个答案都必须包含 exerciseId 和字符串 answer。", 400)
    with _state_lock:
        cached = _state["submissions"].get(idempotency_key)
        if cached is None:
            cached = _fixture("exercise-submission-result.json")
            _state["submissions"][idempotency_key] = cached
            _state["submitted"] = True
        result = copy.deepcopy(cached)
    return jsonify(result)


@v1_bp.get("/api/v1/plans/<plan_id>/diff")
def get_plan_diff(plan_id):
    if plan_id != DEMO_PLAN_ID:
        return _error("PLAN_NOT_FOUND", "未找到对应学习计划。", 404)
    with _state_lock:
        submitted = _state["submitted"]
    if not submitted:
        return _error("PLAN_DIFF_NOT_READY", "完成诊断练习后才会生成计划差异。", 409, True)
    return _response("plan-diff.json")


@v1_bp.get("/api/v1/traces/<trace_id>")
def get_trace(trace_id):
    if trace_id != DEMO_TRACE_ID:
        return _error("TRACE_NOT_FOUND", "未找到对应 Agent 轨迹。", 404)
    with _state_lock:
        submitted = _state["submitted"]
    return _response("trace-after.json" if submitted else "trace-before.json")


@v1_bp.post("/api/v1/demo/reset")
def reset_demo():
    with _state_lock:
        _state["submitted"] = False
        _state["workflow_created"] = False
        _state["submissions"].clear()
    return _response("demo-reset.json")
