# -*- coding: utf-8 -*-
"""鉴权接口（/api/v1/auth/*）。

契约（与 `contracts/openapi.json` 的 Auth* 定义一致）
----------------------------------------------------
POST   /api/v1/auth/register   {nickname, grade?}      → {user, token, expiresAt}
POST   /api/v1/auth/login      {userId, token}         → {user, token, expiresAt}
POST   /api/v1/auth/logout     (Bearer)                → {status: "ok"}
GET    /api/v1/auth/me         (Bearer)                → {user}
DELETE /api/v1/auth/account    (Bearer)                → {status: "deactivated"}

**刻意不做密码登录**：本项目没有需要密码保护的数据，自建密码体系只会带来
合规负担与实现风险。注册即发 token，token 存 preferences，等价于长期会话票据。
生产化路径是把本文件替换为 AGC 认证服务（见 `docs/02` §4.2 方案②）。
"""

from __future__ import annotations

from flask import Blueprint, jsonify, request

from app.auth import service
from app.repositories.json_repository import JsonRepository

auth_api = Blueprint("auth", __name__)
_repository: JsonRepository | None = None


def configure_auth_repository(repository: JsonRepository) -> None:
    global _repository
    _repository = repository


def _error(error_code: str, message: str, status: int = 400):
    return jsonify({"errorCode": error_code, "message": message, "details": None}), status


def _body() -> dict:
    """宽松取体：与 chat 层同样处理 `Content-Type: application/json; charset=utf-8`。"""
    data = request.get_json(silent=True)
    if isinstance(data, dict):
        return data
    raw = request.get_data() or b""
    if not raw.strip():
        return {}
    import json
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _current_token() -> str:
    return service.parse_bearer(request.headers.get("Authorization"))


def _require_user():
    """返回 (user, token) 或 (None, error_response)。"""
    if _repository is None:
        return None, _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    token = _current_token()
    if not token:
        return None, _error("UNAUTHORIZED", "缺少 Authorization: Bearer <token> 请求头", 401)
    user = service.resolve_session(_repository, token)
    if user is None:
        return None, _error("UNAUTHORIZED", "登录已失效，请重新登录", 401)
    return (user, token), None


@auth_api.post("/api/v1/auth/register")
def register():
    """注册：昵称 + 年级 → userId + token，并预置一份空画像。"""
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.register_user(_repository, data.get("nickname"), data.get("grade"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)

    service.provision_starter_profile(
        _repository, result["user"]["userId"], result["user"]["nickname"])
    return jsonify(result), 201


@auth_api.post("/api/v1/auth/login")
def login():
    """恢复登录态：用本地保存的 (userId, token) 换回用户信息。"""
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.login_user(_repository, data.get("userId"), data.get("token"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)
    return jsonify(result)


@auth_api.post("/api/v1/auth/logout")
def logout():
    """退出登录：只吊销当前 token，不动用户数据。"""
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    token = _current_token()
    if not token:
        return _error("UNAUTHORIZED", "缺少 Authorization: Bearer <token> 请求头", 401)
    service.revoke_session(_repository, token)
    return jsonify({"status": "ok"})


@auth_api.get("/api/v1/auth/me")
def me():
    """读取当前登录用户。前端启动时用它校验本地 token 是否仍然有效。"""
    resolved, failure = _require_user()
    if failure is not None:
        return failure
    user, _token = resolved
    return jsonify({"user": service.get_user(_repository, user["userId"])})


@auth_api.delete("/api/v1/auth/account")
def delete_account():
    """注销账号：标记停用 + 清空全部会话（合规要求）。"""
    resolved, failure = _require_user()
    if failure is not None:
        return failure
    user, _token = resolved
    if not service.deactivate_user(_repository, user["userId"]):
        return _error("NOT_FOUND", "账号不存在", 404)
    return jsonify({"status": "deactivated", "userId": user["userId"]})
