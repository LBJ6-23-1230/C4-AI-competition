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
	assert review == [{
		"exerciseId": "exercise-preorder-001", "selectedAnswer": "C",
		"correctAnswer": "A", "correct": False,
		"explanation": "正确答案是 A。请结合题干与选项重新核对概念。",
		"inWrongBook": True,
	}]

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
