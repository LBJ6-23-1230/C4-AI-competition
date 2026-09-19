from app import create_app


def test_partner_match_uses_deterministic_backend_scoring():
	client = create_app().test_client()
	response = client.post("/api/v1/agent/partner-match", json={
		"user": {
			"userId": "demo-user", "learningGoal": {"course": "数据结构", "goal": "期末80+"},
			"time": {"freeTime": ["21:00-23:00"]},
			"knowledge": {"weakness": ["图算法"], "strength": ["递归理解"]},
			"basicInfo": {"grade": "大二", "major": "计算机科学与技术"},
		},
	})

	body = response.get_json()
	assert response.status_code == 200
	assert body["realModeUnavailable"] is False
	assert body["matchedCandidate"]["candidate"]["userId"] == "u002"
	assert body["matchedCandidate"]["factors"]["overlapMinutes"] == 120