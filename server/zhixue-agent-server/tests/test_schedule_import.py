# -*- coding: utf-8 -*-

import base64

from app import create_app
from app.agent import chat_llm

H = {"X-API-Contract-Version": "api-contract-v0.3"}


def test_schedule_image_requires_configured_model(tmp_path, monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    client = create_app(tmp_path / "schedule-no-key.json").test_client()
    response = client.post("/api/v1/import/schedule-image", json={
        "imageBase64": base64.b64encode(b"\x89PNG\r\n\x1a\nimage").decode("ascii")
    }, headers=H)
    assert response.status_code == 503
    assert response.get_json()["errorCode"] == "LLM_NOT_CONFIGURED"


def test_schedule_image_returns_normalized_courses(tmp_path, monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")
    monkeypatch.setattr(chat_llm, "_call_llm_with_image", lambda *args, **kwargs: (
        '{"courses":['
        '{"courseName":"数据结构","examDate":"2026-10-20","priority":"高",'
        '"studyHours":2,"status":"近期复习不足"},'
        '{"courseName":"操作系统","examDate":"","priority":"未知"}'
        ']}'
    ))
    client = create_app(tmp_path / "schedule.json").test_client()
    response = client.post("/api/v1/import/schedule-image", json={
        "imageBase64": base64.b64encode(b"\xff\xd8\xffimage").decode("ascii")
    }, headers=H)
    assert response.status_code == 200
    body = response.get_json()
    assert body["recognizedCount"] == 2
    assert body["courses"][0]["courseName"] == "数据结构"
    assert body["courses"][0]["exam"]["date"] == "2026-10-20"
    assert body["courses"][1]["priority"] == "中"
    assert body["courses"][1]["exam"]["date"] == "未设置"


def test_schedule_image_rejects_invalid_base64(tmp_path, monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "test-key")
    client = create_app(tmp_path / "schedule-invalid.json").test_client()
    response = client.post("/api/v1/import/schedule-image",
                           json={"imageBase64": "not-base64!!!"}, headers=H)
    assert response.status_code == 400
