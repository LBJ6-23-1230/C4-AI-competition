from app import create_app
from app.agent.partner_match import match_partners, score_partner


def test_partner_match_uses_deterministic_backend_scoring(tmp_path):
	client = create_app(tmp_path / "partner-match.json").test_client()
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


def test_partner_goal_factor_distinguishes_exact_and_course_overlap():
	user = {"learningGoal": {"course": "数据结构", "goal": "期末80+"}}
	exact = score_partner(user, {"learningGoal": {"course": "数据结构", "goal": "期末80+"}})
	same_course = score_partner(user, {"learningGoal": {"course": "数据结构", "goal": "通过考试"}})
	different = score_partner(user, {"learningGoal": {"course": "高等数学", "goal": "期末80+"}})

	assert exact["factors"]["goal"] == 30
	assert same_course["factors"]["goal"] == 20
	assert different["factors"]["goal"] == 0


def test_partner_time_overlap_factor_uses_documented_boundaries():
	user = {"time": {"freeTime": ["19:00-21:00"]}}
	cases = [
		(["19:00-21:00"], 120, 30),
		(["19:30-21:00"], 90, 20),
		(["20:30-21:00"], 30, 10),
		(["21:30-22:30"], 0, 0),
	]

	for free_time, expected_overlap, expected_score in cases:
		scored = score_partner(user, {"time": {"freeTime": free_time}})
		assert scored["factors"]["overlapMinutes"] == expected_overlap
		assert scored["factors"]["timeOverlap"] == expected_score


def test_partner_knowledge_complement_is_bidirectional():
	user = {
		"knowledge": {"weakness": ["图算法"], "strength": ["递归理解"]},
	}
	one_way = score_partner(user, {
		"knowledge": {"weakness": [], "strength": ["图算法"]},
	})
	two_way = score_partner(user, {
		"knowledge": {"weakness": ["递归理解"], "strength": ["图算法"]},
	})

	assert one_way["factors"]["knowledgeComplement"] == 10
	assert two_way["factors"]["knowledgeComplement"] == 20


def test_partner_basic_match_and_stability_factors_are_independent():
	user = {"basicInfo": {"grade": "大二", "major": "计算机科学与技术"}}
	same_all = score_partner(user, {
		"basicInfo": {"grade": "大二", "major": "计算机科学与技术"},
		"time": {"freeTime": ["19:00-20:00"]},
	})
	same_grade = score_partner(user, {
		"basicInfo": {"grade": "大二", "major": "软件工程"},
		"time": {"freeTime": ["19:00-20:00", "21:00-22:00"]},
	})
	no_basic_no_time = score_partner(user, {"basicInfo": {}, "time": {}})

	assert same_all["factors"]["basicMatch"] == 10
	assert same_all["factors"]["stability"] == 10
	assert same_grade["factors"]["basicMatch"] == 5
	assert same_grade["factors"]["stability"] == 5
	assert no_basic_no_time["factors"]["basicMatch"] == 0
	assert no_basic_no_time["factors"]["stability"] == 0


def test_partner_match_returns_null_instead_of_force_matching_zero_score():
	result = match_partners(
		{
			"userId": "u001",
			"learningGoal": {"course": "数据结构"},
			"time": {"freeTime": ["19:00-20:00"]},
			"knowledge": {"weakness": ["图算法"], "strength": []},
			"basicInfo": {"grade": "大二", "major": "计算机"},
		},
		[{
			"userId": "u999",
			"learningGoal": {"course": "高等数学"},
			"knowledge": {"weakness": [], "strength": []},
			"basicInfo": {"grade": "大一", "major": "物理"},
		}],
	)

	assert result["matchedCandidate"] is None
	assert result["candidates"][0]["score"] == 0
