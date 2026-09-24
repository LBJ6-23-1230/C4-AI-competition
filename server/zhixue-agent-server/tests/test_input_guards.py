# -*- coding: utf-8 -*-
"""输入护栏与鉴权边界回归测试。

每一条都对应一次真实探测中复现出的 HTTP 500 或越权行为，
不是为了覆盖率而写的测试。
"""

from app import create_app


# ----------------------------------------------------------------- 非对象 JSON body
def test_non_object_json_body_is_rejected_with_400(tmp_path):
    """非对象 JSON 必须返回 400，不能是 500。

    原先 4 个入口都是 `request.get_json(silent=True) or {}`，但只有
    `api/proactive.py` 做了 isinstance 检查。发 `[1,2,3]` / `"hello"` /
    `123` / `true` 时 `data.get(...)` 抛 AttributeError → 500。
    """
    client = create_app(tmp_path / "guard-body.json").test_client()

    for raw in ('[1,2,3]', '"hello"', '123', 'true', 'null'):
        for path in ("/api/v1/workflows",
                     "/api/v1/exercises/set-demo-binary-tree-001/submit",
                     "/api/v1/agent/partner-match"):
            response = client.post(path, data=raw, content_type="application/json")
            assert response.status_code == 400, f"{path} + {raw} → {response.status_code}"
            assert response.get_json()["errorCode"] == "BAD_REQUEST"


def test_missing_or_empty_body_is_still_accepted(tmp_path):
    """没有请求体 / 空对象必须照常放行。

    回归背景：给 `json_object()` 加护栏时一度把"无 body"也判成 400，
    结果打挂了既有测试 `test_workflow_run_integrates_exercise_assessment_and_trace`
    —— `POST /api/v1/workflows/<id>/run` 不传答案（只推进到等待态）是**正常用法**。
    护栏只应拦住"有 body 但不是对象"。
    """
    client = create_app(tmp_path / "guard-empty.json").test_client()
    client.post("/api/v1/demo/reset")
    created = client.post("/api/v1/workflows", json={"goal": "空 body 探测"}).get_json()

    # 完全不传 body
    no_body = client.post(f"/api/v1/workflows/{created['sessionId']}/run")
    assert no_body.status_code == 200

    # 传空对象
    empty = client.post(f"/api/v1/workflows/{created['sessionId']}/run", json={})
    assert empty.status_code == 200


def test_workflow_run_rejects_non_object_body(tmp_path):
    client = create_app(tmp_path / "guard-run.json").test_client()
    for raw in ('[1,2,3]', '"hello"', '123'):
        response = client.post("/api/v1/workflows/whatever/run",
                               data=raw, content_type="application/json")
        assert response.status_code == 400


# ----------------------------------------------------------------- answers 元素类型
def test_submit_rejects_non_object_answer_elements(tmp_path):
    """`answers` 的元素不是对象时必须 400。

    原先只校验 `isinstance(answers, list)`，不校验元素。
    传 `["a"]` / `[1]` / `[None]` 会一路深入到判分逻辑才炸成 500。
    注意：`/run` 端点当时已有该护栏，但 `/submit` 没有 —— 这正是
    "护栏只加在一处"的教训，故此处单独锁住。
    """
    client = create_app(tmp_path / "guard-elements.json").test_client()
    client.post("/api/v1/demo/reset")

    for answers in (["a"], [1], [None], [[]]):
        response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                               json={"idempotencyKey": "k", "userId": "demo-user",
                                     "answers": answers})
        assert response.status_code == 400, f"answers={answers} → {response.status_code}"


def test_autorun_path_shares_the_same_answers_guard(tmp_path):
    """`autoRun` 分支会绕过 `/run` 端点，必须做同样的校验。

    护栏只写在 `run_workflow_api()` 里时，`POST /workflows {autoRun:true, answers:[...]}`
    会直接进 `_run_saved_workflow`，绕过整段校验。
    """
    client = create_app(tmp_path / "guard-autorun.json").test_client()
    client.post("/api/v1/demo/reset")

    response = client.post("/api/v1/workflows", json={
        "goal": "旁路探测", "autoRun": True, "answers": [1, 2, 3]})

    assert response.status_code == 400
    assert response.get_json()["errorCode"] == "BAD_REQUEST"


# ----------------------------------------------------------------- 字段长度上限
def test_oversized_idempotency_key_is_rejected(tmp_path):
    """超长 idempotencyKey 必须被拒。

    它会成为 repository 的键并落盘；实测 20 万字符的 key 让
    repository.json 从 31,927 字节涨到 2,826,331 字节（每次 save 全量重写）。
    """
    client = create_app(tmp_path / "guard-keylen.json").test_client()
    client.post("/api/v1/demo/reset")

    response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit",
                           json={"idempotencyKey": "K" * 200000, "userId": "demo-user",
                                 "answers": []})

    assert response.status_code == 400
    assert response.get_json()["details"]["field"] == "idempotencyKey"


def test_oversized_goal_and_session_id_are_rejected(tmp_path):
    client = create_app(tmp_path / "guard-goallen.json").test_client()

    too_long_goal = client.post("/api/v1/workflows", json={"goal": "G" * 5000})
    assert too_long_goal.status_code == 400
    assert too_long_goal.get_json()["details"]["field"] == "goal"

    too_long_session = client.post("/api/v1/workflows",
                                   json={"goal": "ok", "sessionId": "S" * 5000})
    assert too_long_session.status_code == 400
    assert too_long_session.get_json()["details"]["field"] == "sessionId"


# ----------------------------------------------------------------- 鉴权状态保护
def test_demo_reset_does_not_invalidate_auth_sessions(tmp_path):
    """`demo/reset` 不得清 `sessions`。

    回归背景（这条是本项目修过的最严重的一处）：
    `demo/reset` **无需任何凭据**即可调用。曾有中间版本把 `sessions`
    （`auth/service.py` 的鉴权会话表）一起清掉，后果是：
      * 任何匿名请求都能让**全部已登录用户立刻掉线**
      * 且 `register` 只签发新 userId，旧画像/计划成为孤儿，
        原凭据**永久无法再登录**

    所以这里同时锁两件事：重置后 token 仍有效，且演示基线仍被正确重置。
    """
    client = create_app(tmp_path / "guard-sessions.json").test_client()

    registered = client.post("/api/v1/auth/register",
                             json={"nickname": "会话保持", "grade": "大二",
                                   "phone": "13800009999"}).get_json()
    token = registered["token"]
    headers = {"Authorization": f"Bearer {token}"}

    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200

    assert client.post("/api/v1/demo/reset").status_code == 200

    # 1) 会话不能被清掉
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200, \
        "demo/reset 不得让已登录用户掉线"
    # 2) 演示基线仍被正确重置
    profile = client.get("/api/v1/profile/demo-user").get_json()
    assert profile["profileVersion"] == 1
    assert profile["mastery"][0]["masteryScore"] == 42
    plan = client.get("/api/v1/plans/current").get_json()
    assert plan["version"] == 1
    assert [task["durationMinutes"] for task in plan["tasks"]] == [30, 30]


# ----------------------------------------------------------------- 嵌套字段类型
def test_partner_match_tolerates_malformed_nested_fields(tmp_path):
    """`user` 的**嵌套**字段类型错误不得导致 500。

    HTTP 层只校验 `user` 本身是对象，不校验嵌套字段。原先
    `learningGoal` / `knowledge` / `time` / `basicInfo` 收到字符串/数组/数字时
    `xxx.get(...)` 抛 AttributeError → 500（实测这 4 类稳定复现）。

    注意 `value or {}` 这种写法**挡不住**字符串和数字（非空字符串是 truthy），
    必须用 `isinstance` 判断。
    """
    client = create_app(tmp_path / "guard-nested.json").test_client()

    malformed = [
        {"learningGoal": "x"}, {"learningGoal": [1, 2]}, {"learningGoal": 1},
        {"knowledge": "x"}, {"time": "x"}, {"time": 123},
        {"basicInfo": 1}, {"time": {"freeTime": "abc"}}, {"time": {"freeTime": [1, 2, 3]}},
        {},
    ]
    for user in malformed:
        response = client.post("/api/v1/agent/partner-match", json={"user": user})
        assert response.status_code < 500, f"user={user} → {response.status_code}"


def test_partner_match_still_scores_correctly(tmp_path):
    """加完类型护栏后，正常匹配结果必须不变（防"修坏"）。"""
    client = create_app(tmp_path / "guard-scoring.json").test_client()

    response = client.post("/api/v1/agent/partner-match", json={"user": {
        "userId": "demo-user",
        "learningGoal": {"course": "数据结构", "goal": "期末80+"},
        "time": {"freeTime": ["21:00-23:00"]},
        "knowledge": {"weakness": ["图算法"], "strength": ["递归理解"]},
        "basicInfo": {"grade": "大二", "major": "计算机科学与技术"},
    }})

    assert response.status_code == 200
    body = response.get_json()
    assert body["realModeUnavailable"] is False
    assert body["matchedCandidate"]["candidate"]["userId"] == "u002"
    assert body["matchedCandidate"]["factors"]["overlapMinutes"] == 120


def test_proactive_rejects_non_finite_numbers(tmp_path):
    """`inf` / `nan` 必须回退到默认值，不能冒泡成 500。

    `float("Infinity")` 能成功转换，但下游 `int(days_left)` 抛 OverflowError、
    `f"{score:.0f}"` 抛 ValueError，两者都是 500。
    JSON 不允许 Infinity 字面量，但字符串可以，且 `1e400` 在 Python 里就解析成 inf。
    """
    client = create_app(tmp_path / "guard-nonfinite.json").test_client()

    contexts = [
        {"daysLeft": "Infinity", "foreground": False, "focusSessionActive": False},
        {"daysLeft": "NaN", "foreground": False, "focusSessionActive": False},
        {"daysLeft": 1e400, "foreground": False, "focusSessionActive": False},
        {"masteryScore": "inf", "foreground": False, "focusSessionActive": False},
        {"masteryScore": "nan", "foreground": False, "focusSessionActive": False},
        {"importance": "Infinity", "foreground": False, "focusSessionActive": False},
        {"errorIntensity": "NaN", "foreground": False, "focusSessionActive": False},
        {"pendingTasks": [{"daysLeft": "Inf", "started": False}],
         "foreground": False, "focusSessionActive": False},
    ]
    for context in contexts:
        response = client.post("/api/v1/agent/proactive",
                               json={"userId": "demo-user", "context": context})
        assert response.status_code == 200, f"context={context} → {response.status_code}"
        assert isinstance(response.get_json()["shouldNotify"], bool)
