# -*- coding: utf-8 -*-
"""手机号注册与华为账号登录回归测试。

对应两条产品要求：
1. **注册必须带手机号** —— 手机号是唯一身份标识，昵称不是
2. **华为账号一键登录** —— 鸿蒙全场景最对口的能力：免注册、免验证码
"""

from app import create_app

H = {"X-API-Contract-Version": "api-contract-v0.3"}

_SEQ = {"n": 0}


def _phone() -> str:
    _SEQ["n"] += 1
    return f"1360000{_SEQ['n']:04d}"


#: 测试账号统一用的密码 —— 见 `test_auth_login.py` 同名常量的说明：
#: `_verify_password()` 现在会**拒绝**用密码登录"从未设过密码"的账号
#: （此前会静默放行，等于任意密码都能登进去），所以这些"登回同一账号"的
#: 用例需要账号确实有密码。断言意图不变。
_TEST_PASSWORD = "test-pw-123456"


# --------------------------------------------------------------------- 手机号注册
def test_register_requires_phone(tmp_path):
    client = create_app(tmp_path / "req-phone.json").test_client()

    missing = client.post("/api/v1/auth/register", json={"nickname": "无号同学"}, headers=H)
    assert missing.status_code == 400
    assert "手机号" in missing.get_json()["message"]


def test_register_rejects_malformed_phone(tmp_path):
    client = create_app(tmp_path / "bad-phone.json").test_client()

    for bad in ("12345", "23800000000", "1380000000", "abc", "12800000000"):
        response = client.post("/api/v1/auth/register",
                               json={"nickname": "错号", "phone": bad}, headers=H)
        assert response.status_code == 400, f"phone={bad!r} → {response.status_code}"


def test_register_accepts_common_phone_formats(tmp_path):
    """`+86 138-0000-0000` 这类写法要能归一后存库。"""
    client = create_app(tmp_path / "fmt-phone.json").test_client()
    phone = _phone()
    formatted = f"+86 {phone[:3]}-{phone[3:7]}-{phone[7:]}"

    created = client.post("/api/v1/auth/register",
                          json={"nickname": "格式", "phone": formatted,
                                "password": _TEST_PASSWORD}, headers=H)
    assert created.status_code == 201

    # 用干净格式应能登回
    logged = client.post("/api/v1/auth/login",
                         json={"phone": phone, "password": _TEST_PASSWORD}, headers=H)
    assert logged.status_code == 200
    assert logged.get_json()["user"]["userId"] == created.get_json()["user"]["userId"]


def test_register_rejects_duplicate_phone(tmp_path):
    """手机号唯一：同号重复注册 409，不悄悄建第二个账号。"""
    client = create_app(tmp_path / "dup.json").test_client()
    phone = _phone()
    assert client.post("/api/v1/auth/register",
                       json={"nickname": "第一个", "phone": phone},
                       headers=H).status_code == 201

    duplicate = client.post("/api/v1/auth/register",
                            json={"nickname": "第二个", "phone": phone}, headers=H)

    assert duplicate.status_code == 409
    assert duplicate.get_json()["errorCode"] == "CONFLICT"


def test_phone_is_persisted_normalized_and_masked(tmp_path):
    """落库的是归一化号码；回传的是脱敏号码。"""
    client = create_app(tmp_path / "mask.json").test_client()
    phone = _phone()

    body = client.post("/api/v1/auth/register",
                       json={"nickname": "脱敏", "phone": f"+86 {phone}"},
                       headers=H).get_json()

    user = body["user"]
    assert user["hasPhone"] is True
    assert user["phoneMasked"] == f"{phone[:3]}****{phone[-4:]}"
    assert phone not in str(body), "完整手机号不应出现在响应里"


# --------------------------------------------------------------------- 手机号登录
def test_login_by_phone_returns_same_account(tmp_path):
    client = create_app(tmp_path / "login-phone.json").test_client()
    phone = _phone()
    created = client.post("/api/v1/auth/register",
                          json={"nickname": "手机登录", "phone": phone,
                                "password": _TEST_PASSWORD},
                          headers=H).get_json()

    logged = client.post("/api/v1/auth/login",
                         json={"phone": phone, "password": _TEST_PASSWORD}, headers=H)

    assert logged.status_code == 200
    assert logged.get_json()["user"]["userId"] == created["user"]["userId"]


def test_login_by_unknown_phone_is_404(tmp_path):
    client = create_app(tmp_path / "unknown.json").test_client()

    response = client.post("/api/v1/auth/login", json={"phone": "13700000099"}, headers=H)

    assert response.status_code == 404


def test_login_or_register_prefers_phone_over_nickname(tmp_path):
    """改了昵称但手机号不变 → 仍是同一个人。手机号才是身份。"""
    client = create_app(tmp_path / "prefer.json").test_client()
    phone = _phone()

    first = client.post("/api/v1/auth/login-or-register",
                        json={"nickname": "原名", "phone": phone,
                              "password": _TEST_PASSWORD}, headers=H).get_json()
    renamed = client.post("/api/v1/auth/login-or-register",
                          json={"nickname": "改了个名", "phone": phone,
                                "password": _TEST_PASSWORD}, headers=H).get_json()

    assert renamed["created"] is False
    assert renamed["user"]["userId"] == first["user"]["userId"]


# --------------------------------------------------------------------- 华为账号登录
def test_huawei_first_login_creates_account(tmp_path):
    """首次华为登录应自动建号 —— 用户没填任何东西。"""
    client = create_app(tmp_path / "hw-new.json").test_client()

    response = client.post("/api/v1/auth/login-with-huawei",
                           json={"openId": "hw-open-aaa", "unionId": "hw-union-a",
                                 "nickname": "华友小明"}, headers=H)

    assert response.status_code == 201
    body = response.get_json()
    assert body["created"] is True
    assert body["user"]["authProvider"] == "agc_phone"
    assert body["user"]["nickname"] == "华友小明"


def test_huawei_repeat_login_reuses_account(tmp_path):
    """同一 OpenID 再次登录必须复用账号，不重复建号。"""
    client = create_app(tmp_path / "hw-repeat.json").test_client()

    first = client.post("/api/v1/auth/login-with-huawei",
                        json={"openId": "hw-open-bbb", "nickname": "首次"},
                        headers=H).get_json()
    second = client.post("/api/v1/auth/login-with-huawei",
                         json={"openId": "hw-open-bbb", "nickname": "改了名"},
                         headers=H).get_json()

    assert second["created"] is False
    assert second["user"]["userId"] == first["user"]["userId"]


def test_huawei_different_openid_creates_distinct_account(tmp_path):
    client = create_app(tmp_path / "hw-distinct.json").test_client()

    a = client.post("/api/v1/auth/login-with-huawei",
                    json={"openId": "hw-open-c1"}, headers=H).get_json()
    b = client.post("/api/v1/auth/login-with-huawei",
                    json={"openId": "hw-open-c2"}, headers=H).get_json()

    assert a["user"]["userId"] != b["user"]["userId"]


def test_huawei_without_openid_is_rejected(tmp_path):
    client = create_app(tmp_path / "hw-missing.json").test_client()

    response = client.post("/api/v1/auth/login-with-huawei", json={}, headers=H)

    assert response.status_code == 400
    assert "OpenID" in response.get_json()["message"]


def test_huawei_generates_placeholder_nickname_when_absent(tmp_path):
    """客户端没给昵称时要生成占位昵称，不能是空串（否则画像页会留白）。"""
    client = create_app(tmp_path / "hw-noname.json").test_client()

    body = client.post("/api/v1/auth/login-with-huawei",
                       json={"openId": "hw-open-ddd999"}, headers=H).get_json()

    assert body["user"]["nickname"].strip(), "昵称不能为空"
    assert body["user"]["authProvider"] == "agc_phone"


def test_huawei_account_never_leaks_openid(tmp_path):
    """OpenID 是凭据，绝不能出现在对外响应里。"""
    client = create_app(tmp_path / "hw-leak.json").test_client()
    open_id = "hw-open-secret-xyz"

    body = client.post("/api/v1/auth/login-with-huawei",
                       json={"openId": open_id}, headers=H).get_json()

    assert open_id not in str(body), "authSubject/OpenID 不应回传"
    assert "authSubject" not in body["user"]


def test_huawei_response_shape_matches_contract(tmp_path):
    client = create_app(tmp_path / "hw-shape.json").test_client()

    body = client.post("/api/v1/auth/login-with-huawei",
                       json={"openId": "hw-open-shape"}, headers=H).get_json()

    for field in ("user", "token", "expiresAt", "created"):
        assert field in body, f"缺少契约字段 {field}"
    for field in ("userId", "nickname"):
        assert field in body["user"], f"user 缺少 {field}"


def test_huawei_login_token_works_for_me(tmp_path):
    """华为登录拿到的 token 必须能正常访问受保护接口。"""
    client = create_app(tmp_path / "hw-token.json").test_client()
    token = client.post("/api/v1/auth/login-with-huawei",
                        json={"openId": "hw-open-token1"}, headers=H).get_json()["token"]

    me = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})

    assert me.status_code == 200
    assert me.get_json()["user"]["authProvider"] == "agc_phone"
