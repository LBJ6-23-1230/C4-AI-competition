# -*- coding: utf-8 -*-
"""鉴权层回归测试（`app/auth/service.py` + `/api/v1/auth/*`）。

三条最重要的断言（也是本次加入登录功能最大的风险点）：

1. **演示主链不能受登录功能影响** —— 不带 token 时，`demo/reset` 与整条主链
   必须与加入登录前逐字一致（mastery 42 / Plan V1 [30,30] / √√× → 66.67 → 58）。
2. **鉴权是可选的，不是门禁** —— 无效 token 必须降级为游客身份，而不是 401。
3. **token / auth_subject 绝不出现在任何对外响应里**。
"""

import pytest

from app import create_app
from app.auth import service as auth

DEMO_ANSWERS = [
    {"exerciseId": "exercise-preorder-001", "answer": "A"},
    {"exerciseId": "exercise-inorder-001", "answer": "B"},
    {"exerciseId": "exercise-postorder-001", "answer": "A"},
]


@pytest.fixture
def client(tmp_path):
    return create_app(tmp_path / "auth.json").test_client()


# --------------------------------------------------------------------------- 测试辅助
_PHONE_SEQ = {"n": 0}


def _phone() -> str:
    """生成唯一且合法的测试手机号。

    手机号现在**必填且唯一**（`service._PHONE_REQUIRED = True`），
    所以每次注册都要给一个新号，否则第二个测试会撞唯一约束。
    """
    _PHONE_SEQ["n"] += 1
    return f"1380000{_PHONE_SEQ['n']:04d}"


def _register(client, nickname="小明", grade="大二", phone=None):
    response = client.post("/api/v1/auth/register",
                           json={"nickname": nickname, "grade": grade,
                                 "phone": phone or _phone()})
    assert response.status_code == 201
    return response.get_json()


def _auth_header(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# --------------------------------------------------------------------------- 注册 / 登录
def test_register_returns_user_and_token(client):
    body = _register(client)

    assert body["user"]["nickname"] == "小明"
    assert body["user"]["grade"] == "大二"
    assert body["user"]["userId"].startswith("u-")
    assert len(body["token"]) > 20
    assert body["expiresAt"]


def test_register_never_leaks_token_or_subject(client):
    body = _register(client)

    assert "token" not in body["user"]
    assert "authSubject" not in body["user"]


def test_register_rejects_blank_and_overlong_nickname(client):
    # 都带上合法手机号，确保失败原因**确实来自昵称**而不是"缺手机号"
    assert client.post("/api/v1/auth/register",
                       json={"nickname": "   ", "phone": _phone()}).status_code == 400
    assert client.post("/api/v1/auth/register",
                       json={"nickname": "x" * 17, "phone": _phone()}).status_code == 400
    assert client.post("/api/v1/auth/register", json={}).status_code == 400


def test_register_rejects_unknown_grade(client):
    response = client.post("/api/v1/auth/register",
                           json={"nickname": "小明", "grade": "博后", "phone": _phone()})

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "VALIDATION_ERROR"


def test_register_is_case_and_whitespace_tolerant(client):
    body = _register(client, nickname="  小红  ")

    assert body["user"]["nickname"] == "小红"


def test_login_restores_session_with_saved_credentials(client):
    registered = _register(client)

    response = client.post("/api/v1/auth/login", json={
        "userId": registered["user"]["userId"], "token": registered["token"]})

    assert response.status_code == 200
    assert response.get_json()["user"]["userId"] == registered["user"]["userId"]


def test_login_rejects_mismatched_or_unknown_credentials(client):
    registered = _register(client)
    other = _register(client, nickname="小红")

    assert client.post("/api/v1/auth/login", json={
        "userId": registered["user"]["userId"], "token": other["token"]}).status_code == 401
    assert client.post("/api/v1/auth/login", json={
        "userId": "u-does-not-exist", "token": registered["token"]}).status_code == 401
    assert client.post("/api/v1/auth/login", json={"userId": "", "token": ""}).status_code == 400


# --------------------------------------------------------------------------- me / logout
def test_me_requires_bearer_token(client):
    assert client.get("/api/v1/auth/me").status_code == 401
    assert client.get("/api/v1/auth/me",
                      headers={"Authorization": "Basic abc"}).status_code == 401
    assert client.get("/api/v1/auth/me",
                      headers=_auth_header("not-a-real-token")).status_code == 401


def test_me_returns_current_user(client):
    registered = _register(client)

    response = client.get("/api/v1/auth/me", headers=_auth_header(registered["token"]))

    assert response.status_code == 200
    assert response.get_json()["user"]["nickname"] == "小明"


def test_logout_revokes_only_current_token(client):
    registered = _register(client)
    token = registered["token"]

    assert client.post("/api/v1/auth/logout", headers=_auth_header(token)).status_code == 200
    assert client.get("/api/v1/auth/me", headers=_auth_header(token)).status_code == 401
    # 吊销后不能再登录
    assert client.post("/api/v1/auth/login", json={
        "userId": registered["user"]["userId"], "token": token}).status_code == 401


def test_delete_account_deactivates_and_blocks_relogin(client):
    registered = _register(client)
    token = registered["token"]
    user_id = registered["user"]["userId"]

    response = client.delete("/api/v1/auth/account", headers=_auth_header(token))

    assert response.status_code == 200
    assert response.get_json()["status"] == "deactivated"
    assert client.get("/api/v1/auth/me", headers=_auth_header(token)).status_code == 401
    assert client.post("/api/v1/auth/login",
                       json={"userId": user_id, "token": token}).status_code == 401


# --------------------------------------------------------------------------- 新账号画像
def test_new_account_gets_usable_starter_profile(client):
    """新账号必须立刻能读到画像与计划，否则登录后首页会报 404。"""
    registered = _register(client)
    user_id = registered["user"]["userId"]

    profile = client.get(f"/api/v1/profile/{user_id}").get_json()
    assert profile["profileVersion"] == 1
    assert profile["mastery"][0]["masteryScore"] == 0
    assert profile["history"] == []

    plan = client.get("/api/v1/plans/current").get_json()
    assert plan["version"] == 1
    assert len(plan["tasks"]) >= 1


def test_new_account_mastery_grows_through_real_submission(client):
    """登录功能的价值证明：真实账号走完「练习 → 判分 → 掌握度提升」闭环。"""
    registered = _register(client)
    user_id = registered["user"]["userId"]
    headers = _auth_header(registered["token"])

    response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                           json={"idempotencyKey": "new-user-1", "userId": user_id,
                                 "answers": DEMO_ANSWERS}, headers=headers)

    assert response.status_code == 200
    assessment = response.get_json()["assessment"]
    assert assessment["score"] == 66.67
    assert assessment["oldMastery"] == 0
    assert assessment["suggestedNewMastery"] == 16  # 0 + 16（score >= 60 档）
    assert response.get_json()["needReplan"] is True


# --------------------------------------------------------------------------- 演示主链护栏
def test_demo_baseline_is_unaffected_by_auth_feature(client):
    """★ 最重要的一条：不带 token 时演示基线必须逐项不变。"""
    reset = client.post("/api/v1/demo/reset").get_json()
    assert reset["userId"] == auth.DEMO_USER_ID
    assert reset["profile"]["mastery"][0]["masteryScore"] == 42
    assert [t["durationMinutes"] for t in reset["plan"]["tasks"]] == [30, 30]

    submit = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                         json={"idempotencyKey": "guard-demo", "answers": DEMO_ANSWERS}).get_json()
    assert submit["assessment"]["score"] == 66.67
    assert submit["assessment"]["suggestedNewMastery"] == 58
    assert submit["needReplan"] is True

    profile = client.get("/api/v1/profile/demo-user").get_json()
    assert profile["profileVersion"] == 2
    assert [t["durationMinutes"]
            for t in client.get("/api/v1/plans/current").get_json()["tasks"]] == [45, 15]


def test_invalid_bearer_degrades_to_guest_instead_of_blocking(client):
    """无效 token 不能让整个 App 不可用——降级为游客身份。"""
    response = client.get("/api/v1/profile/demo-user",
                          headers=_auth_header("expired-or-garbage"))

    assert response.status_code == 200
    assert response.get_json()["profile"]["userId"] == auth.DEMO_USER_ID


def test_valid_bearer_does_not_change_demo_endpoints(client):
    """带上登录 token 访问 demo-user 的接口，结果必须与游客一致（演示不受影响）。"""
    registered = _register(client)
    headers = _auth_header(registered["token"])

    assert client.post("/api/v1/demo/reset", headers=headers).status_code == 200
    with_token = client.get("/api/v1/profile/demo-user", headers=headers).get_json()
    without = client.get("/api/v1/profile/demo-user").get_json()

    assert with_token == without


def test_auth_endpoints_require_contract_version_header_to_match(client):
    """契约头校验对 auth 接口同样生效（复用 /api/v1 规则）。"""
    response = client.post("/api/v1/auth/register",
                           json={"nickname": "小明", "phone": _phone()},
                           headers={"X-API-Contract-Version": "api-contract-v0.2"})

    assert response.status_code == 409
    assert response.get_json()["errorCode"] == "CONTRACT_VERSION_MISMATCH"


# --------------------------------------------------------------------------- 领域层单测
def test_parse_bearer_formats():
    assert auth.parse_bearer("Bearer abc123") == "abc123"
    assert auth.parse_bearer("bearer abc123") == "abc123"
    assert auth.parse_bearer("  Bearer   abc123  ") == "abc123"
    assert auth.parse_bearer("Basic abc123") == ""
    assert auth.parse_bearer("") == ""
    assert auth.parse_bearer(None) == ""


def test_normalize_nickname_trims_and_validates():
    assert auth.normalize_nickname("  小明 ") == "小明"
    with pytest.raises(auth.AuthError):
        auth.normalize_nickname("")
    with pytest.raises(auth.AuthError):
        auth.normalize_nickname("a\nb")
    with pytest.raises(auth.AuthError):
        auth.normalize_nickname(None)


def test_session_expiry_is_enforced(tmp_path):
    from app.repositories.json_repository import JsonRepository

    repository = JsonRepository(tmp_path / "repo.json")
    outcome = auth.register_user(repository, "小明", phone=_phone())
    session = repository.get(auth.SESSIONS, outcome["token"])

    session["expiresAt"] = "2020-01-01T00:00:00+00:00"
    repository.save(auth.SESSIONS, outcome["token"], session)

    assert auth.resolve_session(repository, outcome["token"]) is None
    # 过期会话应被顺手清理
    assert repository.get(auth.SESSIONS, outcome["token"]) is None
