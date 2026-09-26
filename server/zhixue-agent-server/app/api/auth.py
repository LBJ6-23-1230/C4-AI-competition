# -*- coding: utf-8 -*-
"""鉴权接口（/api/v1/auth/*）。

契约（与 `contracts/openapi.json` 的 Auth* 定义一致）
----------------------------------------------------
POST   /api/v1/auth/register   {nickname, phone, password?, seedDemoData?} → {user, token, expiresAt, demoDataSeeded}
POST   /api/v1/auth/login      {phone|nickname, password}   → {user, token, expiresAt}
POST   /api/v1/auth/change-password {oldPassword?, newPassword} (Bearer) → {status, hasPassword, wasFirstTime}
POST   /api/v1/auth/logout     (Bearer)                → {status: "ok"}
GET    /api/v1/auth/me         (Bearer)                → {user}
DELETE /api/v1/auth/account    (Bearer)                → {status: "deactivated"}

本地账号支持密码登录，服务端只保存 Werkzeug 生成的加盐哈希；验证码与华为
账号入口继续保留。登录成功后签发会话 token，客户端只持久化 token。

`seedDemoData` 是**可选**字段（建号类接口：register / login-or-register /
verify-code / login-with-huawei），默认 false = 新账号只建空画像、
不写入写死的知识点与计划；详见 `_seed_demo_data()` 与
`app/auth/service.py::provision_starter_profile`。
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


def _error(error_code: str, message: str, status: int = 400,
           details: dict | None = None):
    return jsonify({"errorCode": error_code, "message": message,
                    "details": details}), status


def _auth_error(error: service.AuthError):
    return _error(error.error_code, error.message, error.status, error.details)


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


def _seed_demo_data(data: dict) -> bool:
    """读取可选的 `seedDemoData`：本次注册**要不要**顺便写入演示数据。

    默认 `False`（不载入）—— 与 `service.provision_starter_profile` 的默认值一致：
    新账号默认只建空画像，不回写写死的二叉树知识点与起始计划。
    用户实测反馈："创建一个新账号最好不直接给出已经写死的数据……否则会给用户
    一种虚假的感觉"。想快速看完整闭环的用户可以在注册页显式勾选。

    ⚠️ 只认真正的布尔 `True`：写成 `data.get("seedDemoData")` 会让
    `{"seedDemoData": "false"}`（字符串）被 Python 的真值判断当成"要载入"，
    与调用方的字面意思相反 —— 这类"看起来关着其实开着"的开关是最难查的。
    """
    return data.get("seedDemoData") is True


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
    """注册：昵称 + 年级 + **手机号** → userId + token，并预置一份空画像。

    可选请求体字段 `seedDemoData`（布尔，默认 false）：是否顺便写入演示数据
    （二叉树知识点 + 起始计划）。响应里的 `demoDataSeeded` 如实回填本次结果。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.register_user(_repository, data.get("nickname"),
                                       data.get("grade"), data.get("phone"),
                                       data.get("password"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)

    seeded = service.provision_starter_profile(
        _repository, result["user"]["userId"], result["user"]["nickname"],
        with_demo_data=_seed_demo_data(data))
    return jsonify({**result, "demoDataSeeded": seeded}), 201


@auth_api.post("/api/v1/auth/login")
def login():
    """登录。

    支持两种形式：

    * `{userId, token}` —— 恢复登录态（用本地保存的凭据换回用户信息）
    * `{nickname, password}` —— 按昵称与密码登录

    为什么要加第二种：原先前端「登录」标签下唯一能调的是 `register()`，
    于是用同一个昵称再点一次会**又建一个新账号**（实测两次注册「张三」
    得到两个不同 userId）。用户以为在登录，实际旧画像永远读不到。

    ⚠️ 昵称不是秘密，`{nickname}` 形式**不是安全的认证方式**，只用于
    演示 / 单机场景。真实身份校验请见 `docs/11` 的手机号验证码方案。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()

    # 分派规则：**只要客户端提供了 userId 或 token 这两个键中的任意一个**，
    # 就走凭据恢复路径，由 `service.login_user` 负责校验（空串/None 会得到 400）。
    #
    # ⚠️ 这里必须按"键是否存在"判断，不能按"值是否非空"判断：
    # 否则 `{"userId":"","token":""}` 会掉到昵称分支，
    # 报出 404「该昵称还没有账号」而不是 400「userId 不能为空」——语义错位。
    if "userId" in data or "token" in data:
        try:
            result = service.login_user(_repository, data.get("userId"), data.get("token"))
        except service.AuthError as error:
            return _error(error.error_code, error.message, error.status)
        return jsonify(result)

    # 手机号优先于昵称：手机号唯一、可验证，是更强的身份标识
    if data.get("phone"):
        try:
            result = service.login_by_phone(_repository, data.get("phone"),
                                            data.get("password"))
        except service.AuthError as error:
            return _error(error.error_code, error.message, error.status)
        return jsonify(result)

    try:
        result = service.login_by_nickname(_repository, data.get("nickname"),
                                           data.get("password"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)
    return jsonify(result)


@auth_api.post("/api/v1/auth/send-code")
def send_code():
    """发送手机号验证码；未接入短信服务时仅返回开发模式验证码。"""
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.send_verification_code(_repository, data.get("phone"))
    except service.AuthError as error:
        return _auth_error(error)
    return jsonify(result)


@auth_api.post("/api/v1/auth/verify-code")
def verify_code():
    """校验验证码并自动登录或注册；成功后验证码立即失效。

    可选请求体字段 `seedDemoData`：只在**本次真的建了新号**时起作用。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.verify_verification_code(
            _repository, data.get("phone"), data.get("code"),
            data.get("nickname"), data.get("grade"),
            with_demo_data=_seed_demo_data(data))
    except service.AuthError as error:
        return _auth_error(error)
    return jsonify(result), (201 if result.get("created") else 200)


@auth_api.post("/api/v1/auth/login-or-register")
def login_or_register():
    """**登录优先，注册兜底** —— 前端主按钮应调这个。

    识别顺序：**手机号 → 昵称**（手机号唯一且可验证，优先级更高）。

    行为：
    * 命中已有账号 → 登录（不再新建）
    * 未命中       → 创建账号（若 `_PHONE_REQUIRED` 为真则必须有手机号）

    响应里带 `created` 布尔值，前端可据此提示"欢迎回来 / 已为你建号"。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()

    # 先做一次格式校验，让"手机号写错"在注册/登录之前就被拦住
    try:
        phone = service.normalize_phone(data.get("phone"),
                                        required=service._PHONE_REQUIRED)
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)

    existing = None
    if phone:
        existing = service.find_user_by_phone(_repository, phone)
    if existing is None and not phone:
        try:
            matches = service.find_users_by_nickname(_repository, data.get("nickname"))
        except service.AuthError as error:
            return _error(error.error_code, error.message, error.status)
        existing = matches[0] if matches else None

    if existing is not None:
        try:
            result = (service.login_by_phone(_repository, phone, data.get("password")) if phone
                      else service.login_by_nickname(_repository, data.get("nickname"),
                                                     data.get("password")))
        except service.AuthError as error:
            return _error(error.error_code, error.message, error.status)
        return jsonify({**result, "created": False})

    try:
        result = service.register_user(_repository, data.get("nickname"),
                                       data.get("grade"), phone, data.get("password"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)
    seeded = service.provision_starter_profile(
        _repository, result["user"]["userId"], result["user"]["nickname"],
        with_demo_data=_seed_demo_data(data))
    return jsonify({**result, "created": True, "demoDataSeeded": seeded}), 201


@auth_api.post("/api/v1/auth/login-with-huawei")
def login_with_huawei():
    """华为账号一键登录（登录优先，注册兜底）。

    客户端用 `@kit.AccountKit` 拿到 OpenID 后调本接口。
    首次登录自动建号 —— 用户不需要填昵称、手机号或验证码。

    ⚠️ **本接口不校验 OpenID 真伪**（那需要服务端调华为接口验签）。
    当前版本定位"演示可用、生产需补验签"，见 `docs/13`。
    生产环境必须补上验签，否则伪造 openId 即可登入他人账号。

    可选请求体字段 `seedDemoData`：只在**本次真的建了新号**时起作用。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    data = _body()
    try:
        result = service.login_with_huawei(
            _repository, data.get("openId"), data.get("unionId"),
            data.get("nickname"), data.get("grade"))
    except service.AuthError as error:
        return _error(error.error_code, error.message, error.status)

    if result.get("created"):
        seeded = service.provision_starter_profile(
            _repository, result["user"]["userId"], result["user"]["nickname"],
            with_demo_data=_seed_demo_data(data))
        return jsonify({**result, "demoDataSeeded": seeded}), 201
    return jsonify(result)


@auth_api.post("/api/v1/auth/change-password")
def change_password():
    """修改 / **首次设置**密码（需 `Authorization: Bearer <token>`）。

    * 账号已设过密码 → 必须带对 `oldPassword`，否则 401；
    * 从未设过密码（验证码建号）→ 这是首次设置，无需旧密码。

    存在的意义：「我的 → 账号与密码管理」这个入口一直有，但**没有任何密码管理能力**；
    而且验证码建出来的账号是无密码的，没有这个接口就永远补不上密码。
    """
    if _repository is None:
        return _error("INTERNAL_ERROR", "auth repository is not configured", 500)
    resolved, failure = _require_user()
    if failure is not None:
        return failure
    user, _token = resolved
    data = _body()
    try:
        result = service.change_password(_repository, user["userId"],
                                         data.get("oldPassword"), data.get("newPassword"))
    except service.AuthError as error:
        return _auth_error(error)
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
