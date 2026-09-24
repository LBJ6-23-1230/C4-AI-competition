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

import hashlib
import os
import re
import secrets
import threading
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from app.repositories.repository import Repository

# --------------------------------------------------------------------------- 常量
USERS = "users"
SESSIONS = "sessions"
VERIFICATION_CODES = "verification_codes"

#: 游客 / 演示身份。未登录时的默认 userId，与后端演示数据完全一致。
DEMO_USER_ID = "demo-user"

#: 会话有效期（天）。演示场景给足余量，避免评审过程中突然登录失效。
SESSION_TTL_DAYS = 30

#: 手机号验证码策略（详见 docs/11 §5.2）。
VERIFICATION_CODE_TTL_SECONDS = 5 * 60
VERIFICATION_RESEND_SECONDS = 60
VERIFICATION_DAILY_LIMIT = 10
VERIFICATION_MAX_ATTEMPTS = 5
VERIFICATION_LOCK_SECONDS = 15 * 60

_VERIFICATION_LOCK = threading.RLock()

#: 用户主表中同时保有值、但**不属于**用户个人信息的内容。
_ALLOWED_GRADES = ("大一", "大二", "大三", "大四", "大五", "研一", "研二", "研三", "博士")

_NICKNAME_MIN = 1
_NICKNAME_MAX = 16

#: 注册时是否强制要求手机号。
#:
#: 设为 `True` 的理由：手机号是**唯一身份标识**，昵称不是。
#: 没有手机号时，"登录"只能退化成"按昵称查账号"，而昵称可以重复、
#: 也可以被任何人猜到 —— 既无法保证唯一性，也无法证明身份。
#:
#: 设为 `False` 可退回纯昵称流程（本地演示 / 无短信服务的场合）。
#: 无论取值如何，**手机号一旦提供就必须格式合法且唯一**。
_PHONE_REQUIRED = True


class AuthError(Exception):
    """带契约错误码的鉴权异常，由 API 层转成 HTTP 响应。"""

    def __init__(self, error_code: str, message: str, status: int = 400,
                 details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.message = message
        self.status = status
        self.details = details or {}


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


# 中国大陆手机号：1 开头，第二位 3-9，共 11 位
_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")


def normalize_phone(raw: Any, *, required: bool = True) -> str:
    """手机号清洗与校验。

    接受常见写法并统一：`+86 138-0000-0000`、`138 0000 0000`、
    `(86)13800000000` → 一律归一为 `13800000000`。

    ⚠️ **不做真实性校验**。真实场景需要短信验证码证明"这个号是本人的"，
    本函数只保证**格式合法且归一**。验证码链路见
    `docs/11-用户登录体系方案.md` §5.2。
    """
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        if required:
            raise AuthError("VALIDATION_ERROR", "手机号不能为空", 400)
        return ""
    if not isinstance(raw, str):
        raise AuthError("VALIDATION_ERROR", "手机号必须是字符串", 400)

    digits = re.sub(r"[^\d]", "", raw)
    if digits.startswith("86") and len(digits) == 13:
        digits = digits[2:]
    if not _PHONE_RE.match(digits):
        raise AuthError("VALIDATION_ERROR", "手机号格式不正确（应为 11 位中国大陆号码）", 400)
    return digits


def mask_phone(phone: str) -> str:
    """脱敏展示：138****0000。

    对外接口一律返回脱敏值 —— 手机号是个人敏感信息，
    没有必要完整回传给客户端（客户端只需要"能认出是哪个号"）。
    """
    if not isinstance(phone, str) or len(phone) != 11:
        return ""
    return f"{phone[:3]}****{phone[-4:]}"


def _parse_optional_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment


def _seconds_until(now: datetime, target: datetime) -> int:
    return max(1, int((target - now).total_seconds() + 0.999))


def _verification_hash(code: str, salt: str) -> str:
    return hashlib.sha256(f"{salt}:{code}".encode("ascii")).hexdigest()


def _verification_provider_configured() -> bool:
    return bool((os.getenv("SMS_PROVIDER") or "").strip())


def _verification_production_mode() -> bool:
    return (os.getenv("ZHIXUE_ENV") or "development").strip().lower() in {
        "prod", "production"}


def _empty_verification_code(record: dict[str, Any]) -> None:
    record["codeHash"] = ""
    record["salt"] = ""
    record["codeExpiresAt"] = ""


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _new_user_id() -> str:
    return f"u-{uuid.uuid4().hex[:12]}"


def _public_user(user: dict[str, Any]) -> dict[str, Any]:
    """对外的用户视图：**绝不**返回 token、auth_subject 等内部字段。

    手机号以**脱敏形式**返回（`138****0000`）：客户端只需要"能认出是哪个号"，
    完整号码没有必要回传，减少泄漏面。
    """
    return {
        "userId": user.get("userId"),
        "nickname": user.get("nickname", ""),
        "grade": user.get("grade", ""),
        "authProvider": user.get("authProvider", "guest"),
        "phoneMasked": mask_phone(user.get("phone", "")),
        "hasPhone": bool(user.get("phone")),
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
def find_users_by_nickname(repository: Repository, nickname: Any) -> list[dict[str, Any]]:
    """按昵称查账号（大小写与首尾空白不敏感）。

    为什么需要它：原先前端「登录」标签下的唯一动作是 `register()`，
    所以用同一个昵称再点一次会**又建一个新账号**（实测：
    两次注册 `张三` 得到两个不同 userId）。用户以为自己登录了，
    实际上旧画像永远读不到 —— 这是登录页最实际的缺陷。

    昵称**不唯一**，所以这里返回列表，由调用方决定：
    * 恰好 1 个 → 直接登入该账号
    * 0 个     → 提示"账号不存在，请先注册"
    * 多个     → 要求用户改用更精确的方式（当前实现返回 409 让用户换昵称）
    """
    if not isinstance(nickname, str) or not nickname.strip():
        return []
    target = nickname.strip().casefold()
    matches: list[dict[str, Any]] = []
    for user in repository.list(USERS):
        if not isinstance(user, dict) or user.get("status") != "active":
            continue
        stored = user.get("nickname")
        if isinstance(stored, str) and stored.strip().casefold() == target:
            matches.append(user)
    return matches


def login_by_nickname(repository: Repository, nickname: Any) -> dict[str, Any]:
    """按昵称登录（免密）。

    ⚠️ **安全边界必须说清楚**：昵称不是秘密，所以这**不是**一个安全的认证方式，
    只适合"演示 / 单机使用"的场景。它解决的是"同一个昵称不该产生重复账号"
    这个可用性缺陷，而不是提供真实身份校验。

    真实身份校验请走 `docs/11` 里的手机号验证码方案
    （或接入华为 AGC 认证服务）。
    """
    matches = find_users_by_nickname(repository, nickname)
    if not matches:
        raise AuthError("NOT_FOUND", "该昵称还没有账号，请先注册", 404)
    if len(matches) > 1:
        raise AuthError("CONFLICT",
                        f"昵称「{normalize_nickname(nickname)}」对应 {len(matches)} 个账号，"
                        "请改用更精确的昵称或使用手机号登录", 409)

    user = matches[0]
    user_id = user["userId"]
    session = create_session(repository, user_id)
    user["lastLoginAt"] = _iso(_now())
    repository.save(USERS, user_id, user)
    return {"user": _public_user(user), "token": session["token"],
            "expiresAt": session["expiresAt"]}


def find_user_by_phone(repository: Repository, phone: Any) -> dict[str, Any] | None:
    """按手机号查账号。

    与昵称不同，**手机号是唯一的** —— 所以这里返回单个用户或 None，
    并且在注册时保证唯一。这是手机号登录比昵称登录可靠的根本原因。

    ⚠️ 必须走 `normalize_phone()` 做**同一套归一化**。
    这里曾经只做 `re.sub(r"[^\\d]", ...)`，漏掉了 `+86` 前缀剥离，
    于是 `+86 139-0000-0001` 查不到已存的 `13900000001`
    ——**注册用归一化、查询用另一套规则，是最隐蔽的一类不一致**。
    """
    normalized = normalize_phone(phone, required=False)
    if not normalized:
        return None
    for user in repository.list(USERS):
        if not isinstance(user, dict) or user.get("status") != "active":
            continue
        if user.get("phone") == normalized:
            return user
    return None


def login_by_phone(repository: Repository, phone: Any) -> dict[str, Any]:
    """手机号登录（**免验证码版本**）。

    ⚠️ 这不是完整的手机号登录：真实场景必须先验证短信验证码，
    证明"这个号是本人的"。本函数只做"号存在即登录"，
    适用于演示 / 内网环境。

    完整验证码链路（含限流、锁定、哈希存储）见
    `docs/11-用户登录体系方案.md` §5.2。
    """
    user = find_user_by_phone(repository, phone)
    if user is None:
        raise AuthError("NOT_FOUND", "该手机号还没有账号，请先注册", 404)
    user_id = user["userId"]
    session = create_session(repository, user_id)
    user["lastLoginAt"] = _iso(_now())
    repository.save(USERS, user_id, user)
    return {"user": _public_user(user), "token": session["token"],
            "expiresAt": session["expiresAt"]}


def send_verification_code(repository: Repository, phone: Any,
                           *, now: datetime | None = None) -> dict[str, Any]:
    """签发手机号验证码；开发环境回显 devCode，生产环境不回显。

    限流与锁定都作用于同一手机号：60 秒重发间隔、滚动 24 小时最多 10 次。
    验证码本身只以 `sha256(code + salt)` 形式保存。
    """
    clean_phone = normalize_phone(phone)
    current = now or _now()
    with _VERIFICATION_LOCK:
        record = repository.get(VERIFICATION_CODES, clean_phone) or {}

        locked_until = _parse_optional_time(record.get("lockedUntil"))
        if locked_until is not None and locked_until > current:
            raise AuthError(
                "PHONE_LOCKED",
                "该手机号因验证码错误次数过多已被临时锁定",
                429,
                {"retryAfterSeconds": _seconds_until(current, locked_until)},
            )

        last_sent_at = _parse_optional_time(record.get("lastSentAt"))
        if last_sent_at is not None:
            resend_at = last_sent_at + timedelta(seconds=VERIFICATION_RESEND_SECONDS)
            if current < resend_at:
                raise AuthError(
                    "RATE_LIMITED",
                    f"验证码发送过于频繁，请 {_seconds_until(current, resend_at)} 秒后再试",
                    429,
                    {"retryAfterSeconds": _seconds_until(current, resend_at)},
                )

        window_started_at = _parse_optional_time(record.get("windowStartedAt"))
        try:
            send_count = int(record.get("sendCount", 0))
        except (TypeError, ValueError):
            send_count = 0
        window_expired = (
            window_started_at is None
            or current >= window_started_at + timedelta(hours=24)
        )
        if window_expired:
            window_started_at = current
            send_count = 0
        if send_count >= VERIFICATION_DAILY_LIMIT:
            raise AuthError(
                "DAILY_LIMIT_REACHED",
                f"该手机号 24 小时内最多发送 {VERIFICATION_DAILY_LIMIT} 次验证码",
                429,
                {"limit": VERIFICATION_DAILY_LIMIT},
            )

        if _verification_provider_configured():
            # 生产短信适配器尚未接入。拒绝把“未发送”伪装成已送达。
            raise AuthError(
                "SMS_PROVIDER_UNAVAILABLE",
                "短信服务商已配置，但当前构建未接入发送适配器",
                503,
            )
        if _verification_production_mode():
            raise AuthError(
                "SMS_NOT_CONFIGURED",
                "生产环境未配置短信服务商，拒绝回显开发验证码",
                503,
            )

        code = f"{secrets.randbelow(1_000_000):06d}"
        salt = secrets.token_hex(16)
        previous_lock_expired = (
            locked_until is not None and locked_until <= current)
        try:
            failed_attempts = int(record.get("failedAttempts", 0))
        except (TypeError, ValueError):
            failed_attempts = 0
        if previous_lock_expired:
            failed_attempts = 0

        record.update({
            "phone": clean_phone,
            "codeHash": _verification_hash(code, salt),
            "salt": salt,
            "codeIssuedAt": _iso(current),
            "codeExpiresAt": _iso(
                current + timedelta(seconds=VERIFICATION_CODE_TTL_SECONDS)),
            "lastSentAt": _iso(current),
            "windowStartedAt": _iso(window_started_at),
            "sendCount": send_count + 1,
            "failedAttempts": failed_attempts,
            "lockedUntil": "",
        })
        repository.save(VERIFICATION_CODES, clean_phone, record)

    return {
        "phoneMasked": mask_phone(clean_phone),
        "expiresInSeconds": VERIFICATION_CODE_TTL_SECONDS,
        "resendAfterSeconds": VERIFICATION_RESEND_SECONDS,
        "smsDelivered": False,
        "devCode": code,
    }


def verify_verification_code(repository: Repository, phone: Any, code: Any,
                             nickname: Any = None, grade: Any = None,
                             *, now: datetime | None = None) -> dict[str, Any]:
    """校验验证码；通过后自动登录已有账号，或注册新账号。"""
    clean_phone = normalize_phone(phone)
    if not isinstance(code, str) or not re.fullmatch(r"\d{6}", code.strip()):
        raise AuthError("VALIDATION_ERROR", "验证码必须是 6 位数字", 400)
    clean_code = code.strip()
    current = now or _now()

    with _VERIFICATION_LOCK:
        record = repository.get(VERIFICATION_CODES, clean_phone)
        if record is None:
            raise AuthError("CODE_NOT_FOUND", "请先获取验证码", 400)

        locked_until = _parse_optional_time(record.get("lockedUntil"))
        if locked_until is not None and locked_until > current:
            raise AuthError(
                "PHONE_LOCKED",
                "该手机号因验证码错误次数过多已被临时锁定",
                429,
                {"retryAfterSeconds": _seconds_until(current, locked_until)},
            )

        code_hash = record.get("codeHash")
        salt = record.get("salt")
        code_expires_at = _parse_optional_time(record.get("codeExpiresAt"))
        if not isinstance(code_hash, str) or not code_hash or not isinstance(salt, str):
            raise AuthError("CODE_NOT_FOUND", "验证码不存在或已被使用", 400)
        if code_expires_at is None or code_expires_at <= current:
            _empty_verification_code(record)
            repository.save(VERIFICATION_CODES, clean_phone, record)
            raise AuthError("CODE_EXPIRED", "验证码已过期，请重新获取", 400)

        expected_hash = _verification_hash(clean_code, salt)
        if not secrets.compare_digest(expected_hash, code_hash):
            try:
                failed_attempts = int(record.get("failedAttempts", 0)) + 1
            except (TypeError, ValueError):
                failed_attempts = 1
            record["failedAttempts"] = failed_attempts
            if failed_attempts >= VERIFICATION_MAX_ATTEMPTS:
                locked_until = current + timedelta(seconds=VERIFICATION_LOCK_SECONDS)
                record["lockedUntil"] = _iso(locked_until)
                repository.save(VERIFICATION_CODES, clean_phone, record)
                raise AuthError(
                    "PHONE_LOCKED",
                    "验证码错误次数过多，该手机号已锁定 15 分钟",
                    429,
                    {"retryAfterSeconds": _seconds_until(current, locked_until)},
                )
            repository.save(VERIFICATION_CODES, clean_phone, record)
            raise AuthError(
                "INVALID_CODE",
                "验证码错误",
                400,
                {"remainingAttempts": VERIFICATION_MAX_ATTEMPTS - failed_attempts},
            )

        existing = find_user_by_phone(repository, clean_phone)
        clean_nickname = None
        clean_grade = None
        if existing is None:
            clean_nickname = normalize_nickname(
                nickname if nickname else f"用户{clean_phone[-4:]}")
            clean_grade = normalize_grade(grade)

        # 一次性消费：立即清空哈希与过期时间，但保留限流窗口元数据。
        _empty_verification_code(record)
        record.update({
            "failedAttempts": 0,
            "lockedUntil": "",
            "lastVerifiedAt": _iso(current),
        })
        repository.save(VERIFICATION_CODES, clean_phone, record)

        if existing is not None:
            result = login_by_phone(repository, clean_phone)
            return {**result, "created": False}

        result = register_user(repository, clean_nickname, clean_grade, clean_phone)
        provision_starter_profile(
            repository, result["user"]["userId"], result["user"]["nickname"])
        return {**result, "created": True}


def register_user(repository: Repository, nickname: Any, grade: Any = None,
                  phone: Any = None) -> dict[str, Any]:
    """创建账号：昵称 + 年级 + 手机号 → userId + token。不需要密码。

    **手机号唯一**：同一个手机号重复注册会返回 409 `CONFLICT`，
    而不是悄悄建第二个账号 —— 这正是手机号作为身份标识的价值。

    昵称**有意允许重复**（`_new_user_id()` 保证 userId 唯一即可）。
    但调用方若要避免"用户以为在登录、实际在新建账号"，应先走
    `login_by_phone()` / `login_by_nickname()`，只在确实查无此账号时才注册。
    """
    clean_nickname = normalize_nickname(nickname)
    clean_grade = normalize_grade(grade)
    clean_phone = normalize_phone(phone, required=_PHONE_REQUIRED)

    if clean_phone:
        existing = find_user_by_phone(repository, clean_phone)
        if existing is not None:
            raise AuthError(
                "CONFLICT",
                f"该手机号已注册（{mask_phone(clean_phone)}），请直接登录",
                409)

    user_id = _new_user_id()
    while repository.get(USERS, user_id) is not None:  # 概率极低，防御性处理
        user_id = _new_user_id()

    timestamp = _iso(_now())
    user = {
        "userId": user_id,
        "nickname": clean_nickname,
        "grade": clean_grade,
        "phone": clean_phone,
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


def login_with_huawei(repository: Repository, open_id: Any,
                      union_id: Any = None, nickname: Any = None,
                      grade: Any = None) -> dict[str, Any]:
    """华为账号登录（**登录优先，注册兜底**）。

    用开放标识 `openId` + `authProvider='agc_phone'` 作为身份键：
    * 同一华为账号再次登录 → 复用既有账号
    * 首次登录 → 自动建号（这就是"一键登录"的体验：用户没填任何东西）

    为什么用 `openId` 而不是 `unionId` 做键：`openId` 是**应用内唯一**的，
    换应用会变，天然避免跨应用追踪；`unionId` 保留在用户记录里，
    将来有多个应用时可以打通。

    ⚠️ **安全边界（必须说清）**：本函数**不校验 OpenID 真伪**。
    真正的生产实现需要在服务端调用华为的接口验签（或用 `idToken` 校验），
    否则任何人伪造一个 openId 就能登入他人账号。当前版本定位是
    "演示可用、生产需补验签"，见 `docs/13-全场景与华为账号登录方案.md`。
    """
    if not isinstance(open_id, str) or not open_id.strip():
        raise AuthError("VALIDATION_ERROR", "华为账号未返回 OpenID，无法登录", 400)
    clean_open_id = open_id.strip()
    if len(clean_open_id) > 256:
        raise AuthError("VALIDATION_ERROR", "OpenID 长度异常", 400)

    existing = None
    for user in repository.list(USERS):
        if not isinstance(user, dict) or user.get("status") != "active":
            continue
        if user.get("authSubject") == clean_open_id:
            existing = user
            break

    if existing is not None:
        user_id = existing["userId"]
        session = create_session(repository, user_id)
        existing["lastLoginAt"] = _iso(_now())
        repository.save(USERS, user_id, existing)
        return {"user": _public_user(existing), "token": session["token"],
                "expiresAt": session["expiresAt"], "created": False}

    # 首次登录：自动建号，昵称用客户端给的，缺省则用 openId 后 6 位做占位
    fallback = f"华友{clean_open_id[-6:]}" if len(clean_open_id) >= 6 else "华为用户"
    clean_nickname = normalize_nickname(nickname if nickname else fallback)
    clean_grade = normalize_grade(grade)
    user_id = _new_user_id()
    while repository.get(USERS, user_id) is not None:
        user_id = _new_user_id()

    timestamp = _iso(_now())
    user = {
        "userId": user_id,
        "nickname": clean_nickname,
        "grade": clean_grade,
        "phone": "",
        "avatar": "",
        # 复用既有枚举：agc_phone 表示"来自华为账号体系"
        "authProvider": "agc_phone",
        "authSubject": clean_open_id,
        "authUnionId": (union_id or "").strip() if isinstance(union_id, str) else "",
        "status": "active",
        "createdAt": timestamp,
        "lastLoginAt": timestamp,
    }
    repository.save(USERS, user_id, user)
    session = create_session(repository, user_id)
    return {"user": _public_user(user), "token": session["token"],
            "expiresAt": session["expiresAt"], "created": True}


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
