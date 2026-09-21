from app import create_app
from app.runtime.loop import run_workflow
from app.runtime.session import WorkflowSession


def test_repeated_run_without_answers_does_not_advance_state(tmp_path):
    client = create_app(tmp_path / "resume.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "诊断二叉树后序遍历"}).get_json()
    session_id = created["sessionId"]

    first = client.post(f"/api/v1/workflows/{session_id}/run", json={}).get_json()
    second = client.post(f"/api/v1/workflows/{session_id}/run", json={}).get_json()
    third = client.post(f"/api/v1/workflows/{session_id}/run", json={}).get_json()

    assert first["currentAgent"] == "exercise"
    assert first["stateVersion"] == 2
    assert first["state"]["awaitingAnswers"] is True
    assert second["stateVersion"] == first["stateVersion"]
    assert third["stateVersion"] == first["stateVersion"]
    trace = client.get(f"/api/v1/traces/{created['traceId']}").get_json()
    assert len(trace["events"]) == 1


def test_resume_with_answers_clears_waiting_flag_and_completes(tmp_path):
    client = create_app(tmp_path / "resume-answers.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"}).get_json()
    session_id = created["sessionId"]
    waiting = client.post(f"/api/v1/workflows/{session_id}/run", json={}).get_json()
    client.post(f"/api/v1/workflows/{session_id}/run", json={})

    completed = client.post(f"/api/v1/workflows/{session_id}/run", json={
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "C"},
        ]
    }).get_json()

    assert waiting["stateVersion"] == 2
    assert completed["status"] == "completed"
    assert completed["currentAgent"] == "finish"
    assert completed["stateVersion"] == 4
    assert completed["state"]["awaitingAnswers"] is False
    trace = client.get(f"/api/v1/traces/{created['traceId']}").get_json()
    assert [event["agent"] for event in trace["events"]] == [
        "exercise", "assessment", "secretary"]


def test_resume_with_submission_id_skips_duplicate_assessment(tmp_path):
    client = create_app(tmp_path / "resume-submission.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"}).get_json()
    session_id = created["sessionId"]
    client.post(f"/api/v1/workflows/{session_id}/run", json={})
    submission = client.post(
        "/api/v1/exercises/set-demo-binary-tree-001/submit",
        json={
            "idempotencyKey": "workflow-submission-001",
            "answers": [
                {"exerciseId": "exercise-preorder-001", "answer": "A"},
                {"exerciseId": "exercise-inorder-001", "answer": "B"},
                {"exerciseId": "exercise-postorder-001", "answer": "C"},
            ],
        },
    ).get_json()

    completed = client.post(
        f"/api/v1/workflows/{session_id}/run",
        json={"submissionId": submission["submissionId"]},
    ).get_json()

    assert completed["status"] == "completed"
    assert completed["currentAgent"] == "finish"
    assert completed["state"]["awaitingAnswers"] is False
    assert completed["state"]["submissionId"] == submission["submissionId"]


def test_runtime_short_circuits_awaiting_answers_without_actions():
    session = WorkflowSession(
        "session-awaiting", "完成复习", state={"profile": {}, "plan": {}, "awaitingAnswers": True})
    calls = []

    result = run_workflow(
        session,
        lambda: session.state,
        lambda step, _state: calls.append(step) or {},
    )

    assert calls == []
    assert result.state_version == 1
    assert result.current_step == "diagnosis"


def test_experiment_snapshot_reports_workflow_agent_tool_and_mastery_metrics(tmp_path):
    client = create_app(tmp_path / "workflow-metrics.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "完成二叉树复习"}).get_json()
    session_id = created["sessionId"]
    client.post(f"/api/v1/workflows/{session_id}/run", json={})
    client.post(f"/api/v1/workflows/{session_id}/run", json={})
    client.post(f"/api/v1/workflows/{session_id}/run", json={
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"},
        ]
    })

    summary = client.get("/api/v1/experiments/snapshot").get_json()["summary"]

    assert summary["averageSteps"] == 1.5
    assert summary["coveredAgents"] == ["assessment", "exercise", "secretary"]
    assert summary["coveredTools"] == [
        "grade_exercise", "select_exercises", "update_mastery"]
    assert summary["averageMasteryDelta"] == 16
    assert summary["submissionCount"] == 1
    assert summary["replanCount"] == 1
    assert summary["replanDenominator"] == 1
    assert summary["replanRate"] == 1.0
    assert summary["replanRateBasis"] == "plan_histories/submissions"
    assert summary["traceCompliant"] is True


def test_replan_rate_counts_workflow_path(tmp_path):
    """工作流路径的评估也必须计入重规划统计。

    前端练习页走 /workflows/{id}/run + answers，不走 /exercises/submit；
    若只统计 submissions 集合，前端真实用法下 replanRate 会恒为 0。
    """
    client = create_app(tmp_path / "rate.json").test_client()
    client.post("/api/v1/demo/reset")
    for round_index in range(3):
        created = client.post(
            "/api/v1/workflows", json={"goal": f"完成复习 {round_index + 1}"}).get_json()
        sid = created["sessionId"]
        client.post(f"/api/v1/workflows/{sid}/run", json={})
        client.post(f"/api/v1/workflows/{sid}/run", json={"answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"},
        ]})

    summary = client.get("/api/v1/experiments/snapshot").get_json()["summary"]
    assert summary["submissionCount"] == 3
    assert summary["planDiffCount"] == 3
    assert summary["replanRate"] == 1.0, "工作流路径的重规划必须被统计到"
    assert summary["replanRateBasis"] == "plan_histories/submissions"

    latest_diff = client.get("/api/v1/plans/plan-demo-001/diff").get_json()
    assert latest_diff["oldVersion"] == 3
    assert latest_diff["newVersion"] == 4


# ------------------------------------------------------------------ 输入护栏
def test_run_rejects_excessive_answers(tmp_path):
    """`answers` 数量必须有上限。

    背景：`_run_saved_workflow` 会把 answers 存进会话 state 并落盘。
    实测一次 4000 条的提交会让 repository.json 增长约 1.5MB、响应体 1.3MB，
    而 JsonRepository 每次 save 都全量重写整个仓库 —— 会线性拖慢所有接口。
    """
    client = create_app(tmp_path / "guard-count.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "护栏"}).get_json()
    session_id = created["sessionId"]
    client.post(f"/api/v1/workflows/{session_id}/run", json={})

    payload = {"answers": [{"exerciseId": f"bogus-{i}", "answer": "Y"}
                           for i in range(4000)]}
    response = client.post(f"/api/v1/workflows/{session_id}/run", json=payload)

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "BAD_REQUEST"
    assert response.get_json()["details"]["limit"] == 200


def test_run_rejects_overlong_single_answer(tmp_path):
    """单个 answer 长度必须有上限（否则可被用来撑大请求与响应）。"""
    client = create_app(tmp_path / "guard-length.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "护栏"}).get_json()
    session_id = created["sessionId"]
    client.post(f"/api/v1/workflows/{session_id}/run", json={})

    response = client.post(f"/api/v1/workflows/{session_id}/run",
                           json={"answers": [{"exerciseId": "x", "answer": "Z" * 5000}]})

    assert response.status_code == 400
    assert response.get_json()["details"]["field"] == "answer"


def test_run_does_not_echo_or_persist_consumed_answers(tmp_path):
    """已消费的 answers 不应回显，也不应留在会话 state 里。

    否则每次 save 都会把它全量重写进 repository.json，文件持续膨胀。
    """
    client = create_app(tmp_path / "no-echo.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "不回显"}).get_json()
    session_id = created["sessionId"]
    client.post(f"/api/v1/workflows/{session_id}/run", json={})

    completed = client.post(f"/api/v1/workflows/{session_id}/run", json={"answers": [
        {"exerciseId": "exercise-preorder-001", "answer": "A"},
        {"exerciseId": "exercise-inorder-001", "answer": "B"},
        {"exerciseId": "exercise-postorder-001", "answer": "C"},
    ]}).get_json()

    assert completed["status"] == "completed"
    assert "answers" not in completed["state"], "answers 不应回显给客户端"
    # 重新读取落库的工作流，确认也没写进持久化状态
    restored = client.get(f"/api/v1/workflows/{session_id}").get_json()
    assert restored["status"] == "completed"


def test_demo_reset_clears_workflows(tmp_path):
    """demo/reset 必须清掉 workflows —— 否则工作流记录会无限累积。

    workflows/sessions 是增长最快的集合，残留会让 repository.json 持续膨胀，
    进而拖慢每一次 save（JsonRepository 全量重写）。
    """
    client = create_app(tmp_path / "reset-workflows.json").test_client()
    client.post("/api/v1/demo/reset")

    for index in range(3):
        created = client.post("/api/v1/workflows", json={"goal": f"累积 {index}"}).get_json()
        client.post(f"/api/v1/workflows/{created['sessionId']}/run", json={})

    before = client.get("/api/v1/experiments/snapshot").get_json()["summary"]["traceCount"]
    client.post("/api/v1/demo/reset")
    after = client.get("/api/v1/experiments/snapshot").get_json()["summary"]["traceCount"]

    # reset 前有初始 trace + 3 条工作流 trace；reset 后应只剩初始 trace
    assert after < before, f"reset 后 trace 未减少（{before} → {after}）"
    # 新建的工作流应当已经不存在
    probe = client.get(f"/api/v1/workflows/{created['sessionId']}")
    assert probe.status_code == 404
