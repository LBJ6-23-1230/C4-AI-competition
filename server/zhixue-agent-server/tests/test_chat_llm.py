# -*- coding: utf-8 -*-
"""联调合并层（`app/agent/chat_llm.py` + `/api/agent/*`）的回归测试。

覆盖三件事：
1. 未配置 LLM 时意图识别必须退回关键词匹配，且**不得**伪装成大模型输出；
2. 聊天响应结构冻结为 `{reply, intent, card}`，卡片 targetPage 必须落在前端安全页白名单内；
3. 双向边界：`/api/agent/*`（自然语言层）与 `/api/v1/**`（结构化工作流层）由同一进程提供，
   且 `/api/agent/health` 不做契约版本校验（否则前端会误判后端不可用）。
"""

import pytest

from app import create_app
from app.agent import chat_llm


@pytest.fixture(autouse=True)
def _no_llm(monkeypatch):
    """默认在"无 Key"环境下测试，保证结果确定可复现。"""
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)


@pytest.fixture
def client(tmp_path):
    return create_app(tmp_path / "chat-llm.json").test_client()


# --------------------------------------------------------------------------- 意图与卡片
@pytest.mark.parametrize("message,expected", [
    ("我想查查错题", "analyze_wrong"),
    ("帮我匹配一个搭子", "match_partner"),
    ("这周的任务有哪些", "query_tasks"),
    ("我哪里薄弱", "analyze_weakness"),
    ("我掌握了二叉树遍历", "update_profile"),
    ("今天应该先学什么", "get_suggestion"),
    ("随便聊聊", "get_suggestion"),
])
def test_keyword_intent_fallback_is_deterministic(message, expected):
    assert chat_llm.keyword_intent(message) == expected


def test_card_target_page_is_always_a_declared_page(client):
    """卡片跳转页必须是前端 main_pages.json 里真实存在的页面。"""
    declared = {
        "pages/ChatMain", "pages/CourseImport", "pages/Index", "pages/StudySuggestion",
        "pages/WrongQuestion", "pages/StudyTags", "pages/ExercisePractice", "pages/ApiEnvironment",
        "pages/AgentTrace", "pages/PartnerMatch", "pages/StudyPlan", "pages/ReviewSummary",
        "pages/FocusSetup", "pages/FocusTimer", "pages/FocusResult", "pages/LearningHistory",
    }
    for message in ("查错题", "找搭子", "看任务", "看薄弱点", "给建议"):
        card = client.post("/api/agent/chat", json={"message": message}).get_json()["card"]
        assert card is not None, message
        assert card["targetPage"] in declared, (message, card["targetPage"])


# --------------------------------------------------------------------------- 不伪装
def test_reply_is_labelled_as_local_rule_when_llm_is_absent(client):
    body = client.post("/api/agent/chat", json={"message": "今天我应该先学什么？"}).get_json()

    assert set(body) == {"reply", "intent", "card"}
    assert body["intent"] == "get_suggestion"
    assert "DASHSCOPE_API_KEY" in body["reply"], "未配置 Key 时必须显式声明是本地规则兜底"


def test_image_without_llm_does_not_claim_multimodal_recognition(client):
    body = client.post("/api/agent/chat",
                       json={"image": "ZmFrZS1pbWFnZQ=="}).get_json()

    assert body["intent"] == "analyze_wrong"
    assert "未接入多模态识别" in body["reply"]


def test_llm_failure_degrades_honestly(monkeypatch, client):
    """Key 已配置但调用失败时，必须说明降级，而不是返回静默兜底。"""
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured-but-unreachable")

    def _boom(*_args, **_kwargs):
        raise RuntimeError("simulated transport failure")

    monkeypatch.setattr(chat_llm, "_call_llm", _boom)

    body = client.post("/api/agent/chat", json={"message": "今天我应该先学什么？"}).get_json()

    assert body["intent"] == "get_suggestion"
    assert "本地确定性规则" in body["reply"] or "本地规则" in body["reply"]


# --------------------------------------------------------------------------- 协议与边界
def test_empty_payload_keeps_legacy_response_shape(client):
    body = client.post("/api/agent/chat", json={}).get_json()

    assert body == {"reply": "请告诉我你需要什么帮助？", "intent": "unknown", "card": None}


def test_session_id_is_only_echoed_when_client_supplies_one(client):
    without = client.post("/api/agent/chat", json={"message": "看任务"}).get_json()
    with_id = client.post("/api/agent/chat",
                          json={"message": "看任务", "sessionId": "chat-abc"}).get_json()

    assert "sessionId" not in without
    assert with_id["sessionId"] == "chat-abc"


def test_history_endpoint_records_and_clears_conversation(client):
    client.delete("/api/agent/history")
    client.post("/api/agent/chat", json={"message": "帮我看看错题"})

    history = client.get("/api/agent/history").get_json()["history"]
    assert len(history) == 1
    assert history[0]["user_input"] == "帮我看看错题"

    client.delete("/api/agent/history")
    assert client.get("/api/agent/history").get_json()["history"] == []


def test_health_probe_ignores_contract_version(client):
    """前端连通性探针不能因为契约版本头缺失/不匹配而误报后端不可用。"""
    response = client.get("/api/agent/health",
                          headers={"X-API-Contract-Version": "api-contract-v0.1"})

    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_chat_rejects_wrong_contract_version(client):
    response = client.post("/api/agent/chat", json={"message": "看任务"},
                           headers={"X-API-Contract-Version": "api-contract-v0.2"})

    assert response.status_code == 409
    assert response.get_json()["errorCode"] == "CONTRACT_VERSION_MISMATCH"


def test_single_process_serves_both_layers(client):
    """联调收敛的核心断言：聊天层与结构化工作流层必须同源可用。"""
    assert client.get("/api/agent/health").status_code == 200
    assert client.post("/api/agent/chat", json={"message": "看任务"}).status_code == 200
    assert client.post("/api/v1/demo/reset").status_code == 200
    assert client.get("/api/v1/plans/current").status_code == 200
    assert client.get("/api/v1/exercises/set-demo-binary-tree-001").status_code == 200
