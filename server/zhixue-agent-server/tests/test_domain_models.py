from datetime import date, datetime, timezone

import pytest

from app.domain.evidence import Evidence, MasteryHistory
from app.domain.assessment import AssessmentResult
from app.domain.exercise import Exercise, ExerciseResult, ExerciseSet
from app.domain.plan import LearningPlan, PlanHistory
from app.domain.profile import KnowledgeMastery, LearnerProfile
from app.domain.trace import TraceEvent
from app.decision.priority import calculate_learning_priority
from app.decision.replan_rules import replan_learning_path, should_replan
from app.tools.assessment_tools import grade_exercise, update_mastery
from app.tools.plan_tools import build_plan_diff, create_plan_history
from app.tools.exercise_tools import select_exercises
from app.runtime.tool_registry import ToolError, ToolRegistry, create_default_registry
from app.runtime.loop import run_workflow
from app.runtime.orchestrator import decide_next_step, fallback_decision
from app.runtime.session import WorkflowSession
from app.agents.assessment import AssessmentAgent
from app.agents.diagnosis import DiagnosisAgent
from app.agents.exercise import ExerciseAgent
from app.agents.planner import PlannerAgent
from app.agents.secretary import SecretaryAgent
from app.tools.trace_tools import EventStore, append_trace_event
from app.model_adapters.fallback_adapter import FallbackAdapter
from app.model_adapters.llm import ModelAdapterError
from app.model_adapters.qwen_adapter import QwenAdapter
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.decision.mastery_rules import is_mastery_below_threshold, mastery_band
from app.tools.course_tools import select_courses
from app.tools.profile_tools import get_mastery, profile_summary
from app import create_app


def test_knowledge_mastery_round_trips_contract_fields():
    mastery = KnowledgeMastery("binary-tree", 42, 70, datetime(2026, 9, 2, tzinfo=timezone.utc))

    restored = KnowledgeMastery.from_dict(mastery.to_dict())

    assert restored.to_dict() == mastery.to_dict()


def test_exercise_set_round_trips_public_question_fields_without_answer_key():
    exercise = Exercise("exercise-001", "binary-tree", "二叉树", "easy", "遍历顺序是什么？", ["A", "B"])
    exercise_set = ExerciseSet("set-001", [exercise])

    assert Exercise.from_dict(exercise.to_dict()).to_dict() == exercise.to_dict()
    assert exercise_set.to_dict() == {"setId": "set-001", "exercises": [exercise.to_dict()]}
    assert "answer" not in exercise.to_dict()


def test_exercise_models_reject_invalid_question_and_duplicate_ids():
    with pytest.raises(ValueError, match="difficulty"):
        Exercise("exercise-001", "binary-tree", "二叉树", "expert", "题目", ["A", "B"])

    exercise = Exercise("exercise-001", "binary-tree", "二叉树", "easy", "题目", ["A", "B"])
    with pytest.raises(ValueError, match="unique"):
        ExerciseSet("set-001", [exercise, exercise])


def test_exercise_result_serializes_submission():
    result = ExerciseResult("result-001", "set-001", {"exercise-001": "A"}, 100, datetime(2026, 9, 7, tzinfo=timezone.utc))

    assert result.to_dict()["completedAt"] == "2026-09-07T00:00:00+00:00"


def test_grade_exercise_returns_expected_score_and_knowledge_accuracy():
    result = grade_exercise(
        [
            {"exerciseId": "pre", "answer": "A"},
            {"exerciseId": "in", "answer": "B"},
            {"exerciseId": "post", "answer": "A"},
        ],
        {"pre": "A", "in": "B", "post": "C"},
        {"pre": "binary-tree-postorder", "in": "binary-tree-postorder", "post": "binary-tree-postorder"},
        old_mastery=42,
    )

    assert result.to_dict()["score"] == 66.67
    assert result.to_dict()["perKnowledgeAccuracy"] == {"binary-tree-postorder": 0.6667}
    assert result.to_dict()["errorTypes"] == ["traversal-order"]
    assert result.suggested_new_mastery == 58


def test_update_mastery_is_bounded_and_deterministic():
    assert update_mastery(42, 66.67) == 58
    assert update_mastery(42, 100) == 71
    assert update_mastery(90, 100) == 100

    with pytest.raises(ValueError, match="old_score"):
        update_mastery(101, 80)


def test_plan_tools_build_versioned_diff_and_history():
    old_plan = {"planId": "plan-001", "version": 1, "tasks": [
        {"taskId": "postorder", "knowledgePointId": "binary-tree", "durationMinutes": 30},
        {"taskId": "graph", "knowledgePointId": "graph", "durationMinutes": 30},
    ]}
    new_plan = {"planId": "plan-001", "version": 2, "tasks": [
        {"taskId": "postorder", "knowledgePointId": "binary-tree", "durationMinutes": 45},
        {"taskId": "graph", "knowledgePointId": "graph", "durationMinutes": 15},
    ]}

    assert build_plan_diff(old_plan, new_plan)["changedTasks"] == new_plan["tasks"]
    history = create_plan_history(old_plan, new_plan, "mastery_below_threshold", ["ev-001"])
    assert history["oldVersion"] == 1
    assert history["newVersion"] == 2
    assert history["reason"] == "mastery_below_threshold"
    assert history["evidenceIds"] == ["ev-001"]


def test_knowledge_mastery_rejects_score_outside_range():
    with pytest.raises(ValueError, match="mastery_score"):
        KnowledgeMastery("binary-tree", 101, 70, datetime.now(timezone.utc))


def test_profile_version_is_monotonic_when_advanced():
    profile = LearnerProfile("u001", "期末80+", date(2026, 9, 30), ["20:00-22:00"])

    assert profile.advance_version() == 2
    assert profile.profile_version == 2


def test_learning_plan_round_trips_and_advances_version():
    plan = LearningPlan("plan-001", 1, [{"knowledgePointId": "binary-tree", "duration": 30}], 1)

    restored = LearningPlan.from_dict(plan.to_dict())

    assert restored.to_dict() == plan.to_dict()
    assert restored.next_version() == 2


def test_learning_plan_rejects_non_positive_version():
    with pytest.raises(ValueError, match="version"):
        LearningPlan("plan-001", 0, [], 1)


def test_learning_plan_to_dict_carries_owner():
    """`to_dict()` 必须带上归属。

    计划重排是**整条覆盖**写回（`exercises.py` / `workflows.py` 都 save 同一条 key），
    只要 `to_dict()` 不带 `userId`，记录就会丢掉归属；而读侧 `plans.py` 用的是
    `plan.get("userId", "demo-user")` —— 键缺失时默认值生效，真实账号随即
    `GET /plans/current` → 404。这条把写侧的口径钉住。
    """
    owned = LearningPlan("plan-u-1", 1, [{"taskId": "t"}], 1, "r", "u-1")

    assert owned.to_dict()["userId"] == "u-1"
    assert LearningPlan.from_dict(owned.to_dict()).user_id == "u-1"
    # 往返后仍然一致
    assert LearningPlan.from_dict(owned.to_dict()).to_dict() == owned.to_dict()


def test_learning_plan_without_owner_omits_the_key():
    """未设置归属时**不写该键**，而不是写空串。

    读侧的默认值口径依赖"键缺失"（`.get("userId", "demo-user")`）；
    写成 `""` 会让默认值失效，反而把演示身份也弄失配。
    """
    anonymous = LearningPlan("plan-demo-001", 1, [], 1, "r")

    assert "userId" not in anonymous.to_dict()


def test_domain_history_and_trace_round_trip_contract_fields():
    timestamp = datetime(2026, 9, 3, tzinfo=timezone.utc)
    evidence = Evidence("ev-001", "assessment", "result-001", "binary-tree", "accuracy", 0.67, timestamp, 0.9)
    mastery_history = MasteryHistory(42, 58, ["ev-001"], "assessment", timestamp)
    plan_history = PlanHistory(1, 2, [{"taskId": "task-001"}], "掌握度低于阈值", ["ev-001"], timestamp)
    trace = TraceEvent("assessment", ["grade_exercise"], "答案已提交", "掌握度更新", ["ev-001"], 3, timestamp, "completed")

    assert Evidence.from_dict(evidence.to_dict()).to_dict() == evidence.to_dict()
    assert MasteryHistory.from_dict(mastery_history.to_dict()).to_dict() == mastery_history.to_dict()
    assert PlanHistory.from_dict(plan_history.to_dict()).to_dict() == plan_history.to_dict()
    assert TraceEvent.from_dict(trace.to_dict()).to_dict() == trace.to_dict()


def test_event_store_appends_trace_events_with_runtime_versions(tmp_path):
    repository = JsonRepository(tmp_path / "events.json")
    event = append_trace_event(repository, "trace-001", agent="planner", tool_calls=["calculate_learning_priority"],
        input_summary="读取画像", output_summary="生成计划", evidence_ids=["ev-001"], state_version=2,
        status="completed", session_id="session-001", step_id="step-1", input_state_version=1,
        output_state_version=2)

    assert event["sessionId"] == "session-001"
    assert event["outputStateVersion"] == 2
    assert EventStore(repository).list("trace-001") == [event]


def test_json_repository_survives_reopen(tmp_path):
    path = tmp_path / "repository.json"
    repository = JsonRepository(path)
    repository.save("profiles", "u001", {"userId": "u001", "profileVersion": 1})
    repository.save("traces", "trace-001", {"traceId": "trace-001", "events": []})

    reopened = JsonRepository(path)

    assert reopened.get("profiles", "u001") == {"userId": "u001", "profileVersion": 1}
    assert reopened.list("traces") == [{"traceId": "trace-001", "events": []}]
    reopened.delete("profiles", "u001")
    assert reopened.get("profiles", "u001") is None


def test_json_repository_is_safe_under_concurrent_writes(tmp_path):
    """并发保存不得抛异常。

    回归背景：`_flush()` 原先用**固定**的临时文件名，且没有锁。
    并发写时在 Windows 上会以两种方式失败：
      1. 多方写同一个 `.tmp`，一方 `os.replace()` 时文件被占用 → WinError 32
      2. 临时名唯一后，多个 `os.replace()` 同时替换同一目标 → WinError 5
    两者都会冒泡成 HTTP 500。经 HTTP 并发提交实测：
    修复前 **8 并发 88% 返回 500、10 并发 90%**；修复后 0%。

    这里用 barrier 让线程同时起跑，并用较大 payload 放大竞态窗口
    （小 payload 时窗口太窄，复现不出来）。
    """
    import threading

    path = tmp_path / "concurrent.json"
    repository = JsonRepository(path)
    errors: list[BaseException] = []
    lock = threading.Lock()
    barrier = threading.Barrier(8)

    def writer(index: int) -> None:
        barrier.wait()
        try:
            repository.save("bench", f"k{index}", {"index": index, "pad": "x" * 20000})
        except BaseException as error:  # noqa: BLE001 - 测试需要捕获全部异常
            with lock:
                errors.append(error)

    threads = [threading.Thread(target=writer, args=(i,)) for i in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == [], f"并发写出现异常：{errors[:1]}"
    # 8 次写入应当全部落盘
    assert len(repository.list("bench")) == 8


def test_demo_reset_persists_profile_plan_and_trace(tmp_path):
    app = create_app(tmp_path / "demo.json")
    client = app.test_client()

    response = client.post("/api/v1/demo/reset")

    assert response.status_code == 200
    body = response.get_json()
    assert body["profile"]["mastery"][0]["masteryScore"] == 42
    assert body["plan"]["version"] == 1
    assert body["traceId"] == "trace-demo-reset-001"

    reopened = JsonRepository(tmp_path / "demo.json")
    assert reopened.get("profiles", "demo-user")["mastery"][0]["masteryScore"] == 42
    assert reopened.get("plans", "plan-demo-001")["version"] == 1
    assert reopened.get("traces", "trace-demo-reset-001")["events"] == []


def test_demo_api_exposes_profile_plan_exercises_and_health(tmp_path):
    client = create_app(tmp_path / "api.json").test_client()

    assert client.get("/health").get_json() == {"status": "ok"}
    assert client.get("/api/v1/profile/demo-user").status_code == 200
    assert client.get("/api/v1/plans/current").get_json()["planId"] == "plan-demo-001"
    exercises = client.get("/api/v1/exercises/set-demo-binary-tree-001").get_json()
    assert exercises["setId"] == "set-demo-binary-tree-001"
    assert len(exercises["exercises"]) == 3


def test_question_bank_answer_keys_are_used_for_grading(tmp_path):
    client = create_app(tmp_path / "answers.json").test_client()
    client.post("/api/v1/demo/reset")

    response = client.post("/api/v1/exercises/set-demo-data-structures-001/submit", json={
        "idempotencyKey": "graph-answer-001",
        "answers": [{"exerciseId": "exercise-graph-001", "answer": "B"}],
    })

    assert response.status_code == 200
    assert response.get_json()["assessment"]["score"] == 100


def test_legacy_chat_compatibility_endpoint_uses_stable_response_shape(tmp_path):
    client = create_app(tmp_path / "chat.json").test_client()

    empty = client.post("/api/agent/chat", json={})
    response = client.post("/api/agent/chat", json={"message": "我想查查错题"})

    assert empty.status_code == 200
    assert empty.get_json() == {"reply": "请告诉我你需要什么帮助？", "intent": "unknown",
                                "card": None, "llmUsed": False}
    assert response.status_code == 200
    # 契约基线三字段 + 可选 llmUsed（前端 ChatMain 据此显示来源标签）
    assert set(response.get_json()) == {"reply", "intent", "card", "llmUsed"}
    assert response.get_json()["intent"] == "analyze_wrong"
    assert response.get_json()["llmUsed"] is False


def test_experiment_snapshot_exports_anonymous_counts_and_records(tmp_path):
    client = create_app(tmp_path / "experiment.json").test_client()
    client.post("/api/v1/demo/reset")
    client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
        "idempotencyKey": "snapshot-001",
        "answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"}],
    })

    response = client.get("/api/v1/experiments/snapshot")
    body = response.get_json()

    assert response.status_code == 200
    assert body["snapshotVersion"] == "experiment-snapshot-v1"
    assert body["summary"]["submissionCount"] == 1
    assert body["summary"]["evidenceCount"] == 1
    assert body["summary"]["eventCount"] >= 1
    assert body["summary"]["averageSteps"] == 0.5
    assert body["summary"]["coveredAgents"] == ["assessment"]
    assert body["summary"]["coveredTools"] == ["grade_exercise"]
    assert body["summary"]["averageMasteryDelta"] == 29
    assert body["summary"]["replanRate"] == 0
    assert body["summary"]["traceCompliant"] is True
    assert body["summary"]["traceComplianceViolations"] == []
    assert "userId" not in str(body)
    assert body["traces"][0]["recordId"] == "record-0001"


def test_model_adapters_require_structured_json_and_fallback_without_model():
    assert FallbackAdapter().decide({})["step"] == "diagnosis"
    assert QwenAdapter(lambda _state: '{"step":"planner"}').decide({})["step"] == "planner"

    with pytest.raises(ModelAdapterError, match="invalid JSON"):
        QwenAdapter(lambda _state: "not-json").decide({})
    with pytest.raises(ModelAdapterError, match="request failed"):
        QwenAdapter(lambda _state: (_ for _ in ()).throw(RuntimeError("network"))).complete({})


def test_qwen_adapter_without_key_is_explicitly_unavailable(monkeypatch):
    # Keep the variable present but empty so python-dotenv does not reload the local .env.
    monkeypatch.setenv("DASHSCOPE_API_KEY", "")

    assert QwenAdapter.from_environment() is None
    with pytest.raises(ModelAdapterError, match="API key"):
        QwenAdapter(api_key="").complete({})


def test_qwen_adapter_reads_explicit_configuration_without_exposing_secret(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "configured-key")
    monkeypatch.setenv("LLM_BASE_URL", "https://example.test/api/v1")
    monkeypatch.setenv("LLM_MODEL", "qwen-vl-plus")
    # 显式空值可阻止 python-dotenv 把开发机 `.env` 的值重新注入。
    monkeypatch.setenv("LLM_DECISION_MODEL", "")

    adapter = QwenAdapter.from_environment()

    assert adapter is not None
    assert adapter.base_url == "https://example.test/api/v1"
    assert adapter.model == "qwen-vl-plus"

    # 聊天层可继续使用 VL 模型，工作流决策层单独走纯文本模型。
    monkeypatch.setenv("LLM_DECISION_MODEL", "qwen-plus")
    decision_adapter = QwenAdapter.from_environment()

    assert decision_adapter is not None
    assert decision_adapter.model == "qwen-plus"


def test_runtime_falls_back_when_model_adapter_fails_without_state_corruption():
    session = WorkflowSession("session-fallback", "完成复习", max_steps=1)
    state = {}

    result = run_workflow(session, lambda: state, lambda step, _state: {"step": step},
        model_decider=QwenAdapter(lambda _state: "invalid-json").decide)

    assert result.current_step == "max_steps"
    assert result.status == "error"
    assert result.state.get("step") == "diagnosis"


def test_exercise_api_rejects_non_positive_count(tmp_path):
    client = create_app(tmp_path / "api.json").test_client()

    response = client.get("/api/v1/exercises/set-demo-data-structures-001?count=0")

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "BAD_REQUEST"


def test_exercise_refresh_excludes_previous_three_questions(tmp_path):
    client = create_app(tmp_path / "exercise-refresh.json").test_client()
    first = client.get(
        "/api/v1/exercises/set-demo-binary-tree-001"
        "?knowledgePointId=binary-tree-postorder&count=3"
    ).get_json()["exercises"]
    query = "&".join(f"excludeExerciseId={item['exerciseId']}" for item in first)
    refreshed = client.get(
        "/api/v1/exercises/set-demo-binary-tree-001"
        f"?knowledgePointId=binary-tree-postorder&count=3&{query}"
    ).get_json()["exercises"]

    assert len(refreshed) == 3
    assert {item["exerciseId"] for item in first}.isdisjoint(
        {item["exerciseId"] for item in refreshed})


def test_missing_api_resource_uses_contract_error_shape(tmp_path):
    response = create_app(tmp_path / "api.json").test_client().get("/api/v1/profile/missing")

    assert response.status_code == 404
    assert response.get_json()["errorCode"] == "NOT_FOUND"
    assert "message" in response.get_json()


def test_submit_exercises_scores_and_is_idempotent(tmp_path):
    client = create_app(tmp_path / "api.json").test_client()
    client.post("/api/v1/demo/reset")
    payload = {"idempotencyKey": "submit-001", "answers": [
        {"exerciseId": "exercise-preorder-001", "answer": "A"},
        {"exerciseId": "exercise-inorder-001", "answer": "B"},
        {"exerciseId": "exercise-postorder-001", "answer": "A"},
    ]}

    first = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)
    second = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)

    assert first.status_code == 200
    assert first.get_json() == second.get_json()
    assert first.get_json()["assessment"]["score"] == 66.67
    trace = client.get("/api/v1/traces/trace-submit-submit-001")
    assert trace.status_code == 200
    assert trace.get_json()["events"][0]["agent"] == "assessment"


def test_submit_updates_profile_and_replans(tmp_path):
    client = create_app(tmp_path / "api.json").test_client()
    payload = {"idempotencyKey": "submit-001", "answers": [
        {"exerciseId": "exercise-preorder-001", "answer": "A"},
        {"exerciseId": "exercise-inorder-001", "answer": "B"},
        {"exerciseId": "exercise-postorder-001", "answer": "A"},
    ]}

    response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json=payload)
    profile = client.get("/api/v1/profile/demo-user").get_json()
    plan = client.get("/api/v1/plans/current").get_json()
    diff = client.get("/api/v1/plans/plan-demo-001/diff").get_json()

    assert response.get_json()["masteryUpdate"] == {
        "knowledgePointId": "binary-tree-postorder", "oldScore": 42, "newScore": 58}
    assert profile["profileVersion"] == 2
    assert profile["mastery"][0]["masteryScore"] == 58
    assert len(profile["history"]) == 1
    assert len(profile["evidence"]) == 1
    assert plan["version"] == 2
    assert diff["oldVersion"] == 1
    assert diff["newVersion"] == 2
    assert diff["changedTasks"][0]["durationMinutes"] == 45
    assert diff["changedTasks"][1]["durationMinutes"] == 15


def test_workflow_creates_and_returns_persisted_status(tmp_path):
    client = create_app(tmp_path / "api.json").test_client()
    client.post("/api/v1/demo/reset")

    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"})
    assert created.status_code == 200
    body = created.get_json()
    assert body["status"] == "running"
    assert body["currentStep"] == "exercise"

    status = client.get(f"/api/v1/workflows/{body['sessionId']}")
    assert status.status_code == 200
    assert status.get_json() == {"status": "running", "currentAgent": "exercise",
        "stateVersion": 1, "finalAction": None}


def test_workflow_run_integrates_exercise_assessment_and_trace(tmp_path):
    client = create_app(tmp_path / "workflow-run.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"}).get_json()

    waiting = client.post(f"/api/v1/workflows/{created['sessionId']}/run")
    assert waiting.status_code == 200
    assert waiting.get_json()["currentStep"] == "exercise"
    assert waiting.get_json()["status"] == "running"

    completed = client.post(f"/api/v1/workflows/{created['sessionId']}/run", json={
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "C"},
        ]
    })
    assert completed.status_code == 200
    assert completed.get_json()["status"] == "completed"
    assert completed.get_json()["currentStep"] == "finish"
    trace = client.get(f"/api/v1/traces/{created['traceId']}").get_json()
    assert [event["agent"] for event in trace["events"]] == ["exercise", "assessment", "secretary"]


def test_workflow_assessment_persists_mastery_evidence_and_replanned_plan(tmp_path):
    client = create_app(tmp_path / "workflow-persistence.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"}).get_json()

    client.post(f"/api/v1/workflows/{created['sessionId']}/run")
    completed = client.post(f"/api/v1/workflows/{created['sessionId']}/run", json={
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"},
        ]
    })

    assert completed.get_json()["status"] == "completed"
    profile = client.get("/api/v1/profile/demo-user").get_json()
    plan = client.get("/api/v1/plans/current").get_json()

    assert profile["mastery"][0]["masteryScore"] == 58
    assert len(profile["evidence"]) == 1
    assert plan["version"] == 2


def test_workflow_creation_with_existing_session_id_resumes_without_reset(tmp_path):
    client = create_app(tmp_path / "workflow-resume.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成复习"}).get_json()
    client.post(f"/api/v1/workflows/{created['sessionId']}/run")

    resumed = client.post("/api/v1/workflows", json={
        "goal": "不同的重复目标", "sessionId": created["sessionId"], "maxSteps": 1,
    }).get_json()

    assert resumed["sessionId"] == created["sessionId"]
    assert resumed["currentStep"] == "exercise"
    assert resumed["traceId"] == created["traceId"]


def test_workflow_requires_goal(tmp_path):
    response = create_app(tmp_path / "api.json").test_client().post("/api/v1/workflows", json={})

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "BAD_REQUEST"


def test_workflow_rejects_invalid_max_steps_without_persisting_state(tmp_path):
    client = create_app(tmp_path / "workflow-validation.json").test_client()

    for value in (0, 21, "2", True):
        response = client.post("/api/v1/workflows", json={"goal": "完成复习", "maxSteps": value})
        assert response.status_code == 400
        assert response.get_json()["errorCode"] == "BAD_REQUEST"


def test_priority_engine_uses_all_five_factors_and_ranks_weak_point_first():
    priorities = calculate_learning_priority([
        {"knowledgePointId": "binary-tree", "masteryScore": 42, "errorIntensity": 80,
         "importance": 90, "prerequisiteImpact": 70},
        {"knowledgePointId": "graph", "masteryScore": 80, "errorIntensity": 10,
         "importance": 60, "prerequisiteImpact": 10},
    ], {"daysLeft": 7})

    assert priorities[0]["knowledgePointId"] == "binary-tree"
    assert set(priorities[0]["factors"]) == {
        "mastery", "errorIntensity", "importance", "urgency", "prerequisiteImpact"}
    assert priorities[0]["totalScore"] > priorities[1]["totalScore"]


def test_priority_engine_normalizes_factors_and_is_deterministic():
    knowledge_points = [{"knowledgePointId": "tree", "masteryScore": 0,
        "errorIntensity": 100, "importance": 100, "urgency": 100,
        "prerequisiteImpact": 100}]

    first = calculate_learning_priority(knowledge_points, {"daysLeft": 0})[0]
    second = calculate_learning_priority(knowledge_points, {"daysLeft": 0})[0]

    assert first == second
    assert sum(factor["weight"] for factor in first["factors"].values()) == pytest.approx(1.0)
    assert all(0 <= factor["value"] <= 1 for factor in first["factors"].values())
    assert sum(factor["contribution"] for factor in first["factors"].values()) == pytest.approx(
        first["score"], abs=1e-6)
    assert first["factors"]["mastery"]["value"] == 1.0

    zero_mastery = calculate_learning_priority(
        [{"knowledgePointId": "tree", "masteryScore": 100}], {"daysLeft": 30})[0]
    assert zero_mastery["factors"]["mastery"]["value"] == 0.0


def test_replan_rule_increases_weak_task_and_reduces_other_pending_task():
    plan = {"planId": "plan-001", "version": 1, "tasks": [
        {"knowledgePointId": "binary-tree", "durationMinutes": 30, "status": "pending"},
        {"knowledgePointId": "graph", "durationMinutes": 30, "status": "pending"},
    ]}

    decision = should_replan({"masteryScore": 58, "repeatedError": True})
    result = replan_learning_path(plan, {"masteryScore": 58, "knowledgePointId": "binary-tree",
        "repeatedError": True})

    assert decision["needReplan"] is True
    assert result["plan"]["version"] == 2
    assert result["plan"]["tasks"] == [
        {"knowledgePointId": "binary-tree", "durationMinutes": 45, "status": "pending"},
        {"knowledgePointId": "graph", "durationMinutes": 15, "status": "pending"},
    ]


def test_replan_rule_does_not_repeat_high_mastery_topic():
    decision = should_replan({"masteryScore": 78, "repeatedError": False, "incompleteTasks": 0})

    assert decision == {"needReplan": False, "reasons": []}


def test_plan_diff_api_uses_contract_field_names(tmp_path):
    client = create_app(tmp_path / "plan-diff.json").test_client()
    client.post("/api/v1/demo/reset")
    client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
        "idempotencyKey": "plan-diff-contract",
        "answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"}],
    })

    diff = client.get("/api/v1/plans/plan-demo-001/diff").get_json()

    # 本测试的意图是**校验契约字段名**（见函数名），不是固化文案。
    # 文案在 2026-09-23 更新过：原先固定写「掌握度低于阈值」，但重规划的时长
    # 分配其实是**按本次得分分级**的（得分越低，薄弱点任务分到越多）。
    # 由前端同学实测发现"不管错多少都是 [45,15]"，修好后文案也如实说明依据。
    # 契约对 adjustmentReason 只要求是 string，故这里放宽为"说明得分依据"。
    assert diff["adjustmentReason"].startswith("按本次得分")
    assert "66.67" in diff["adjustmentReason"]
    assert diff["triggerEvidence"]
    assert "reason" not in diff


def test_completed_empty_modules_provide_deterministic_helpers(tmp_path):
    assert is_mastery_below_threshold(58)
    assert mastery_band(80) == "mastered"
    assert select_courses([{"courseId": "c1", "knowledgePointId": "tree"}], "tree") == [
        {"courseId": "c1", "knowledgePointId": "tree"}]
    profile = {"userId": "u1", "goal": "review", "profileVersion": 2,
        "mastery": [{"knowledgePointId": "tree", "masteryScore": 58}]}
    assert get_mastery(profile, "tree") == 58
    assert profile_summary(profile)["profileVersion"] == 2

    repository = SQLiteRepository(tmp_path / "repository.sqlite")
    repository.save("profiles", "u1", profile)
    assert repository.get("profiles", "u1") == profile
    assert repository.list("profiles") == [profile]
    repository.delete("profiles", "u1")
    assert repository.get("profiles", "u1") is None


def test_select_exercises_filters_and_deduplicates():
    exercises = [
        {"exerciseId": "a", "knowledgePointId": "graph", "difficulty": "easy"},
        {"exerciseId": "a", "knowledgePointId": "graph", "difficulty": "easy"},
        {"exerciseId": "b", "knowledgePointId": "graph", "difficulty": "medium"},
    ]

    assert [item["exerciseId"] for item in select_exercises(exercises, "graph", "easy", 3)] == ["a"]


def test_tool_registry_executes_registered_tool_for_allowed_agent():
    registry = ToolRegistry()
    registry.register("double", {"type": "object"}, lambda value: value * 2, {"exercise"})

    assert registry.execute("double", "exercise", {"value": 21}) == 42
    assert registry.get("double").schema == {"type": "object"}


def test_tool_registry_rejects_unknown_and_forbidden_calls():
    registry = ToolRegistry()
    registry.register("double", {}, lambda value: value * 2, {"exercise"})

    with pytest.raises(ToolError, match="cannot call"):
        registry.execute("double", "secretary", {"value": 21})
    with pytest.raises(ToolError, match="unknown tool"):
        registry.execute("missing", "exercise", {})


def test_tool_registry_rejects_duplicate_registration():
    registry = ToolRegistry()
    registry.register("double", {}, lambda value: value * 2, {"exercise"})

    with pytest.raises(ValueError, match="already registered"):
        registry.register("double", {}, lambda value: value * 3, {"exercise"})


def test_default_tool_registry_exposes_deterministic_tools_and_wraps_failures():
    registry = create_default_registry()

    assert {tool.name for tool in registry.list()} >= {
        "calculate_learning_priority", "select_exercises", "grade_exercise", "update_mastery",
        "should_replan", "replan_learning_path"}
    with pytest.raises(ToolError) as error:
        registry.execute("update_mastery", "assessment", {"old_score": 101, "assessment_score": 80})
    assert error.value.code == "TOOL_FAILED"


def test_workflow_fallback_selects_steps_from_observable_state():
    assert fallback_decision({}).step == "diagnosis"
    assert fallback_decision({"profile": {}, "plan": None}).step == "planner"
    assert fallback_decision({"profile": {}, "plan": {}, "pendingSubmission": True}).step == "assessment"
    assert fallback_decision({"profile": {}, "plan": {}, "assessment": {}, "needReplan": True}).step == "planner"
    assert decide_next_step({}, lambda _state: {"invalid": True}).used_fallback is True
    assert decide_next_step({"profile": {}, "plan": {}},
        lambda _state: {"step": "planner"}).step == "exercise"


def test_workflow_loop_writes_back_versions_and_stops_at_max_steps():
    session = WorkflowSession("session-001", "完成复习", max_steps=2)
    state = {}
    steps = []

    def observe():
        return state

    def act(step, _observed):
        steps.append(step)
        state["profile"] = {}
        if step == "planner":
            state["plan"] = {}
        return {"step": step}

    result = run_workflow(session, observe, act)

    assert steps == ["diagnosis", "planner"]
    assert result.status == "error"
    assert result.current_step == "max_steps"
    assert result.state_version == 4
    assert WorkflowSession.from_dict(result.to_dict()).to_dict() == result.to_dict()


def test_five_agents_return_structured_outputs_with_separate_responsibilities():
    assert SecretaryAgent().run({"profile": {}, "plan": None}).output["nextStep"] == "planner"
    diagnosis = DiagnosisAgent().run({"evidence": [{"knowledgePointId": "tree", "errorType": "order"}]})
    assert diagnosis.output["weakPoints"][0]["knowledgePointId"] == "tree"
    planner = PlannerAgent().run({"knowledgePoints": [{"knowledgePointId": "tree", "masteryScore": 42}]})
    assert planner.tool_calls == ("calculate_learning_priority",)
    exercise = ExerciseAgent().run({"exercises": [{"exerciseId": "e1", "knowledgePointId": "tree"}]})
    assert exercise.output["exercises"][0]["exerciseId"] == "e1"
    assessment = AssessmentAgent().run({"answers": [{"exerciseId": "e1", "answer": "A"}],
        "answerKeys": {"e1": "A"}, "knowledgePointsByExercise": {"e1": "tree"}, "oldMastery": 42})
    assert assessment.output["suggestedNewMastery"] == 71
    assert assessment.tool_calls == ("grade_exercise", "update_mastery")
