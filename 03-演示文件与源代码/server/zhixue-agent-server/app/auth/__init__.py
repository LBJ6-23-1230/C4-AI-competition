# -*- coding: utf-8 -*-
"""鉴权包：领域逻辑在 `service`，HTTP 接口在 `app/api/auth.py`。

刻意把领域逻辑与 Flask 解耦——`service` 里全部是纯函数（只依赖 `Repository`），
因此可以被单元测试直接调用，也可以被将来的 AGC 认证服务替换而不动 API 层。
"""

from app.auth.service import (  # noqa: F401
    DEMO_USER_ID,
    AuthError,
    create_session,
    deactivate_user,
    get_user,
    login_user,
    parse_bearer,
    provision_starter_profile,
    register_user,
    resolve_session,
    revoke_all_sessions,
    revoke_session,
)

__all__ = [
    "DEMO_USER_ID",
    "AuthError",
    "create_session",
    "deactivate_user",
    "get_user",
    "login_user",
    "parse_bearer",
    "provision_starter_profile",
    "register_user",
    "resolve_session",
    "revoke_all_sessions",
    "revoke_session",
]
