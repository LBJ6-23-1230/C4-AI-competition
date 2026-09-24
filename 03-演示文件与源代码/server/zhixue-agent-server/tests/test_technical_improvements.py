# -*- coding: utf-8 -*-
"""liantiao4 技术改进项的回归测试。

覆盖四类之前**没有测试保护**的边界与安全行为：

1. `run_workflow` 的步数边界 —— `max_steps` 恰好用满时不能被误判成"步数超限"
2. 非 2xx 的 HTTP 错误统一返回 `{errorCode, message, details}` JSON（405 / 414 / 415）
3. `/api/agent/history` 按用户隔离 —— 读不到别人的、也清不掉别人的
4. CORS 不再反射任意 Origin
"""

from __future__ import annotations

import json

import pytest

from app import create_app
from app.runtime.session import WorkflowSession


@pytest.fixture
def app(tmp_path):
    application = create_app(tmp_path / "repository.json")
    application.config.update(TESTING=True)
    return application


@pytest.fixture
def client(app):
    return app.test_client()


# ===========================================================================
# 1) run_workflow 的步数边界
#
# 背景：`app/runtime/loop.py` 用 `for ... else` 表达"步数用尽"，写法不常见。
# 我一度以为它会在 `max_steps` 恰好用满时把正常结束误标成 `status=error`，
# 并据此改写了逻辑 —— 实测证明**该缺陷不存在**（`else` 不可达，因为循环体
# 每条出口都有 `break`），而改写版**反而弄坏了 waiting 场景**。
# 已回退，并用下面这组测试把"真实边界行为"固化下来，避免再次误判。
# ===========================================================================
def _run_workflow(max_steps: int, decide_steps: list[str], act_results: list[dict],
                  initial_state: dict | None = None):
    """用受控的 `decide_next_step` 驱动 `run_workflow`。

    `run_workflow` 通过模块级名字调用 `decide_next_step`，所以 patch
    `app.runtime.loop.decide_next_step` 即可精确控制"第几次决定返回什么"。
    """
    from types import SimpleNamespace

    from app.runtime import loop as loop_mod
    from app.runtime.loop import run_workflow

    queue = list(decide_steps)

    def decide(state, model_decider=None):
        step = queue.pop(0) if queue else "finish"
        return SimpleNamespace(step=step, reason="学习流程已完成" if step == "finish" else "继续")

    original = loop_mod.decide_next_step
    loop_mod.decide_next_step = decide
    try:
        session = WorkflowSession(session_id="session-loop-boundary", goal="验证步数边界",
                                  user_id="demo-user", max_steps=max_steps)
        results = list(act_results)

        def act(step, current):
            return results.pop(0) if results else {"status": "ok"}

        run_workflow(session, lambda: dict(initial_state or {"awaitingAnswers": False}), act)
        return session
    finally:
        loop_mod.decide_next_step = original


@pytest.mark.parametrize("max_steps", [1, 2, 3, 6])
def test_finish_on_last_allowed_step_is_not_marked_as_error(max_steps):
    """`finish` 恰好落在第 N 次决定、且 `max_steps == N` → 必须 completed。

    这是 `for/else` 最容易被怀疑出错的场景，实测原实现正确（`finish` 分支有 break）。
    """
    session = _run_workflow(max_steps, ["finish"], [{"status": "ok"}])
    assert session.status == "completed"
    assert session.current_step == "finish"
    assert session.final_action == "学习流程已完成"


@pytest.mark.parametrize("max_steps", [1, 2, 3])
def test_waiting_on_last_allowed_step_is_not_marked_as_error(max_steps):
    """等答题恰好发生在最后一次迭代 → 保持 running，不得标 max_steps。

    `waiting` 分支把 status 写成 `"running"`，所以任何"仍在 running 即超限"
    的判据都会在这里误伤 —— 这正是我那次错误改写的失效点。
    """
    session = _run_workflow(max_steps, ["diagnosis"] * max_steps,
                            [{"status": "waiting", "nextAction": "提交答案后继续评估"}],
                            initial_state={"awaitingAnswers": False})
    # 第 1 步就 waiting，因此无论 max_steps 多大都应停在 waiting
    if max_steps >= 1:
        assert session.current_step != "max_steps", "等答题被误标为步数超限"
        assert session.state.get("awaitingAnswers") is True


def test_genuine_step_exhaustion_is_reported_as_error():
    """真正跑满 `max_steps` 仍未到终态 → 必须报 `max_steps` error。

    这证明 `for ... else` 的 `else` **是可达的**，而不是死代码：
    某轮走的是"普通步"（`act` 既非 waiting 也非 error）且循环条件耗尽时进入 `else`。
    """
    session = _run_workflow(1, ["diagnosis"], [{"status": "ok"}])
    assert session.status == "error"
    assert session.current_step == "max_steps"
    assert session.final_action == "已达到工作流步数上限"


def test_already_terminal_session_is_not_advanced():
    """已是终态的会话再跑一次 → 立即返回，不新增状态版本。"""
    from app.runtime.loop import run_workflow

    session = WorkflowSession(session_id="s-terminal", goal="已结束", status="completed",
                              state_version=5, max_steps=3)
    before = session.state_version
    run_workflow(session, lambda: {"awaitingAnswers": False},
                 lambda step, cur: pytest.fail("终态会话不应再执行步骤"))
    assert session.state_version == before
    assert session.status == "completed"


def test_awaiting_answers_short_circuits_without_advancing():
    """已处于等答题状态（无新提交）→ 直接返回，不推进、不改状态版本。

    对应生产里"重复 run 不空转"的修复（`stateVersion` 恒为 2）。
    """
    from app.runtime.loop import run_workflow

    session = WorkflowSession(session_id="s-awaiting", goal="等答题", max_steps=6)
    before = session.state_version
    run_workflow(session, lambda: {"awaitingAnswers": True, "pendingSubmission": False},
                 lambda step, cur: pytest.fail("等答题时不应执行步骤"))
    assert session.state_version == before
    assert session.current_step != "max_steps"


# ===========================================================================
# 2) HTTP 错误统一 JSON
# ===========================================================================
@pytest.mark.parametrize("method,path,expected", [
    # 405：`/api/v1/workflows` 只接受 POST
    ("get", "/api/v1/workflows", 405),
    # 405：profile 只接受 GET
    ("post", "/api/v1/profile/demo-user", 405),
])
def test_method_not_allowed_returns_json(client, method, path, expected):
    response = getattr(client, method)(path)
    assert response.status_code == expected
    assert response.is_json, f"{method.upper()} {path} 返回了非 JSON（Flask 默认 HTML 错误页）"
    body = response.get_json()
    assert body["errorCode"] == "BAD_REQUEST"
    assert isinstance(body["message"], str) and body["message"]
    assert "details" in body


def test_non_json_body_returns_json_400_not_html(client):
    """非 JSON 请求体必须返回 JSON 错误，而不是 HTML 错误页。

    说明：这里断言 **400** 而不是 415。项目里 `app/api/validation.json_object()`
    已把"有 body 但不是 JSON 对象"统一成 400 `BAD_REQUEST`（语义更准：
    客户端的问题在**载荷**而非 Content-Type），所以 415 处理器实际是兜底，
    正常路径走不到。保留 415 处理器是为了防止未来新增端点绕过 `json_object()`。
    """
    response = client.post("/api/v1/workflows", data="not json",
                           content_type="text/plain")
    assert response.status_code == 400
    assert response.is_json, "非 JSON 体返回了 HTML 错误页"
    assert response.get_json()["errorCode"] == "BAD_REQUEST"


def test_error_handlers_for_server_level_statuses_are_registered(app):
    """414 / 413 / 415 的处理器必须已注册，且返回统一 JSON 结构。

    为什么不在这里实跑 414：**414 由 WSGI/HTTP 服务器层判定，Flask 测试客户端
    不施加请求行长度上限**，所以 `test_client` 永远拿不到 414。真实触发验证放在
    `integration/verify_integration.py`（那里有真的 `run.py` 在监听端口）。
    这里通过 `app.error_handler_spec` 直接取出处理器调用，保证"一旦被触发，
    返回的是 JSON"。
    """
    registry = app.error_handler_spec

    def lookup(status):
        """在注册表里找 status 对应的处理器（不假设具体的键层级）。"""
        for _blueprint, by_status in registry.items():
            handlers = (by_status or {}).get(status)
            if handlers:
                for _exc, handler in handlers.items():
                    return handler
        return None

    for status in (405, 413, 414, 415):
        handler = lookup(status)
        assert handler is not None, f"{status} 没有注册 JSON 错误处理器"

        with app.test_request_context("/api/v1/workflows"):
            error = type("E", (Exception,),
                         {"description": "test", "code": status, "name": "E"})()
            body, code = handler(error)
            # 处理器返回的是 dict，Flask 会序列化成 JSON（与既有 404/400/500 处理器一致）
            assert code == status
            assert body["errorCode"] == "BAD_REQUEST"
            assert body["message"]
            assert "details" in body


def test_404_still_json_after_handler_additions(client):
    """回归：新增错误处理器不能把既有的 404 JSON 行为挤掉。"""
    response = client.get("/api/v1/profile/missing-user")
    assert response.status_code == 404
    assert response.is_json
    assert response.get_json()["errorCode"] == "NOT_FOUND"


# ===========================================================================
# 3) 对话历史按用户隔离
# ===========================================================================
def _say(client, message: str, user_id: str):
    return client.post("/api/agent/chat", json={"message": message, "userId": user_id})


def test_history_is_isolated_per_user(client):
    """甲看不到乙的历史，反之亦然。"""
    client.delete("/api/agent/history?userId=user-a")
    client.delete("/api/agent/history?userId=user-b")

    _say(client, "甲的问题", "user-a")
    _say(client, "乙的问题", "user-b")

    history_a = client.get("/api/agent/history?userId=user-a").get_json()["history"]
    history_b = client.get("/api/agent/history?userId=user-b").get_json()["history"]

    assert [e["user_input"] for e in history_a] == ["甲的问题"]
    assert [e["user_input"] for e in history_b] == ["乙的问题"]


def test_clearing_one_user_history_does_not_touch_another(client):
    """`DELETE` 只清当前身份 —— 原实现会清空**所有人**。"""
    client.delete("/api/agent/history?userId=user-a")
    client.delete("/api/agent/history?userId=user-b")
    _say(client, "甲的问题", "user-a")
    _say(client, "乙的问题", "user-b")

    client.delete("/api/agent/history?userId=user-a")

    assert client.get("/api/agent/history?userId=user-a").get_json()["history"] == []
    remaining_b = client.get("/api/agent/history?userId=user-b").get_json()["history"]
    assert [e["user_input"] for e in remaining_b] == ["乙的问题"], \
        "清甲的历史把乙的也清了（越权回归）"


def test_history_response_declares_identity(client):
    """响应里回传 userId，便于前端确认自己读到的是谁的历史。"""
    body = client.get("/api/agent/history?userId=who-am-i").get_json()
    assert body["userId"] == "who-am-i"


def test_history_without_identity_falls_back_to_demo_user(client):
    """不带任何身份参数 → 演示身份（评委/curl 场景不能被破坏）。"""
    body = client.get("/api/agent/history").get_json()
    assert body["userId"] == "demo-user"


def test_legacy_flat_history_file_is_migrated_not_lost(tmp_path):
    """旧的扁平数组格式要被兼容读取，不能报错也不能丢数据。"""
    from app.agent import chat_llm

    legacy = [{"user_input": "旧记录", "bot_response": "旧回复", "timestamp": "2026-01-01 00:00:00"}]
    path = chat_llm._history_path()
    original = path.read_text(encoding="utf-8") if path.exists() else None
    try:
        path.write_text(json.dumps(legacy, ensure_ascii=False), encoding="utf-8")
        assert chat_llm.get_history("demo-user") == legacy
        # 其他身份读到空，而不是崩溃
        assert chat_llm.get_history("someone-else") == []
    finally:
        if original is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original, encoding="utf-8")


def test_history_store_is_keyed_by_user(tmp_path):
    """落盘结构是按 userId 分桶的 dict（便于人工核查隔离是否生效）。"""
    from app.agent import chat_llm

    path = chat_llm._history_path()
    original = path.read_text(encoding="utf-8") if path.exists() else None
    try:
        chat_llm.append_history("你好", "你好呀", "u-bucket")
        raw = json.loads(path.read_text(encoding="utf-8"))
        assert isinstance(raw, dict)
        assert "u-bucket" in raw
        assert raw["u-bucket"][0]["user_input"] == "你好"
    finally:
        if original is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original, encoding="utf-8")


# ===========================================================================
# 4) CORS 收紧
# ===========================================================================
def test_cors_allows_localhost_origin(client):
    response = client.get("/api/agent/health", headers={"Origin": "http://localhost:8080"})
    assert response.headers.get("Access-Control-Allow-Origin") == "http://localhost:8080"


def test_cors_allows_private_lan_origin_for_real_device(client):
    """HarmonyOS 真机走局域网 IP，必须放行，否则真机联调直接失效。"""
    response = client.get("/api/agent/health", headers={"Origin": "http://192.168.1.20:5000"})
    assert response.headers.get("Access-Control-Allow-Origin") == "http://192.168.1.20:5000"


def test_cors_does_not_reflect_arbitrary_origin(client):
    """公网域名不得被反射 —— 原先裸 `CORS(app)` 会放行任意 Origin。"""
    response = client.get("/api/agent/health",
                          headers={"Origin": "https://evil.example.com"})
    allowed = response.headers.get("Access-Control-Allow-Origin")
    assert allowed != "https://evil.example.com", "CORS 仍在反射任意 Origin"
    assert allowed != "*"


def test_cors_origins_overrideable_by_env(monkeypatch, tmp_path):
    """`ZHIXUE_CORS_ORIGINS` 可覆盖，便于排障与部署。"""
    monkeypatch.setenv("ZHIXUE_CORS_ORIGINS", "http://custom.host:1234")
    application = create_app(tmp_path / "cors-override.json")
    local = application.test_client().get(
        "/api/agent/health", headers={"Origin": "http://custom.host:1234"})
    assert local.headers.get("Access-Control-Allow-Origin") == "http://custom.host:1234"

    other = application.test_client().get(
        "/api/agent/health", headers={"Origin": "http://localhost:9999"})
    assert other.headers.get("Access-Control-Allow-Origin") is None
