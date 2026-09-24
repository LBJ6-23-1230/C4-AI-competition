from app.agent.proactive import proactive_decision
from app import create_app


def test_proactive_recommends_focus_for_urgent_gap():
    result = proactive_decision(
        {
            "userId": "demo-user",
            "context": {
                "now": "2026-09-16T21:10:00+08:00",
                "location": "library",
                "foreground": False,
                "lastStudyAt": "2026-09-14T20:30:00+08:00",
                "focusSessionActive": False,
                "masteryScore": 58,
                "errorIntensity": 67,
                "daysLeft": 5,
                "importance": 90,
            },
        }
    )

    assert result["shouldNotify"] is True
    assert result["channel"] == "reminder"
    assert result["action"]["type"] == "focus"
    assert result["action"]["label"] == "开始 45 分钟专注"
    assert result["action"]["preset"]["taskId"] == "task-postorder"
    assert result["action"]["preset"]["durationMinutes"] == 45
    assert "reason" in result and "factors" in result
    assert "exam_within_7d" in result["contextTags"]
    assert "exam_within_7d_low_mastery" in result["contextTags"]
    assert result["cardData"]["knowledgePointId"] == "binary-tree-postorder"


def test_proactive_avoids_notification_while_focus_session_active():
    result = proactive_decision(
        {
            "userId": "demo-user",
            "context": {
                "now": "2026-09-16T21:10:00+08:00",
                "location": "library",
                "foreground": False,
                "lastStudyAt": "2026-09-15T20:30:00+08:00",
                "focusSessionActive": True,
                "masteryScore": 58,
                "errorIntensity": 67,
                "daysLeft": 5,
                "importance": 90,
            },
        }
    )
    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"


def test_proactive_is_deterministic_for_same_input():
    context = {
        "now": "2026-09-16T21:10:00+08:00",
        "location": "library",
        "foreground": False,
        "lastStudyAt": "2026-09-14T20:30:00+08:00",
        "focusSessionActive": False,
        "masteryScore": 58,
        "errorIntensity": 67,
        "daysLeft": 5,
        "importance": 90,
    }
    first = proactive_decision({"userId": "demo-user", "context": context})
    second = proactive_decision({"userId": "demo-user", "context": context})
    assert first == second


def test_proactive_sends_no_alert_when_user_is_healthy():
    result = proactive_decision(
        {
            "userId": "demo-user",
            "context": {
                "now": "2026-09-16T21:10:00+08:00",
                "location": "library",
                "foreground": False,
                "lastStudyAt": "2026-09-16T20:30:00+08:00",
                "focusSessionActive": False,
                "masteryScore": 90,
                "errorIntensity": 10,
                "daysLeft": 30,
                "importance": 50,
            },
        }
    )
    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"


def test_proactive_handles_missing_profile_context_gracefully():
    result = proactive_decision({"userId": "demo-user", "context": {"now": "2026-09-16T21:10:00+08:00"}})
    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"


def test_proactive_uses_location_tag_when_present():
    result = proactive_decision(
        {
            "userId": "demo-user",
            "context": {
                "now": "2026-09-16T21:10:00+08:00",
                "location": "library",
                "foreground": False,
                "lastStudyAt": "2026-09-14T20:30:00+08:00",
                "focusSessionActive": False,
                "masteryScore": 58,
                "errorIntensity": 67,
                "daysLeft": 4,
                "importance": 90,
            },
        }
    )
    assert "location_library" in result["contextTags"]


def test_proactive_notifies_for_pending_ddl_within_two_days():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00",
        "pendingTasks": [{"taskId": "task-1", "status": "pending", "daysLeft": 2}],
    }})

    assert result["shouldNotify"] is True
    assert "pending_ddl_within_2d" in result["contextTags"]


def test_pending_ddl_uses_task_identity_and_context_days_left():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00",
        "daysLeft": 2,
        "pendingTasks": [{
            "taskId": "task-graph-review",
            "title": "图算法复习",
            "status": "pending",
            "started": False,
        }],
    }})

    assert result["shouldNotify"] is True
    assert result["action"]["preset"]["taskId"] == "task-graph-review"
    assert result["action"]["preset"]["title"] == "图算法复习"
    assert result["cardData"]["taskName"] == "图算法复习"
    assert result["title"] == "待办「图算法复习」即将截止"
    assert "图算法复习" in result["body"]


def test_pending_ddl_ignores_completed_tasks_and_picks_most_urgent():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00",
        "pendingTasks": [
            {"taskId": "done", "status": "completed", "daysLeft": 1},
            {"taskId": "later", "status": "pending", "daysLeft": 2},
            {"taskId": "soon", "title": "最短截止任务", "status": "pending", "daysLeft": 1},
        ],
    }})

    assert result["shouldNotify"] is True
    assert result["action"]["preset"]["taskId"] == "soon"
    assert result["cardData"]["taskName"] == "最短截止任务"


def test_pending_ddl_picks_earliest_task_with_stable_tie_break():
    result = proactive_decision({"context": {
        "pendingTasks": [
            {"taskId": "later", "title": "较晚任务", "status": "pending", "daysLeft": 2},
            {"taskId": "tie-first", "title": "同截止先出现", "status": "pending", "daysLeft": 1},
            {"taskId": "tie-second", "title": "同截止后出现", "status": "pending", "daysLeft": 1},
        ],
    }})

    assert result["action"]["preset"]["taskId"] == "tie-first"


def test_pending_ddl_ignores_started_tasks():
    result = proactive_decision({"context": {
        "pendingTasks": [{
            "taskId": "started",
            "title": "已经开始的任务",
            "status": "pending",
            "started": True,
            "daysLeft": 1,
        }],
    }})

    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"


def test_pending_ddl_absent_or_malformed_is_safe():
    for pending_tasks in (None, "not-an-array", [None, 1, "invalid"]):
        context = {} if pending_tasks is None else {"pendingTasks": pending_tasks}
        result = proactive_decision({"context": context})
        assert result["shouldNotify"] is False
        assert result["channel"] == "silent"


def test_proactive_notifies_after_two_days_without_study():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00",
        "lastStudyAt": "2026-09-14T20:30:00+08:00",
    }})

    assert result["shouldNotify"] is True
    assert "no_study_for_2d" in result["contextTags"]


def test_proactive_does_not_notify_for_started_ddl_or_healthy_exam_context():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00",
        "pendingTasks": [{"taskId": "task-1", "status": "in_progress", "daysLeft": 1}],
        "masteryScore": 80,
        "daysLeft": 5,
        "lastStudyAt": "2026-09-16T20:30:00+08:00",
    }})

    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"


def test_proactive_notifies_for_exam_with_mastery_below_80():
    result = proactive_decision({"context": {
        "now": "2026-09-16T21:10:00+08:00", "daysLeft": 7, "masteryScore": 79,
        "lastStudyAt": "2026-09-16T20:30:00+08:00",
    }})

    assert result["shouldNotify"] is True
    assert "exam_within_7d_low_mastery" in result["contextTags"]


def test_proactive_never_returns_actionable_notification_when_suppressed():
    result = proactive_decision({"context": {"daysLeft": 2, "masteryScore": 20, "foreground": True}})

    assert result["shouldNotify"] is False
    assert result["channel"] == "silent"
    assert result["action"]["type"] == "none"


def test_proactive_api_accepts_pending_tasks_and_rejects_invalid_shapes(tmp_path):
    client = create_app(tmp_path / "proactive-api.json").test_client()
    valid = client.post("/api/v1/agent/proactive", json={
        "userId": "demo-user",
        "context": {
            "foreground": False,
            "pendingTasks": [{
                "taskId": "task-1",
                "title": "高数作业",
                "status": "pending",
                "daysLeft": 2,
            }],
        },
    })
    invalid = client.post("/api/v1/agent/proactive", json={
        "context": {"pendingTasks": ["not-an-object"]},
    })

    assert valid.status_code == 200
    assert valid.get_json()["shouldNotify"] is True
    assert valid.get_json()["action"]["preset"]["taskId"] == "task-1"
    assert invalid.status_code == 400
    assert invalid.get_json()["errorCode"] == "BAD_REQUEST"


def test_proactive_rejects_malformed_pending_tasks(tmp_path):
    client = create_app(tmp_path / "proactive-invalid.json").test_client()

    for pending_tasks in ("not-an-array", {"title": "not-an-array"}, [1], [None]):
        response = client.post("/api/v1/agent/proactive", json={
            "context": {"pendingTasks": pending_tasks},
        })
        assert response.status_code == 400
        assert response.get_json()["errorCode"] == "BAD_REQUEST"
