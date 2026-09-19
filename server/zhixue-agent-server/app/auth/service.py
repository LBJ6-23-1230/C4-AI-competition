# -*- coding: utf-8 -*-
"""鉴权领域逻辑（纯函数式，不依赖 Flask）。

设计取舍（与 `docs/02-登录界面设计与用户数据库方案.md` 一致）
--------------------------------------------------------------
1. **不做密码体系**。本项目没有任何需要密码保护的东西（无支付、无隐私资产），
   自建密码存储（bcrypt / argon2 + 加盐）是纯负担与合规风险。
   方案：注册只取昵称 + 年级 → 服务端下发 `userId`（UUID）与 `token`（随机串）。
2. **`demo-user` 是保留的游客身份**。未登录 / 「一键体验」/ 离线 Fixture 全部使用它，
   因此**演示主链的数值与行为完全不受登录功能影响**（`demo/reset` 依然只作用于 demo-user）。
3. **不记录手机号明文**。`auth_subject` 只存第三方（如 AGC）返回的 uid，
   需要展示时由客户端脱敏。
4. 全部函数只接收 `Repository`，便于把 `JsonRepository` 换成 `SqliteRepository`
   （`app/repositories/sqlite_repository.py` 已实现同一套协议，`create_app` 改一行即可）。
"""

from __future__ import annotations

import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from app.repositories.repository import Repository

# --------------------------------------------------------------------------- 常量
USERS = "users"
SESSIONS = "sessions"

#: 游客 / 演示身份。未登录时的默认 userId，与后端演示数据完全一致。
DEMO_USER_ID = "demo-user"

#: 会话有效期（天）。演示场景给足余量，避免评审过程中突然登录失效。
SESSION_TTL_DAYS = 30

#: 用户主表中同时保有值、但**不属于**用户个人信息的内容。
_ALLOWED_GRADES = ("大一", "大二", "大三", "大四", "大五", "研一", "研二", "研三", "博士")

_NICKNAME_MIN = 1
_NICKNAME_MAX = 16


class AuthError(Exception):
    """带契约错误码的鉴权异常，由 API 层转成 HTTP 响应。"""

    def __init__(self, error_code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.message = message
        self.status = status


# --------------------------------------------------------------------------- 工具
def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(moment: datetime) -> str:
    return moment.replace(microsecond=0).isoformat()


def normalize_nickname(raw: Any) -> str:
    """昵称清洗：去空白、限长、拒绝空值与换行。

    刻意**不做**敏感词过滤等重型校验——那是服务端策略，不是演示工程的职责；
    但必须挡住空值、超长与纯空白，否则会污染画像页与搭子匹配的展示。
    """
    if not isinstance(raw, str):
        raise AuthError("VALIDATION_ERROR", "昵称必须是字符串", 400)
    nickname = raw.strip()
    if len(nickname) < _NICKNAME_MIN:
        raise AuthError("VALIDATION_ERROR", "昵称不能为空", 400)
    if len(nickname) > _NICKNAME_MAX:
        raise AuthError("VALIDATION_ERROR", f"昵称不能超过 {_NICKNAME_MAX} 个字符", 400)
    if any(ch in nickname for ch in ("\n", "\r", "\t")):
        raise AuthError("VALIDATION_ERROR", "昵称不能包含换行或制表符", 400)
    return nickname


def normalize_grade(raw: Any) -> str:
    """年级：允许缺省；给了就必须是白名单内的值（避免前端传任意串污染展示）。"""
    if raw is None:
        return ""
    if not isinstance(raw, str):
        raise AuthError("VALIDATION_ERROR", "年级必须是字符串", 400)
    grade = raw.strip()
    if not grade:
        return ""
    if grade not in _ALLOWED_GRADES:
        raise AuthError("VALIDATION_ERROR", f"年级必须是以下之一：{'/'.join(_ALLOWED_GRADES)}", 400)
    return grade


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _new_user_id() -> str:
    return f"u-{uuid.uuid4().hex[:12]}"


def _public_user(user: dict[str, Any]) -> dict[str, Any]:
    """对外的用户视图：**绝不**返回 token、auth_subject 等内部字段。"""
    return {
        "userId": user.get("userId"),
        "nickname": user.get("nickname", ""),
        "grade": user.get("grade", ""),
        "authProvider": user.get("authProvider", "guest"),
        "createdAt": user.get("createdAt", ""),
        "lastLoginAt": user.get("lastLoginAt", ""),
    }


# --------------------------------------------------------------------------- 会话
def create_session(repository: Repository, user_id: str) -> dict[str, Any]:
    token = _new_token()
    expires_at = _now() + timedelta(days=SESSION_TTL_DAYS)
    session = {
        "token": token,
        "userId": user_id,
        "createdAt": _iso(_now()),
        "expiresAt": _iso(expires_at),
    }
    repository.save(SESSIONS, token, session)
    return session


def resolve_session(repository: Repository, token: str) -> dict[str, Any] | None:
    """把 token 换成用户；过期或不存在返回 None（不抛异常，便于中间件安全降级）。"""
    if not token:
        return None
    session = repository.get(SESSIONS, token)
    if session is None:
        return None
    expires_raw = str(session.get("expiresAt", ""))
    try:
        expires_at = datetime.fromisoformat(expires_raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    if expires_at < _now():
        repository.delete(SESSIONS, token)
        return None
    user_id = str(session.get("userId", ""))
    if not user_id:
        return None
    return repository.get(USERS, user_id)


def revoke_session(repository: Repository, token: str) -> bool:
    if not token or repository.get(SESSIONS, token) is None:
        return False
    repository.delete(SESSIONS, token)
    return True


def revoke_all_sessions(repository: Repository, user_id: str) -> int:
    """注销账号 / 安全事件时清空该用户所有会话。"""
    removed = 0
    for session in repository.list(SESSIONS):
        if session.get("userId") == user_id:
            repository.delete(SESSIONS, str(session.get("token", "")))
            removed += 1
    return removed


# --------------------------------------------------------------------------- 注册 / 登录
def register_user(repository: Repository, nickname: Any, grade: Any = None) -> dict[str, Any]:
    """创建账号：昵称 + 年级 → userId + token。不需要密码。"""
    clean_nickname = normalize_nickname(nickname)
    clean_grade = normalize_grade(grade)

    user_id = _new_user_id()
    while repository.get(USERS, user_id) is not None:  # 概率极低，防御性处理
        user_id = _new_user_id()

    timestamp = _iso(_now())
    user = {
        "userId": user_id,
        "nickname": clean_nickname,
        "grade": clean_grade,
        "avatar": "",
        "authProvider": "local",
        "authSubject": "",
        "status": "active",
        "createdAt": timestamp,
        "lastLoginAt": timestamp,
    }
    repository.save(USERS, user_id, user)
    session = create_session(repository, user_id)

    return {"user": _public_user(user), "token": session["token"],
            "expiresAt": session["expiresAt"]}


def login_user(repository: Repository, user_id: Any, token: Any) -> dict[str, Any]:
    """用已保存的 (userId, token) 恢复登录态。

    这是「免密登录」的合理形式：token 就是凭据，等价于长期会话票据。
    """
    if not isinstance(user_id, str) or not user_id.strip():
        raise AuthError("VALIDATION_ERROR", "userId 不能为空", 400)
    if not isinstance(token, str) or not token.strip():
        raise AuthError("VALIDATION_ERROR", "token 不能为空", 400)

    user = repository.get(USERS, user_id.strip())
    if user is None or user.get("status") != "active":
        raise AuthError("UNAUTHORIZED", "账号不存在或已注销，请重新注册", 401)

    session = repository.get(SESSIONS, token.strip())
    if session is None or session.get("userId") != user_id.strip():
        raise AuthError("UNAUTHORIZED", "登录已失效，请重新登录", 401)

    refreshed = resolve_session(repository, token.strip())
    if refreshed is None:
        raise AuthError("UNAUTHORIZED", "登录已过期，请重新登录", 401)

    user["lastLoginAt"] = _iso(_now())
    repository.save(USERS, user_id.strip(), user)
    return {"user": _public_user(user), "token": token.strip(),
            "expiresAt": session.get("expiresAt", "")}


def get_user(repository: Repository, user_id: str) -> dict[str, Any] | None:
    user = repository.get(USERS, user_id)
    if user is None or user.get("status") != "active":
        return None
    return _public_user(user)


def deactivate_user(repository: Repository, user_id: str) -> bool:
    """注销账号：标记停用 + 清空全部会话。

    合规要求（《个人信息保护法》账号注销权）。演示工程采取**软删除**：
    保留 users 行的 status 标记以便审计，但立即断开所有登录入口。
    真实生产环境还应级联清理该用户的画像 / 计划 / 对话等衍生数据。
    """
    user = repository.get(USERS, user_id)
    if user is None:
        return False
    user["status"] = "deactivated"
    user["deactivatedAt"] = _iso(_now())
    repository.save(USERS, user_id, user)
    revoke_all_sessions(repository, user_id)
    return True


# --------------------------------------------------------------------------- 新用户画像预置
def provision_starter_profile(repository: Repository, user_id: str, nickname: str) -> None:
    """给新账号预置一份空画像与起始计划。

    为什么需要：`/api/v1/profile/{userId}` 在画像不存在时返回 404（契约如此），
    而新账号没有任何学习证据。若不预置，登录后首页会立刻报「画像不存在」。
    这里给一份 mastery=0 的空壳，让「学习 → 判分 → 掌握度提升」的完整叙事
    对真实账号同样成立——**这正是登录功能的价值所在**。

    注意：**只有新注册的真实账号**会走这里；`demo-user` 的演示基线
    （mastery=42 / Plan V1 [30,30]）由 `app/api/demo.py` 单独维护，两者互不干扰。
    """
    if repository.get("profiles", user_id) is not None:
        return

    from app.domain.plan import LearningPlan
    from app.domain.profile import KnowledgeMastery, LearnerProfile

    timestamp = _now()
    profile = LearnerProfile(
        user_id,
        f"{nickname}的学习目标",
        None,
        ["20:00-22:00"],
        1,
        [KnowledgeMastery("binary-tree-postorder", 0, 0.2, timestamp, "二叉树后序遍历")],
    )
    repository.save("profiles", user_id, profile.to_dict())

    plan = LearningPlan(
        f"plan-{user_id}",
        1,
        [{"taskId": "task-postorder", "knowledgePointId": "binary-tree-postorder",
          "knowledgePointName": "二叉树后序遍历", "durationMinutes": 30,
          "status": "pending", "priority": "high"}],
        1,
        "新账号起始计划：从二叉树后序遍历开始",
    )
    plan_data = plan.to_dict()
    plan_data["userId"] = user_id
    repository.save("plans", plan.plan_id, plan_data)


# --------------------------------------------------------------------------- 供中间件使用
_BEARER_PATTERN = re.compile(r"^Bearer\s+(?P<token>.+)$", re.IGNORECASE)


def parse_bearer(header_value: str | None) -> str:
    """从 `Authorization: Bearer <token>` 中取出 token；格式不符返回空串。"""
    if not header_value:
        return ""
    matched = _BEARER_PATTERN.match(header_value.strip())
    return matched.group("token").strip() if matched else ""
