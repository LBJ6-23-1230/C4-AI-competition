# -*- coding: utf-8 -*-
"""联调合并层（`app/agent/chat_llm.py` + `/api/agent/*`）的回归测试。

覆盖三件事：
1. 未配置 LLM 时意图识别必须退回关键词匹配，且**不得**伪装成大模型输出；
2. 聊天响应结构冻结为 `{reply, intent, card}`，卡片 targetPage 必须落在前端安全页白名单内；
3. 双向边界：`/api/agent/*`（自然语言层）与 `/api/v1/**`（结构化工作流层）由同一进程提供，
   且 `/api/agent/health` 不做契约版本校验（否则前端会误判后端不可用）。
"""

import pytest
from types import SimpleNamespace

from app import create_app
from app.agent import chat_llm


_PNG_16X16 = (
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGO4"
    "o6FBEmIY1TCqYfhqAAAyBCwQhvh37QAAAABJRU5ErkJggg==")


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
        assert set(card) == {"type", "title", "actionLabel", "targetPage"}
        assert card["targetPage"] in declared, (message, card["targetPage"])


# --------------------------------------------------------------------------- 不伪装
def test_reply_is_labelled_as_local_rule_when_llm_is_absent(client):
    body = client.post("/api/agent/chat", json={"message": "今天我应该先学什么？"}).get_json()

    # 契约基线三字段 + 可选的 llmUsed（前端据它显示"本地规则兜底"标签）
    assert set(body) == {"reply", "intent", "card", "llmUsed"}
    assert body["intent"] == "get_suggestion"
    assert body["llmUsed"] is False, "未配置 Key 时必须如实标注非大模型输出"
    assert "DASHSCOPE_API_KEY" in body["reply"], "未配置 Key 时必须显式声明是本地规则兜底"


def test_image_without_llm_does_not_claim_multimodal_recognition(client):
    body = client.post("/api/agent/chat",
                       json={"image": "ZmFrZS1pbWFnZQ=="}).get_json()

    assert body["intent"] == "analyze_wrong"
    assert "未接入多模态识别" in body["reply"]


# --------------------------------------------------------------- 多模态通路可达性
def test_image_routes_to_multimodal_handler_when_llm_ready(monkeypatch):
    """带图片时必须走 Qwen-VL 多模态分支。

    回归背景：`detect_intent()` 原先只看文本，而"只有图片没有文字"时
    API 层会把消息替换为「帮我分析这道题」，关键词表里没有这个词，
    于是意图落到 get_suggestion，`_call_llm_with_image()` **永远不会被执行**——
    多模态识图功能形同虚设。修复后 has_image=True 直接判定 analyze_wrong。
    """
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured")

    calls: list[dict] = []

    def _fake_with_image(system_prompt, user_prompt, image_base64):
        calls.append({"image": image_base64, "user_prompt": user_prompt})
        return "已识别：二叉树后序遍历"

    monkeypatch.setattr(chat_llm, "_call_llm_with_image", _fake_with_image)

    result = chat_llm.chat("帮我分析这道题", image_base64="ZmFrZS1pbWFnZQ==")

    assert result["intent"] == "analyze_wrong"
    assert result["llmUsed"] is True
    assert calls, "必须真的调用多模态接口"
    assert calls[0]["image"] == "ZmFrZS1pbWFnZQ=="
    assert result["reply"] == "已识别：二叉树后序遍历"


def test_detect_intent_short_circuits_on_image():
    """带图时不应浪费一次文本意图识别调用。"""
    intent, used = chat_llm.detect_intent("随便说点什么", has_image=True)
    assert intent == "analyze_wrong"
    assert used is True


def test_detect_intent_without_image_still_uses_text_rules():
    """不带图时，文本意图识别行为不变（不能因为修多模态而改坏纯文本）。"""
    assert chat_llm.detect_intent("帮我找学习搭子")[0] == "match_partner"
    assert chat_llm.detect_intent("今天先学什么")[0] == "get_suggestion"


def test_multimodal_uses_configured_model_and_detects_png(monkeypatch):
    monkeypatch.setenv("LLM_MODEL", "qwen3.8-flash")
    monkeypatch.setenv("LLM_VL_MODEL", "qwen3-vl-plus")
    captured: dict = {}

    class _Completions:
        def create(self, **kwargs):
            captured.update(kwargs)
            return SimpleNamespace(
                choices=[SimpleNamespace(
                    message=SimpleNamespace(content="图片分析完成"))])

    client = SimpleNamespace(
        chat=SimpleNamespace(completions=_Completions()))
    monkeypatch.setattr(chat_llm, "_client", lambda: client)

    result = chat_llm._call_llm_with_image("system", "user", _PNG_16X16)

    assert result == "图片分析完成"
    assert captured["model"] == "qwen3-vl-plus"
    image_url = captured["messages"][1]["content"][0]["image_url"]["url"]
    assert image_url.startswith("data:image/png;base64,")


def test_llm_failure_degrades_honestly(monkeypatch, client):
    """Key 已配置但调用失败时，必须说明降级，而不是返回静默兜底。"""
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured-but-unreachable")

    def _boom(*_args, **_kwargs):
        raise RuntimeError("simulated transport failure")

    monkeypatch.setattr(chat_llm, "_call_llm", _boom)

    body = client.post("/api/agent/chat", json={"message": "今天我应该先学什么？"}).get_json()

    assert body["intent"] == "get_suggestion"
    assert "本地确定性规则" in body["reply"] or "本地规则" in body["reply"]


def test_chat_result_marks_failed_llm_as_unused(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured-but-unreachable")

    def _boom(*_args, **_kwargs):
        raise RuntimeError("simulated transport failure")

    monkeypatch.setattr(chat_llm, "_call_llm", _boom)

    result = chat_llm.chat("今天我应该先学什么？")

    assert result["llmUsed"] is False
    assert "本次大模型调用失败" in result["reply"]


def test_chat_result_marks_successful_llm_as_used(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured")

    def _fake_call(system_prompt, user_prompt, **_kwargs):
        if user_prompt.startswith("现在请分析用户输入"):
            return '{"intent":"get_suggestion"}'
        return "这是大模型生成的学习建议"

    monkeypatch.setattr(chat_llm, "_call_llm", _fake_call)

    result = chat_llm.chat("今天我应该先学什么？")

    assert result["llmUsed"] is True
    assert result["reply"] == "这是大模型生成的学习建议"


# --------------------------------------------------------------------------- 协议与边界
def test_empty_payload_keeps_legacy_response_shape(client):
    body = client.post("/api/agent/chat", json={}).get_json()

    assert body == {"reply": "请告诉我你需要什么帮助？", "intent": "unknown",
                    "card": None, "llmUsed": False}


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
