from app import create_app
from app.agent import chat_llm
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
		"candidates": [{
			"userId": "candidate-1",
			"basicInfo": {"name": "候选同学", "grade": "大二", "major": "计算机科学与技术"},
			"learningGoal": {"course": "数据结构", "goal": "期末80+"},
			"time": {"freeTime": ["21:00-23:00"]},
			"knowledge": {"weakness": ["递归理解"], "strength": ["图算法"]},
		}],
	})

	body = response.get_json()
	assert response.status_code == 200
	assert body["realModeUnavailable"] is False
	assert body["matchedCandidate"]["candidate"]["userId"] == "candidate-1"
	assert body["matchedCandidate"]["factors"]["overlapMinutes"] == 120


def test_real_accounts_replace_demo_people_when_available(tmp_path):
	client = create_app(tmp_path / "partner-real-accounts.json").test_client()
	created = client.post("/api/v1/auth/register", json={
		"nickname": "真实测试同学", "grade": "大二", "phone": "13800138001",
		"seedDemoData": False,
	})
	assert created.status_code == 201

	response = client.post("/api/v1/agent/partner-match", json={"user": {
		"userId": "demo-user",
		"basicInfo": {"grade": "大二", "major": "计算机科学与技术"},
	}})
	body = response.get_json()

	assert response.status_code == 200
	assert body["candidateSources"] == {"accounts": 1, "demo": 0}
	assert body["candidates"][0]["candidate"]["basicInfo"]["name"] == "真实测试同学"


def test_target_course_comes_from_imported_courses(tmp_path, monkeypatch):
	"""导入课程后「主攻课程」必须真的进 `learningGoal.course` —— 否则目标一致因子恒为 0。

	回归的是什么：`_real_candidates` / `_real_user_profile` 里 course 原先**硬编码为空串**，
	而 `score_partner` 的两个分档（30 / 20）**都先要求 course 非空** ——
	结果两个课表重合的账号与一个从未导入课程的账号得分完全相同（实测都是 15 分），
	同分排序下还可能选中那个陌生人。
	"""
	monkeypatch.delenv('DASHSCOPE_API_KEY', raising=False)   # 走规则表，课程来源确定
	client = create_app(tmp_path / "partner-target-course.json").test_client()

	def register(nick, phone):
		return client.post("/api/v1/auth/register", json={
			"nickname": nick, "grade": "大三", "phone": phone,
			"seedDemoData": False}).get_json()

	甲 = register("甲同学", "13800138201")
	乙 = register("乙同学", "13800138202")
	丙 = register("丙同学没课表", "13800138203")

	for 人, courses in [(甲, ["数据结构", "操作系统"]), (乙, ["数据结构", "计算机网络"])]:
		headers = {"Authorization": f"Bearer {人['token']}"}
		client.post(f"/api/v1/profile/{人['user']['userId']}/knowledge-points",
			json={"courses": courses}, headers=headers)

	headers = {"Authorization": f"Bearer {甲['token']}"}
	body = client.post("/api/v1/agent/partner-match", json={}, headers=headers).get_json()
	by_name = {item["candidate"]["basicInfo"]["name"]: item for item in body["candidates"]}

	# 两人都以「数据结构」为知识点贡献最多的课程 → course 相同 → 该因子拿到 20 分
	assert by_name["乙同学"]["candidate"]["learningGoal"]["course"] == "数据结构"
	assert by_name["乙同学"]["factors"]["goal"] == 20
	# 丙没导入过任何课程 → course 为空 → 仍为 0，如实反映"没说过要主攻什么"
	assert by_name["丙同学没课表"]["candidate"]["learningGoal"]["course"] == ""
	assert by_name["丙同学没课表"]["factors"]["goal"] == 0
	# 关键结论：课表重合的乙必须**严格高于**毫不相干的丙
	assert by_name["乙同学"]["score"] > by_name["丙同学没课表"]["score"]


def test_online_match_never_falls_back_to_demo_candidates(tmp_path):
	client = create_app(tmp_path / "partner-no-demo-fallback.json").test_client()

	response = client.post("/api/v1/agent/partner-match", json={"user": {
		"userId": "demo-user", "basicInfo": {"grade": "大二"},
	}})
	body = response.get_json()

	assert response.status_code == 200
	assert body["candidateSources"] == {"accounts": 0, "demo": 0}
	assert body["matchedCandidate"] is None
	assert body["candidates"] == []


def test_chat_and_detail_page_share_same_real_account_winner(tmp_path):
	client = create_app(tmp_path / "partner-shared-ranking.json").test_client()
	alice = client.post("/api/v1/auth/register", json={
		"nickname": "甲", "grade": "大二", "phone": "13800138101", "seedDemoData": False,
	}).get_json()
	client.post("/api/v1/auth/register", json={
		"nickname": "低年级候选", "grade": "大一", "phone": "13800138102", "seedDemoData": False,
	})
	best = client.post("/api/v1/auth/register", json={
		"nickname": "同年级最高分", "grade": "大二", "phone": "13800138103", "seedDemoData": False,
	}).get_json()
	headers = {"Authorization": f"Bearer {alice['token']}"}

	detail = client.post("/api/v1/agent/partner-match", json={}, headers=headers).get_json()
	chat_rank = chat_llm._authoritative_partner_scores({}, alice["user"]["userId"])

	assert detail["matchedCandidate"]["candidate"]["userId"] == best["user"]["userId"]
	assert chat_rank["matchedCandidate"]["userId"] == best["user"]["userId"]
	assert chat_rank["matchedCandidate"]["score"] == detail["matchedCandidate"]["score"]
	assert all(item["name"] not in {"小红", "小刚"} for item in chat_rank["全部候选人排名"])


def test_chat_response_cannot_be_overridden_by_llm_fixture_name(monkeypatch):
	authoritative = {
		"matchedCandidate": {"userId": "real-1", "name": "1", "score": 45},
		"总分": 45,
		"分项得分": {"goal": 0, "timeOverlap": 30, "knowledgeComplement": 0,
			"basicMatch": 10, "stability": 5},
		"全部候选人排名": [
			{"userId": "real-1", "name": "1", "score": 45},
			{"userId": "real-2", "name": "2", "score": 20},
		],
	}
	monkeypatch.setattr(chat_llm, "_authoritative_partner_scores",
		lambda _data, _user_id: authoritative)
	monkeypatch.setattr(chat_llm, "_call_llm",
		lambda *_args, **_kwargs: "小红是你的最佳学习搭子，总分10分。")

	result = chat_llm._handle_match_partner("帮我匹配一个学习搭子", {}, "real-user")

	assert result.startswith("1 是当前匹配分最高的学习搭子（总分 45/100）")
	assert "小红" not in result
	assert "总分10" not in result


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
