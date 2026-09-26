# -*- coding: utf-8 -*-
"""登录链路回归测试。

对应登录页最实际的两个缺陷：
1. 「登录」标签下用同一昵称再点一次会**又建一个新账号**（实测两次注册
   「张三」得到两个不同 userId），用户以为登录了、实际旧画像永远读不到。
2. 换设备/清应用数据后**没有可用的登录入口** —— 原 `/auth/login` 需要
   `userId + token`，而 token 只存在原设备的 preferences 里。
"""

from app import create_app


# --------------------------------------------------------------------- 测试辅助
_PHONE_SEQ = {"n": 0}


def _phone() -> str:
    """生成唯一且合法的测试手机号（手机号现在必填且唯一）。"""
    _PHONE_SEQ["n"] += 1
    return f"1390000{_PHONE_SEQ['n']:04d}"


#: 测试账号统一用的密码。
#:
#: 为什么必须给测试账号设密码：`_verify_password()` 现在**拒绝**用密码登录
#: "从未设过密码"的账号 —— 此前它遇到空 `passwordHash` 直接放行，等于**任意密码
#: 都能登进去**（已按界面路径实测复现：验证码建号 → 密码输入 `zzzzzz` → 200）。
#: 下面这些用例测的是「登回同一账号 / 手机号格式归一化 / 昵称去空格」，
#: 与"有没有密码"无关，所以统一带上密码，保持它们原本的意图不变。
_TEST_PASSWORD = "test-pw-123456"


def _register(client, nickname, grade=None, phone=None, password=_TEST_PASSWORD):
    return client.post("/api/v1/auth/register",
                       json={"nickname": nickname, "grade": grade,
                             "phone": phone or _phone(), "password": password})


# --------------------------------------------------- 登录优先 / 注册兜底
def test_login_or_register_reuses_existing_account(tmp_path):
    """同一手机号/昵称第二次调用必须**登录**，不得再建账号。"""
    client = create_app(tmp_path / "lor.json").test_client()
    phone = _phone()

    first = client.post("/api/v1/auth/login-or-register",
                        json={"nickname": "张三", "grade": "大二", "phone": phone,
                              "password": _TEST_PASSWORD})
    assert first.status_code == 201
    first_body = first.get_json()
    assert first_body["created"] is True
    first_id = first_body["user"]["userId"]

    second = client.post("/api/v1/auth/login-or-register",
                         json={"nickname": "张三", "grade": "大二", "phone": phone,
                               "password": _TEST_PASSWORD})
    assert second.status_code == 200
    second_body = second.get_json()

    assert second_body["created"] is False, "第二次应当是登录，而不是新建账号"
    assert second_body["user"]["userId"] == first_id, "必须复用同一 userId"


def test_login_or_register_prefers_phone_over_nickname(tmp_path):
    """手机号优先于昵称：换了昵称但号相同，仍应登入同一账号。

    这是手机号作为**唯一身份标识**的核心价值 —— 昵称只是展示名，
    改了昵称不该变成另一个人。
    """
    client = create_app(tmp_path / "lor-phone.json").test_client()
    phone = _phone()

    first = client.post("/api/v1/auth/login-or-register",
                        json={"nickname": "原名", "phone": phone,
                              "password": _TEST_PASSWORD}).get_json()
    renamed = client.post("/api/v1/auth/login-or-register",
                          json={"nickname": "改了个名", "phone": phone,
                                "password": _TEST_PASSWORD}).get_json()

    assert renamed["created"] is False
    assert renamed["user"]["userId"] == first["user"]["userId"]


def test_login_or_register_creates_when_absent(tmp_path):
    client = create_app(tmp_path / "lor-new.json").test_client()

    response = client.post("/api/v1/auth/login-or-register",
                           json={"nickname": "新同学", "phone": _phone()})

    assert response.status_code == 201
    assert response.get_json()["created"] is True


# --------------------------------------------------- 按手机号登录
def test_login_by_phone_returns_same_account(tmp_path):
    """凭手机号登回原账号（换设备场景的主入口）。"""
    client = create_app(tmp_path / "byphone.json").test_client()

    phone = _phone()
    registered = _register(client, "李四", "大一", phone=phone)
    original_id = registered.get_json()["user"]["userId"]
    assert registered.get_json()["user"]["phoneMasked"], "注册响应应当带脱敏手机号"

    response = client.post("/api/v1/auth/login",
                           json={"phone": phone, "password": _TEST_PASSWORD})

    assert response.status_code == 200
    assert response.get_json()["user"]["userId"] == original_id


def test_login_by_phone_accepts_common_formats(tmp_path):
    """`+86 138-0000-0000` 这类写法要能归一后登入。"""
    client = create_app(tmp_path / "byphone-fmt.json").test_client()
    phone = _phone()

    registered = _register(client, "格式测试", phone=phone).get_json()
    formatted = f"+86 {phone[:3]}-{phone[3:7]}-{phone[7:]}"

    response = client.post("/api/v1/auth/login",
                           json={"phone": formatted, "password": _TEST_PASSWORD})

    assert response.status_code == 200
    assert response.get_json()["user"]["userId"] == registered["user"]["userId"]


def test_login_by_unknown_phone_is_404(tmp_path):
    client = create_app(tmp_path / "unknown-phone.json").test_client()

    response = client.post("/api/v1/auth/login", json={"phone": "13700000099"})

    assert response.status_code == 404
    assert response.get_json()["errorCode"] == "NOT_FOUND"


def test_password_account_calls_backend_and_rejects_wrong_password(tmp_path):
    client = create_app(tmp_path / "password-login.json").test_client()
    phone = _phone()
    created = client.post("/api/v1/auth/login-or-register", json={
        "nickname": "密码用户", "phone": phone, "password": "secret88",
    })
    assert created.status_code == 201

    wrong = client.post("/api/v1/auth/login", json={
        "phone": phone, "password": "wrong000",
    })
    assert wrong.status_code == 401
    assert wrong.get_json()["errorCode"] == "UNAUTHORIZED"

    correct = client.post("/api/v1/auth/login", json={
        "phone": phone, "password": "secret88",
    })
    assert correct.status_code == 200
    assert correct.get_json()["user"]["userId"] == created.get_json()["user"]["userId"]


def test_passwordless_account_cannot_log_in_with_any_password(tmp_path):
    """★ 回归：验证码建出来的账号**没有密码**，因此不能用密码登录 ——
    更不能"任意密码都能过"。

    缺陷形态（已按界面路径实测复现）：`_verify_password()` 遇到空 `passwordHash`
    直接 `return`（本意是"兼容历史免密账号"），而登录接口在任何密码下都会走到
    那里并放行 —— 于是 `zzzzzz`、空串、乱码统统能登进一个**不是自己的**账号。
    这条路正是"知道手机号就能登入"的入口。

    修法：空 `passwordHash` 视为"从未设过密码"，**如实拒绝**并指引用户走验证码登录，
    而不是静默放行。
    """
    client = create_app(tmp_path / "passwordless.json").test_client()
    phone = _phone()

    # 走验证码链路建号 —— 该链路拿不到 password，所以账号是"无密码"的
    sent = client.post("/api/v1/auth/send-code", json={"phone": phone}).get_json()
    code = sent.get("devCode")
    assert code, "测试环境应处于开发模式（conftest 已显式钉住 ZHIXUE_ENV=development）"

    created = client.post("/api/v1/auth/verify-code",
                          json={"phone": phone, "code": code, "nickname": "验证码用户"})
    assert created.status_code == 201

    for password in ("zzzzzz", "", "whatever-1"):
        response = client.post("/api/v1/auth/login",
                               json={"phone": phone, "password": password})
        assert response.status_code == 401, f"密码 {password!r} 竟然登进去了"


def _auth_header_for(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_change_password_verifies_old_password_and_takes_effect(tmp_path):
    """★ 回归：改密码必须验证原密码；改完新密码可用、旧密码失效。

    对应实测反馈「APP 目前没有修改密码的入口，需要增加一个用户自己修改密码的功能」。
    """
    client = create_app(tmp_path / "change-pw.json").test_client()
    phone = _phone()
    created = client.post("/api/v1/auth/login-or-register", json={
        "nickname": "改密用户", "phone": phone, "password": "old-pw-123456",
    }).get_json()
    headers = _auth_header_for(created["token"])

    # 原密码不对 → 401，且**不生效**
    wrong = client.post("/api/v1/auth/change-password",
                        json={"oldPassword": "nope-000000", "newPassword": "new-pw-123456"},
                        headers=headers)
    assert wrong.status_code == 401, wrong.get_json()
    assert client.post("/api/v1/auth/login",
                       json={"phone": phone, "password": "old-pw-123456"}).status_code == 200

    # 原密码正确 → 200
    ok = client.post("/api/v1/auth/change-password",
                     json={"oldPassword": "old-pw-123456", "newPassword": "new-pw-123456"},
                     headers=headers)
    assert ok.status_code == 200, ok.get_json()
    assert ok.get_json()["wasFirstTime"] is False

    # 新密码可登录、旧密码失效
    assert client.post("/api/v1/auth/login",
                       json={"phone": phone, "password": "new-pw-123456"}).status_code == 200
    assert client.post("/api/v1/auth/login",
                       json={"phone": phone, "password": "old-pw-123456"}).status_code == 401


def test_change_password_first_time_for_verification_code_account(tmp_path):
    """验证码建号是无密码的 → 登录后可以**首次设置**密码（无需原密码）。

    这正是"没有改密入口就永远补不上密码"那条断链的修复。
    """
    client = create_app(tmp_path / "change-pw-first.json").test_client()
    phone = _phone()
    code = client.post("/api/v1/auth/send-code", json={"phone": phone}).get_json()["devCode"]
    created = client.post("/api/v1/auth/verify-code",
                          json={"phone": phone, "code": code, "nickname": "首设用户"})
    headers = _auth_header_for(created.get_json()["token"])

    ok = client.post("/api/v1/auth/change-password",
                     json={"newPassword": "first-pw-123456"}, headers=headers)
    assert ok.status_code == 200, ok.get_json()
    assert ok.get_json()["wasFirstTime"] is True

    assert client.post("/api/v1/auth/login",
                       json={"phone": phone, "password": "first-pw-123456"}).status_code == 200


def test_change_password_requires_login(tmp_path):
    """未登录不能改密码 —— 否则就是一个人人可用的越权接口。"""
    client = create_app(tmp_path / "change-pw-anon.json").test_client()

    response = client.post("/api/v1/auth/change-password", json={"newPassword": "whatever-1"})

    assert response.status_code == 401


def test_change_password_rejects_short_new_password(tmp_path):
    client = create_app(tmp_path / "change-pw-short.json").test_client()
    created = client.post("/api/v1/auth/login-or-register", json={
        "nickname": "短密用户", "phone": _phone(), "password": "old-pw-123456",
    }).get_json()

    response = client.post("/api/v1/auth/change-password",
                           json={"oldPassword": "old-pw-123456", "newPassword": "abc"},
                           headers=_auth_header_for(created["token"]))

    assert response.status_code == 400, response.get_json()


def test_password_hash_is_not_exposed_or_stored_as_plaintext(tmp_path):
    database = tmp_path / "password-storage.json"
    client = create_app(database).test_client()
    response = client.post("/api/v1/auth/register", json={
        "nickname": "安全用户", "phone": _phone(), "password": "plain-secret",
    })
    assert response.status_code == 201
    assert "password" not in str(response.get_json()).lower()
    raw = database.read_text(encoding="utf-8")
    assert "plain-secret" not in raw
    assert "passwordHash" in raw


def test_register_requires_phone(tmp_path):
    """注册必须带手机号 —— 手机号是唯一身份标识，昵称不是。"""
    client = create_app(tmp_path / "need-phone.json").test_client()

    missing = client.post("/api/v1/auth/register", json={"nickname": "无号同学"})
    assert missing.status_code == 400
    assert "手机号" in missing.get_json()["message"]

    malformed = client.post("/api/v1/auth/register",
                            json={"nickname": "错号同学", "phone": "12345"})
    assert malformed.status_code == 400


def test_register_rejects_duplicate_phone(tmp_path):
    """手机号唯一：同号重复注册必须 409，而不是悄悄建第二个账号。"""
    client = create_app(tmp_path / "dup-phone.json").test_client()
    phone = _phone()
    _register(client, "第一个", phone=phone)

    response = client.post("/api/v1/auth/register",
                           json={"nickname": "第二个", "phone": phone})

    assert response.status_code == 409
    assert response.get_json()["errorCode"] == "CONFLICT"


def test_register_response_never_leaks_full_phone(tmp_path):
    """响应只回脱敏手机号，完整号码不回传。"""
    client = create_app(tmp_path / "mask.json").test_client()
    phone = _phone()

    body = _register(client, "脱敏测试", phone=phone).get_json()

    raw = str(body)
    assert phone not in raw, "完整手机号不应出现在响应里"
    assert body["user"]["phoneMasked"] == f"{phone[:3]}****{phone[-4:]}"
    assert body["user"]["hasPhone"] is True


def test_login_by_unknown_nickname_is_404(tmp_path):
    """昵称不存在时要明确报错，而不是悄悄建号。"""
    client = create_app(tmp_path / "unknown.json").test_client()

    response = client.post("/api/v1/auth/login", json={"nickname": "从没注册过"})

    assert response.status_code == 404
    assert response.get_json()["errorCode"] == "NOT_FOUND"
    assert "还没有账号" in response.get_json()["message"]


def test_login_by_nickname_is_trim_and_case_tolerant(tmp_path):
    client = create_app(tmp_path / "tolerant.json").test_client()
    registered = _register(client, "Tom", "大二").get_json()
    original_id = registered["user"]["userId"]

    for variant in ("  Tom  ", "tom", "TOM"):
        response = client.post("/api/v1/auth/login",
                               json={"nickname": variant, "password": _TEST_PASSWORD})
        assert response.status_code == 200, f"{variant!r} 应当能登入"
        assert response.get_json()["user"]["userId"] == original_id


def test_login_by_ambiguous_nickname_is_409(tmp_path):
    """昵称不唯一时必须报冲突，不能随便挑一个账号登入。"""
    client = create_app(tmp_path / "ambiguous.json").test_client()
    _register(client, "重名用户")
    _register(client, "重名用户")

    response = client.post("/api/v1/auth/login", json={"nickname": "重名用户"})

    assert response.status_code == 409
    assert response.get_json()["errorCode"] == "CONFLICT"


# --------------------------------------------------- 向后兼容
def test_login_with_user_id_and_token_still_works(tmp_path):
    """老的 (userId, token) 恢复路径不能被破坏。"""
    client = create_app(tmp_path / "compat.json").test_client()
    registered = _register(client, "老王").get_json()

    response = client.post("/api/v1/auth/login", json={
        "userId": registered["user"]["userId"], "token": registered["token"]})

    assert response.status_code == 200
    assert response.get_json()["token"] == registered["token"]


def test_login_prefers_credentials_over_nickname(tmp_path):
    """两者同时提供时，优先按凭据恢复（避免昵称意外覆盖身份）。"""
    client = create_app(tmp_path / "prefer.json").test_client()
    user_a = _register(client, "甲同学").get_json()
    user_b = _register(client, "乙同学").get_json()

    response = client.post("/api/v1/auth/login", json={
        "userId": user_a["user"]["userId"], "token": user_a["token"],
        "nickname": "乙同学"})

    assert response.status_code == 200
    assert response.get_json()["user"]["userId"] == user_a["user"]["userId"]


# --------------------------------------------------- 注册仍可用
def test_register_remains_idempotent_at_the_account_level_for_new_nicknames(tmp_path):
    """`/auth/register` 仍是有意允许建同昵称账号的原语（不做去重）。

    去重发生在 `login-or-register` / `login`。
    这样设计是为了不破坏既有测试与"确实想再建一个身份"的场景。
    """
    client = create_app(tmp_path / "rawregister.json").test_client()

    first = _register(client, "同昵称").get_json()
    second = _register(client, "同昵称").get_json()

    assert first["user"]["userId"] != second["user"]["userId"]


def test_login_or_register_response_shape_matches_contract(tmp_path):
    """响应形状必须与契约一致（含 created 字段）。"""
    client = create_app(tmp_path / "shape.json").test_client()

    body = client.post("/api/v1/auth/login-or-register",
                       json={"nickname": "形状检查", "phone": _phone()}).get_json()

    for field in ("user", "token", "expiresAt", "created"):
        assert field in body, f"缺少契约字段 {field}"
    for field in ("userId", "nickname"):
        assert field in body["user"], f"user 缺少 {field}"
    # 绝不能泄漏凭据字段
    assert "authSubject" not in body["user"]
