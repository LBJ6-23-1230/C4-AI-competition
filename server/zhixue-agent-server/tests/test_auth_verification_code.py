# -*- coding: utf-8 -*-
"""手机号验证码接口就绪版的回归测试。"""

from datetime import datetime, timedelta, timezone

from app import create_app
from app.auth import service
from app.repositories.json_repository import JsonRepository


_PHONE_SEQ = {"n": 0}


def _phone() -> str:
    _PHONE_SEQ["n"] += 1
    return f"1350000{_PHONE_SEQ['n']:04d}"


def _client(tmp_path, name: str):
    path = tmp_path / name
    client = create_app(path).test_client()
    return client, path


def _send(client, phone: str):
    return client.post("/api/v1/auth/send-code", json={"phone": phone})


def test_send_code_returns_dev_code_but_only_persists_hash(tmp_path):
    client, path = _client(tmp_path, "send-code.json")
    phone = _phone()

    response = _send(client, phone)
    body = response.get_json()

    assert response.status_code == 200
    assert body["phoneMasked"] == f"{phone[:3]}****{phone[-4:]}"
    assert body["smsDelivered"] is False
    assert body["expiresInSeconds"] == service.VERIFICATION_CODE_TTL_SECONDS
    assert body["resendAfterSeconds"] == service.VERIFICATION_RESEND_SECONDS
    assert len(body["devCode"]) == 6 and body["devCode"].isdigit()

    record = JsonRepository(path).get(service.VERIFICATION_CODES, phone)
    assert record is not None
    assert record["codeHash"] != body["devCode"]
    assert record["codeHash"] == service._verification_hash(
        body["devCode"], record["salt"])
    assert "devCode" not in record


def test_verify_code_auto_registers_and_is_single_use(tmp_path):
    client, _path = _client(tmp_path, "verify-new.json")
    phone = _phone()
    code = _send(client, phone).get_json()["devCode"]

    response = client.post("/api/v1/auth/verify-code", json={
        "phone": phone,
        "code": code,
        "nickname": "验证码新用户",
        "grade": "大二",
    })
    body = response.get_json()

    assert response.status_code == 201
    assert body["created"] is True
    assert body["user"]["nickname"] == "验证码新用户"
    assert body["user"]["phoneMasked"] == f"{phone[:3]}****{phone[-4:]}"
    assert phone not in str(body)

    profile = client.get(
        f"/api/v1/profile/{body['user']['userId']}",
        headers={"Authorization": f"Bearer {body['token']}"},
    )
    assert profile.status_code == 200
    assert profile.get_json()["mastery"][0]["masteryScore"] == 0

    replay = client.post("/api/v1/auth/verify-code", json={
        "phone": phone,
        "code": code,
    })
    assert replay.status_code == 400
    assert replay.get_json()["errorCode"] == "CODE_NOT_FOUND"


def test_verify_code_logs_existing_phone_into_same_account(tmp_path):
    client, _path = _client(tmp_path, "verify-existing.json")
    phone = _phone()
    registered = client.post("/api/v1/auth/register", json={
        "nickname": "已有用户",
        "phone": phone,
    }).get_json()
    code = _send(client, phone).get_json()["devCode"]

    response = client.post("/api/v1/auth/verify-code", json={
        "phone": phone,
        "code": code,
    })

    assert response.status_code == 200
    assert response.get_json()["created"] is False
    assert response.get_json()["user"]["userId"] == registered["user"]["userId"]


def test_send_code_enforces_sixty_second_resend_limit(tmp_path):
    client, _path = _client(tmp_path, "resend-limit.json")
    phone = _phone()
    assert _send(client, phone).status_code == 200

    response = _send(client, phone)

    assert response.status_code == 429
    assert response.get_json()["errorCode"] == "RATE_LIMITED"
    assert 1 <= response.get_json()["details"]["retryAfterSeconds"] <= 60


def test_send_code_enforces_daily_limit(tmp_path, monkeypatch):
    client, path = _client(tmp_path, "daily-limit.json")
    phone = _phone()
    clock = {"now": datetime(2026, 9, 20, tzinfo=timezone.utc)}
    monkeypatch.setattr(service, "_now", lambda: clock["now"])

    for index in range(service.VERIFICATION_DAILY_LIMIT):
        clock["now"] = (
            datetime(2026, 9, 20, tzinfo=timezone.utc)
            + timedelta(seconds=(service.VERIFICATION_RESEND_SECONDS + 1) * index)
        )
        assert _send(client, phone).status_code == 200

    clock["now"] += timedelta(seconds=service.VERIFICATION_RESEND_SECONDS + 1)
    response = _send(client, phone)

    assert response.status_code == 429
    assert response.get_json()["errorCode"] == "DAILY_LIMIT_REACHED"
    assert response.get_json()["details"]["limit"] == service.VERIFICATION_DAILY_LIMIT


def test_verify_code_locks_phone_after_five_wrong_attempts(tmp_path):
    client, _path = _client(tmp_path, "lockout.json")
    phone = _phone()
    code = _send(client, phone).get_json()["devCode"]
    wrong_code = "000000" if code != "000000" else "111111"

    for attempt in range(4):
        response = client.post("/api/v1/auth/verify-code", json={
            "phone": phone, "code": wrong_code})
        assert response.status_code == 400
        assert response.get_json()["errorCode"] == "INVALID_CODE"
        assert response.get_json()["details"]["remainingAttempts"] == 4 - attempt

    locked = client.post("/api/v1/auth/verify-code", json={
        "phone": phone, "code": wrong_code})
    assert locked.status_code == 429
    assert locked.get_json()["errorCode"] == "PHONE_LOCKED"

    correct_but_locked = client.post("/api/v1/auth/verify-code", json={
        "phone": phone, "code": code})
    assert correct_but_locked.status_code == 429
    assert correct_but_locked.get_json()["errorCode"] == "PHONE_LOCKED"


def test_verify_code_expires_and_clears_secret(tmp_path, monkeypatch):
    client, path = _client(tmp_path, "expired.json")
    phone = _phone()
    clock = {"now": datetime(2026, 9, 20, tzinfo=timezone.utc)}
    monkeypatch.setattr(service, "_now", lambda: clock["now"])
    code = _send(client, phone).get_json()["devCode"]
    clock["now"] += timedelta(seconds=service.VERIFICATION_CODE_TTL_SECONDS + 1)

    response = client.post("/api/v1/auth/verify-code", json={
        "phone": phone, "code": code})

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "CODE_EXPIRED"
    stored = JsonRepository(path).get(service.VERIFICATION_CODES, phone)
    assert stored["codeHash"] == ""
    assert stored["salt"] == ""


def test_send_code_validates_phone_and_production_never_leaks_dev_code(
        tmp_path, monkeypatch):
    client, _path = _client(tmp_path, "production.json")

    malformed = _send(client, "12345")
    assert malformed.status_code == 400
    assert malformed.get_json()["errorCode"] == "VALIDATION_ERROR"

    monkeypatch.delenv("SMS_PROVIDER", raising=False)
    monkeypatch.setenv("ZHIXUE_ENV", "production")
    response = _send(client, _phone())

    assert response.status_code == 503
    assert response.get_json()["errorCode"] == "SMS_NOT_CONFIGURED"
    assert "devCode" not in response.get_json()
