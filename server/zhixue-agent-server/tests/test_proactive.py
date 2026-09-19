from app.agent.proactive import proactive_decision


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
