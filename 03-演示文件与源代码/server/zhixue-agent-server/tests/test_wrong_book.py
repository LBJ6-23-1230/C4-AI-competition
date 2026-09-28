"""Wrong-book flow: review, auto-add, grouping, practice and removal."""
from app import create_app


def test_wrong_answer_is_reviewed_and_auto_added_by_course(tmp_path):
	client = create_app(tmp_path / "wrong-book.json").test_client()
	response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
		"idempotencyKey": "wrong-book-auto-add",
		"answers": [{"exerciseId": "exercise-preorder-001", "answer": "C"}],
	})
	assert response.status_code == 200
	review = response.get_json()["review"]
	assert len(review) == 1
	assert review[0]["exerciseId"] == "exercise-preorder-001"
	assert review[0]["selectedAnswer"] == "C"
	assert review[0]["correctAnswer"] == "A"
	assert review[0]["correct"] is False
	assert review[0]["inWrongBook"] is True
	assert review[0]["explanationSource"] == "fallback"
	# 即使测试环境没有配置模型，也不能再退回“请重新核对概念”的空泛占位文案。
	assert len(review[0]["explanation"]) >= 80
	assert "A. 根-左-右" in review[0]["explanation"]

	book = client.get("/api/v1/wrong-book").get_json()
	assert book["total"] == 1
	assert book["courses"][0]["courseName"] == "数据结构"
	item = book["courses"][0]["items"][0]
	assert item["exerciseId"] == "exercise-preorder-001"
	assert item["wrongCount"] == 1
	assert "answerKey" not in item


def test_three_correct_attempts_remove_item_and_manual_toggle_works(tmp_path):
	client = create_app(tmp_path / "wrong-book-practice.json").test_client()
	added = client.post("/api/v1/wrong-book/exercise-preorder-001", json={"added": True})
	assert added.status_code == 200
	assert added.get_json()["added"] is True

	for expected_count in (1, 2):
		attempt = client.post("/api/v1/wrong-book/exercise-preorder-001/attempt",
			json={"answer": "A"}).get_json()
		assert attempt["correct"] is True
		assert attempt["correctCount"] == expected_count
		assert attempt["removed"] is False
	third = client.post("/api/v1/wrong-book/exercise-preorder-001/attempt",
		json={"answer": "A"}).get_json()
	assert third["correctCount"] == 3
	assert third["removed"] is True
	assert client.get("/api/v1/wrong-book").get_json()["total"] == 0

	client.post("/api/v1/wrong-book/exercise-inorder-001", json={"added": True})
	removed = client.post("/api/v1/wrong-book/exercise-inorder-001", json={"added": False})
	assert removed.get_json() == {
		"exerciseId": "exercise-inorder-001", "added": False, "removed": True}
	assert client.get("/api/v1/wrong-book").get_json()["total"] == 0


def test_submission_uses_llm_detailed_review(monkeypatch, tmp_path):
	from app.agent import exercise_gen

	monkeypatch.setattr(exercise_gen, "generation_available", lambda: True)
	monkeypatch.setattr(exercise_gen.chat_llm, "_call_llm", lambda *_args, **_kwargs:
		'{"reviews":[{"exerciseId":"exercise-preorder-001",'
		'"explanation":"A 是前序遍历的根左右顺序；B 是后序，C 是中序，D 交换了左右子树。你选择 C，说明混淆了根节点访问时机；先看根在最前、中央还是最后即可快速判断。"}]}')
	client = create_app(tmp_path / "wrong-book-llm-review.json").test_client()
	response = client.post("/api/v1/exercises/set-demo-binary-tree-001/submit", json={
		"idempotencyKey": "llm-review",
		"answers": [{"exerciseId": "exercise-preorder-001", "answer": "C"}],
	})
	assert response.status_code == 200
	assert "B 是后序" in response.get_json()["review"][0]["explanation"]
	assert response.get_json()["review"][0]["explanationSource"] == "llm"
