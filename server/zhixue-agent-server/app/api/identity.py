# -*- coding: utf-8 -*-
"""统一的身份解析。

为什么必须集中一处
------------------
项目原先多处端点直接写 `request.args.get("userId", "demo-user")`，
而 `app/__init__.py` 虽然把 Bearer token 解析成了 `g.current_user`，
**却没有任何端点读取它** —— 结果是"登录了，看到的还是演示账号的数据"。

散落各处还带来第二个风险：**越权**。
带甲的合法 token、把请求体里的 `userId` 填成乙，就能改乙的掌握度
（审计实测：乙的 0 变成 16）。

所以规则统一在这里，只有两条：

1. **已登录 → 用登录身份，并且忽略客户端传的 `userId`**（防冒用）
2. 未登录 → 用显式传入的 `userId`（评委/curl 不带 token 也能看 demo-user）
3. 都没有 → 回退演示身份

这样既修好数据隔离，又**不破坏演示基线**：不带 token 时行为与从前完全一致。
"""

from __future__ import annotations

from typing import Any

from flask import g

#: 演示 / 游客身份，与 `app/auth/service.DEMO_USER_ID` 和前端
#: `ApiDefaults.DEMO_USER_ID` 保持一致。
DEMO_USER_ID = "demo-user"

#: userId 长度上限（与 `app/api/validation.py` 的字段上限同源）
MAX_USER_ID_CHARS = 128


def current_user_id() -> str:
    """取当前登录身份；未登录返回空串。"""
    current = getattr(g, "current_user", None)
    if isinstance(current, dict):
        value = current.get("userId")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def resolve_user_id(supplied: Any = None, default: str = DEMO_USER_ID) -> str:
    """身份解析：**已登录身份 > 显式参数 > 演示身份**。

    `supplied` 可以是请求体里的 `userId` 或 query 里的 `userId`。
    已登录时**刻意忽略**它 —— 否则任何人都能借自己的 token 去操作别人的数据。
    """
    authed = current_user_id()
    if authed:
        return authed
    if isinstance(supplied, str) and supplied.strip():
        return supplied.strip()[:MAX_USER_ID_CHARS]
    return default


def is_impersonation_attempt(supplied: Any) -> bool:
    """已登录却显式传了**别人的** userId —— 用于日志/审计，不用于拒绝。

    不直接拒绝的原因：前端某些页面仍可能带着旧参数，
    直接 403 会把正常流程打断。真正的拦截靠 `resolve_user_id` 忽略该值。
    """
    authed = current_user_id()
    if not authed or not isinstance(supplied, str) or not supplied.strip():
        return False
    return supplied.strip() != authed
