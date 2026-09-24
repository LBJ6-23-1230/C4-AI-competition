# -*- coding: utf-8 -*-
"""回归测试：跨用户数据隔离与畸形输入健壮性。

本文件固化的是 2026-09-22 三轮只读审计（后端 / 前端 / 契约）发现的缺陷中，
**已修复且能用后端接口复现**的部分。每条测试的 docstring 都写明
"原缺陷现象 → 后果 → 为什么这样断言"，便于日后判断测试是否仍然有效。
"""

from __future__ import annotations

import base64

import pytest

from app import create_app


def _register(client, nickname: str, phone: str) -> str:
    """注册并返回 Bearer token。"""
    response = client.post("/api/v1/auth/register",
                           json={"nickname": nickname, "phone": phone})
    assert response.status_code in (200, 201), response.get_data(as_text=True)
    return response.get_json()["token"]


def _create_kb(client, token: str, name: str) -> str:
    response = client.post("/api/v1/knowledge-bases",
                           json={"name": name, "courseName": "数据结构"},
                           headers={"Authorization": f"Bearer {token}"})
    assert response.status_code in (200, 201), response.get_data(as_text=True)
    return response.get_json()["kbId"]


# --------------------------------------------------------------------------- 知识库切片隔离
def test_same_file_name_from_two_users_does_not_overwrite_chunks(tmp_path):
    """同名同内容文件上传后，两个用户的切片必须各自独立。

    原缺陷：`chunkId` 只由 `(fileName, 序号, text[:64])` 决定，
    而它同时是 `chunks` 集合的**主键**。于是 user-b 上传与 user-a 同名同内容的
    文件时，会直接覆盖 user-a 的切片记录（连 userId/kbId 都被改写），
    导致 user-a 的检索命中由 1 变 0，而其知识库汇总仍显示 chunkCount=2。

    断言：两个 userId 在 chunks 里都至少有一条记录，且 A 仍能检索到命中。
    """
    client = create_app(tmp_path / "kb-isolation.json").test_client()
    token_a = _register(client, "isolation-a", "13900002001")
    token_b = _register(client, "isolation-b", "13900002002")
    head_a = {"Authorization": f"Bearer {token_a}"}
    head_b = {"Authorization": f"Bearer {token_b}"}

    body = base64.b64encode(
        "# 二叉树遍历\n\n前序是根左右。\n中序是左根右。\n后序是左右根。\n".encode("utf-8")
    ).decode("ascii")

    kb_a = _create_kb(client, token_a, "A 的资料")
    kb_b = _create_kb(client, token_b, "B 的资料")

    up_a = client.post(f"/api/v1/knowledge-bases/{kb_a}/documents",
                       json={"fileName": "notes.md", "contentBase64": body}, headers=head_a)
    assert up_a.status_code in (200, 201)
    assert up_a.get_json()["chunkCount"] > 0

    up_b = client.post(f"/api/v1/knowledge-bases/{kb_b}/documents",
                       json={"fileName": "notes.md", "contentBase64": body}, headers=head_b)
    assert up_b.status_code in (200, 201)

    # A 仍能检索到自己的切片 —— 这是"未被覆盖"最直接的证据
    search = client.post(f"/api/v1/knowledge-bases/{kb_a}/search",
                         json={"query": "后序遍历"}, headers=head_a)
    assert search.status_code == 200
    assert len(search.get_json().get("hits") or []) > 0, \
        "user-a 的检索被 user-b 的同名文件摧毁（chunkId 主键冲突未修复）"


def test_demo_reset_does_not_delete_other_users_workflow(tmp_path):
    """匿名 demo/reset 不得删除其他用户的 workflow。

    原缺陷：实现是 `_repository.clear(collection)` —— 清空**整个集合**，
    而该接口无需任何凭据。于是任何匿名请求都会把所有注册用户的
    workflows / traces / submissions / evidences / plan_histories 一起删掉，
    而 profiles 仍保留 → 用户数据变成孤儿且不可恢复。

    断言：reset 之后，另一个用户的 workflow 仍然可读（200）。
    """
    client = create_app(tmp_path / "demo-reset-scope.json").test_client()
    token = _register(client, "reset-victim", "13900003001")
    head = {"Authorization": f"Bearer {token}"}

    created = client.post("/api/v1/workflows", json={"goal": "受害者的工作流"}, headers=head)
    assert created.status_code in (200, 201)
    session_id = created.get_json()["sessionId"]

    assert client.get(f"/api/v1/workflows/{session_id}", headers=head).status_code == 200

    assert client.post("/api/v1/demo/reset").status_code == 200

    after = client.get(f"/api/v1/workflows/{session_id}", headers=head)
    assert after.status_code == 200, \
        "匿名 demo/reset 删除了其他用户的 workflow（整集合 clear 未修复）"


def test_demo_reset_still_clears_demo_owned_workflows(tmp_path):
    """反向保护：demo/reset 仍必须清掉**演示身份自己**的 workflow。

    与上一条是一对：按归属删除不能宽到"什么都不删"。
    """
    client = create_app(tmp_path / "demo-reset-own.json").test_client()
    client.post("/api/v1/demo/reset")

    created = client.post("/api/v1/workflows", json={"goal": "演示累积"})
    session_id = created.get_json()["sessionId"]
    assert client.get(f"/api/v1/workflows/{session_id}").status_code == 200

    client.post("/api/v1/demo/reset")
    assert client.get(f"/api/v1/workflows/{session_id}").status_code == 404


# --------------------------------------------------------------------------- 畸形输入健壮性
@pytest.mark.parametrize("context", [
    {"location": 5},
    {"location": [1, 2]},
    {"location": {"a": 1}},
    {"now": 1758530000},
    {"now": 123},
    {"lastStudyAt": 1758530000},
    {"lastStudyAt": [1]},
    {"now": "not-a-date"},
])
def test_proactive_tolerates_wrongly_typed_context(tmp_path, context):
    """`/api/v1/agent/proactive` 遇到类型错误的 context 字段不得 500。

    原缺陷两处：
      * `(context.get("location") or "unknown").strip()` —— 非空非字符串绕过 `or`，
        抛 `AttributeError: 'int' object has no attribute 'strip'`
      * `_parse_iso8601` 只捕 `ValueError`，对非字符串直接 `.replace()`，
        epoch 秒（客户端最常见写法）会抛 `AttributeError`

    契约把 location 声明为 string、now/lastStudyAt 声明为 string/date-time，
    类型不符应当被当成"信号缺失"处理，而不是服务器故障。
    """
    client = create_app(tmp_path / "proactive-types.json").test_client()
    response = client.post("/api/v1/agent/proactive",
                           json={"userId": "demo-user", "context": context})
    assert response.status_code < 500, \
        f"畸形 context {context!r} 触发了 {response.status_code}"


def test_proactive_normal_payload_unchanged(tmp_path):
    """回归：正常载荷仍应给出通知决策（修复不能把功能一起关掉）。"""
    client = create_app(tmp_path / "proactive-normal.json").test_client()
    response = client.post("/api/v1/agent/proactive", json={
        "userId": "demo-user",
        "context": {
            "now": "2026-09-22T10:00:00+08:00",
            "daysLeft": 3,
            "masteryScore": 42,
            "pendingTasks": [],
            "location": "library",
        },
    })
    assert response.status_code == 200
    body = response.get_json()
    assert body["shouldNotify"] is True
    assert body["channel"] == "reminder"
    assert body["reason"]


# --------------------------------------------------------------------------- 契约字段
def test_workflow_run_returns_contract_required_next_action(tmp_path):
    """`POST /api/v1/workflows`（autoRun 分支）必须返回契约 required 的 nextAction。

    原缺陷：`_run_saved_workflow()` 已算出 `updated["nextAction"]`，
    但返回键元组没包含它 → 违反 `WorkflowResponse.required`，
    契约合规的前端客户端必然拿到 INVALID_RESPONSE。
    """
    client = create_app(tmp_path / "workflow-nextaction.json").test_client()
    created = client.post("/api/v1/workflows",
                          json={"goal": "验证 nextAction", "autoRun": True})
    assert created.status_code in (200, 201)
    body = created.get_json()
    assert "nextAction" in body, "autoRun 分支缺少契约 required 的 nextAction"


def test_workflow_state_does_not_leak_answer_keys(tmp_path):
    """标准答案不得随工作流状态回传。

    原缺陷：`_workflow_state()` 把 `_ANSWER_KEYS` 塞进会话 state，
    而 `_run_saved_workflow()` 只 pop 了 profile/exercises/answers，
    `state.answerKeys` 原样返回并落盘 —— 发一次不传答案的 run
    即可拿到全部正确选项，**确定性判分层被完全绕过**。
    """
    client = create_app(tmp_path / "workflow-answers.json").test_client()
    created = client.post("/api/v1/workflows", json={"goal": "验证答案不外泄"})
    session_id = created.get_json()["sessionId"]

    ran = client.post(f"/api/v1/workflows/{session_id}/run", json={})
    assert ran.status_code in (200, 201)
    state = ran.get_json().get("state") or {}
    assert "answerKeys" not in state, "工作流状态里回传了标准答案"


# --------------------------------------------------------------------------- 计划因子
def test_plan_factors_come_from_real_profile(tmp_path):
    """`/plans/current` 的五因子必须随画像变化，不能是常量。

    原缺陷：`app/api/plans.py` 直接给确定性优先级引擎喂硬编码常量
    （`masteryScore: 58`、`errorIntensity: 67`、`importance: 90` …），
    于是"为什么是它"因子卡的数字**与调用者是谁完全无关**。

    断言：把画像掌握度从 42 改成 90 后，mastery 因子的 value 必须变化。
    """
    client = create_app(tmp_path / "plan-factors.json").test_client()
    client.post("/api/v1/demo/reset")

    import app.api.plans as plans_module

    first = client.get("/api/v1/plans/current?userId=demo-user").get_json()
    mastery_first = next(r for r in first["factors"] if r["name"] == "mastery")

    profile = plans_module._repository.get("profiles", "demo-user")
    for item in profile.get("mastery", []):
        if item.get("knowledgePointId") == "binary-tree-postorder":
            item["masteryScore"] = 90
    plans_module._repository.save("profiles", "demo-user", profile)

    second = client.get("/api/v1/plans/current?userId=demo-user").get_json()
    mastery_second = next(r for r in second["factors"] if r["name"] == "mastery")

    assert mastery_first["value"] != mastery_second["value"], \
        "五因子不随画像变化 —— 说明仍在喂常量"
    # 量纲检查：引擎内部 /100 归一化，value 必在 [0,1]
    assert 0.0 <= mastery_second["value"] <= 1.0


def test_plan_factors_explain_the_lead_task(tmp_path):
    """因子卡解释的必须是**计划首个任务**的知识点。

    原缺陷（修复过程中暴露）：实现取"重新排名后的第一名"，
    而画像里没有掌握度记录的知识点回退 0 → mastery 因子恒为 1.0 → 必然排第一，
    于是计划页显示 task-postorder，因子卡讲的却是 graph-algorithm。
    """
    client = create_app(tmp_path / "plan-lead-task.json").test_client()
    client.post("/api/v1/demo/reset")

    body = client.get("/api/v1/plans/current?userId=demo-user").get_json()
    lead_point = body["tasks"][0].get("knowledgePointId")
    mastery = next(r for r in body["factors"] if r["name"] == "mastery")

    # demo 基线的首个任务是 binary-tree-postorder，画像掌握度 42 → (100-42)/100 = 0.58
    if lead_point == "binary-tree-postorder":
        assert mastery["value"] == pytest.approx(0.58, abs=0.001), \
            "因子卡讲错了知识点（不是计划首个任务）"


# --------------------------------------------------------------------------- 掌握度归属
def test_mastery_update_is_attributed_to_the_practiced_knowledge_point(tmp_path):
    """掌握度必须记在**本次练习的那个知识点**上。

    原缺陷（后端审计 P1-5）：
      * `old_mastery` 固定取 `binary-tree-postorder` 那条（否则 42）
      * 响应的 `masteryUpdate.knowledgePointId` 被硬编码成同一值
      * `persist_mastery` 把**同一个** `suggested_new_mastery` 写给所有被判分知识点
    后果：提交其它知识点题集时，"掌握度提升"落不到画像上，真正的薄弱点永不被记录。

    断言：提交 graph-algorithm 的题后，响应里报告的就是 graph-algorithm，
    而不是 binary-tree-postorder。
    """
    client = create_app(tmp_path / "mastery-attribution.json").test_client()
    client.post("/api/v1/demo/reset")

    resp = client.post("/api/v1/exercises/set-demo-data-structures-001/submit", json={
        "userId": "demo-user",
        "idempotencyKey": "mastery-attribution-001",
        "answers": [{"exerciseId": "exercise-graph-001", "answer": "A"}],
    })
    assert resp.status_code == 200, resp.get_data(as_text=True)
    body = resp.get_json()
    reported = body["masteryUpdate"]["knowledgePointId"]
    assert reported == "graph-algorithm", \
        f"掌握度被记到了 {reported!r}，而不是本次练习的 graph-algorithm"


def test_mastery_update_creates_missing_knowledge_point(tmp_path):
    """画像里没有记录的知识点，练习后必须被补建。

    原缺陷：`persist_mastery` 只遍历**已存在**的 mastery 条目，
    新知识点练完在响应里可见、画像里却查无此点 —— 统计与事实不符。
    """
    client = create_app(tmp_path / "mastery-create.json").test_client()
    client.post("/api/v1/demo/reset")

    import app.api.exercises as exercises_module

    resp = client.post("/api/v1/exercises/set-demo-data-structures-001/submit", json={
        "userId": "demo-user",
        "idempotencyKey": "mastery-create-001",
        "answers": [{"exerciseId": "exercise-graph-001", "answer": "A"}],
    })
    assert resp.status_code == 200

    profile = exercises_module._repository.get("profiles", "demo-user")
    points = {m.get("knowledgePointId") for m in (profile or {}).get("mastery", [])}
    assert "graph-algorithm" in points, \
        "练习过的知识点没有在画像里建档（画像里查无此点）"


def test_empty_answers_do_not_penalize_mastery(tmp_path):
    """空答案不得被当成"全错"扣掌握度并触发重规划。

    原缺陷（后端审计 P1-6）：`validate_answers` 放行 `answers: []`，
    判分用 `max(1, len(valid_ids))` 掩盖除零 → `score=0.0` →
    掌握度 -4、`needReplan=true`、计划被改成 [45,15]、profileVersion +1、
    history 记一条 —— 但 `perKnowledgeAccuracy` 为空，
    `persist_mastery` 什么都没改，于是历史/响应与真实数据不一致，
    **用户被无理由罚分**。

    断言：空答案返回 400，且画像掌握度不变。
    """
    client = create_app(tmp_path / "empty-answers.json").test_client()
    client.post("/api/v1/demo/reset")

    import app.api.exercises as exercises_module

    before = exercises_module._repository.get("profiles", "demo-user")
    before_mastery = {m["knowledgePointId"]: m["masteryScore"] for m in before["mastery"]}

    resp = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
        "userId": "demo-user",
        "idempotencyKey": "empty-answers-001",
        "answers": [],
    })
    assert resp.status_code == 400, \
        f"空答案应被拒绝，实际 {resp.status_code}：{resp.get_data(as_text=True)[:200]}"

    after = exercises_module._repository.get("profiles", "demo-user")
    after_mastery = {m["knowledgePointId"]: m["masteryScore"] for m in after["mastery"]}
    assert before_mastery == after_mastery, "空答案改变了掌握度（无理由罚分）"


# --------------------------------------------------------------------------- 并发
def test_concurrent_trace_append_does_not_lose_events(tmp_path):
    """并发追加 trace 事件不得丢事件。

    原缺陷（后端审计 P1-13）：`EventStore.append` 是"读整个 trace → 追加一条
    → 写回"，`JsonRepository.save()` 虽有自己的写锁，但**锁不住这段序列**。
    实测 48 次并发 append 只留下 5 条事件 —— 而 trace 是答辩里
    "Agent 决策可追溯"的核心证据，`/api/v1/experiments/snapshot` 的统计也基于它。

    断言：N 线程各追加 1 条后，事件数正好是 N。
    """
    import threading

    from app.domain.trace import TraceEvent
    from app.tools.trace_tools import EventStore

    app = create_app(tmp_path / "trace-concurrency.json")
    import app.api.traces as traces_module

    repository = traces_module._repository
    store = EventStore(repository)
    trace_id = "trace-concurrency-probe"
    repository.save("traces", trace_id, {"traceId": trace_id, "events": []})

    workers = 24
    barrier = threading.Barrier(workers)

    def worker(index: int) -> None:
        barrier.wait()  # 尽量让所有线程同时进入 append
        store.append(trace_id, TraceEvent(
            agent="assessment", tool_calls=["grade_exercise"],
            input_summary=f"并发 {index}", output_summary="ok", evidence_ids=[],
            state_version=1, timestamp=__import__("datetime").datetime.now(
                __import__("datetime").timezone.utc),
            status="completed"))

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(workers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    events = store.list(trace_id)
    assert len(events) == workers, \
        f"并发追加丢了事件：期望 {workers} 条，实际 {len(events)} 条"


def test_wrong_submission_id_reports_submission_error_not_workflow_error(tmp_path):
    """对**存在的**会话传错 submissionId，报错必须指向 submissionId。

    原缺陷（后端审计 P2-16）：`raise KeyError(submission_id)` 与"会话不存在"
    共用同一个 `except KeyError` 分支，于是返回
    `404 {"message": "workflow not found"}` —— 而 workflow 其实存在。
    客户端会误判为会话失效并重建会话，掩盖真实错误。
    """
    client = create_app(tmp_path / "wrong-submission.json").test_client()
    created = client.post("/api/v1/workflows", json={"goal": "验证报错语义"})
    session_id = created.get_json()["sessionId"]

    resp = client.post(f"/api/v1/workflows/{session_id}/run",
                       json={"submissionId": "submission-does-not-exist"})
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["errorCode"] == "NOT_FOUND"
    assert "submission" in body["message"], \
        f"报错指向了 workflow 而不是 submission：{body['message']!r}"


# --------------------------------------------------------------------------- 画像更新落盘
def test_update_profile_intent_actually_persists_goal(tmp_path):
    """「更新档案」意图必须真的写进 profiles，而不是只回一句"已更新"。

    原缺陷（后端审计 P1-11）：`_handle_update_profile` 只取模型返回的 `reply`，
    把整个 `updates` 对象丢弃，且 chat 全链路没有 repository 写入口 ——
    用户说"把目标改成 XX"会得到"已帮你更新信息。"，但 profiles 一字未改。
    这是**静默 no-op + 假成功**。

    断言：直接调用落盘钩子后，profiles 里的 goal 真的变了、profileVersion 递增。
    """
    app = create_app(tmp_path / "profile-persist.json")
    import app.api.chat as chat_module

    before = chat_module._repository.get("profiles", "demo-user")
    changed = chat_module._apply_profile_updates("demo-user", {
        "user": {"learningGoal": {"goal": "数据结构期末 90+"}}
    })
    after = chat_module._repository.get("profiles", "demo-user")

    assert changed, "钩子没有报告任何改动"
    assert after["goal"] == "数据结构期末 90+"
    assert after["profileVersion"] == before["profileVersion"] + 1, \
        "画像版本号没有递增（下游无法感知变更）"


def test_update_profile_hook_ignores_fields_backend_does_not_own(tmp_path):
    """后端不持有的字段（姓名/年级/薄弱点）不得被写进 profiles。

    为什么这条重要：`profiles` 的 schema 只有
    `{userId, goal, examDate, freeTimeSlots, profileVersion, mastery}`。
    把 `basicInfo` / `knowledge` 硬塞进来只会写到一个没人读的地方 ——
    那正是本次要消灭的"假成功"。这些字段属于前端本地 AppState，由前端应用。
    """
    create_app(tmp_path / "profile-scope.json")
    import app.api.chat as chat_module

    changed = chat_module._apply_profile_updates("demo-user", {
        "user": {
            "basicInfo": {"name": "张三", "grade": "大三"},
            "knowledge": {"weakness": ["图算法"]},
        }
    })
    profile = chat_module._repository.get("profiles", "demo-user")

    assert changed == [], f"不该报告改动了后端不持有的字段：{changed}"
    assert "name" not in profile and "basicInfo" not in profile
    assert "weakness" not in profile and "knowledge" not in profile


def test_chat_layer_hook_is_wired_by_create_app(tmp_path):
    """`create_app()` 必须把画像落盘钩子注册给对话层。

    为什么要单独测"接线"：只测 `_apply_profile_updates()` 本身，
    无法发现"钩子没被注册"这种断线 —— 而断了线就退回到原来的
    静默 no-op（回复说已更新、实际没落盘），正是本次要修的问题。
    """
    create_app(tmp_path / "hook-wiring.json")
    from app.agent import chat_llm

    assert chat_llm._PROFILE_UPDATE_HOOK is not None, \
        "create_app() 没有注册画像落盘钩子（chat 层会退回静默 no-op）"

    # 通过钩子走一遍，确认它真的写到了 profiles
    applied = chat_llm._PROFILE_UPDATE_HOOK("demo-user", {
        "user": {"learningGoal": {"goal": "接线验证目标"}}
    })
    assert applied, "钩子没有报告任何改动"
    import app.api.chat as chat_module

    profile = chat_module._repository.get("profiles", "demo-user")
    assert profile["goal"] == "接线验证目标", "钩子被调用但没有落盘"


def test_update_profile_handler_returns_updates_for_frontend(tmp_path):
    """`_handle_update_profile` 必须把 updates 交给调用方，而不是丢掉。

    原缺陷：该函数只 `return reply`，把整份 updates 丢弃 ——
    于是 prompt 里"返回 updates 让调用方应用"的设计完全落空，
    课程/任务类改动永远无法生效。
    这里不调真实 LLM（会需要网络与配额），改为验证**返回值契约**：
    正常路径返回 `(reply, updates)` 二元组，且 updates 是 dict。
    """
    from app.agent import chat_llm

    original = chat_llm._call_llm
    try:
        # 伪造模型输出：符合 UpdateProfilePrompt 约定
        chat_llm._call_llm = lambda *a, **k: (
            '{"intent":"update_profile","reply":"好的，已记录。",'
            '"updates":{"user":{"learningGoal":{"goal":"数据结构 90+"}},'
            '"course":[{"courseName":"数据结构","tasks":[]}]}}'
        )
        reply, updates = chat_llm._handle_update_profile("把目标改成 90+", {}, "demo-user")
    finally:
        chat_llm._call_llm = original

    assert isinstance(updates, dict), "updates 没有被返回给调用方"
    assert updates.get("user"), "updates.user 丢失"
    assert updates.get("course"), "updates.course 丢失（前端无法应用课程改动）"
    # 课程类改动后端接不住，回复里必须**如实说明**，不能默默假装成功了
    assert "App 本地维护" in reply, \
        f"回复没有如实说明课程改动由前端维护：{reply!r}"



