"""Per-user wrong-question book with deterministic three-correct removal."""
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
from app.api.validation import json_object
from app.repositories.json_repository import JsonRepository


wrong_book_api = Blueprint("wrong_book", __name__)
_repository: JsonRepository | None = None


def configure_wrong_book_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _key(user_id: str, exercise_id: str) -> str:
	return f"{user_id}:{exercise_id}"


def _all_questions(user_id: str) -> list[dict]:
	from app.api.exercises import _EXERCISE_BANK
	items = list(_EXERCISE_BANK)
	if _repository:
		# 现场生成题带 userId，不能让甲账号用猜到的 exerciseId 读取乙账号题目。
		items.extend(item for item in _repository.list("exercises")
			if isinstance(item, dict) and item.get("userId", "demo-user") == user_id)
	return items


def _question(exercise_id: str, user_id: str) -> dict | None:
	return next((item for item in _all_questions(user_id) if item.get("exerciseId") == exercise_id), None)


def _course_for(user_id: str, question: dict) -> str:
	point_id = str(question.get("knowledgePointId") or "")
	profile = _repository.get("profiles", user_id) if _repository else None
	if isinstance(profile, dict):
		for row in profile.get("mastery", []):
			if isinstance(row, dict) and row.get("knowledgePointId") == point_id:
				course = str(row.get("sourceCourse") or "").strip()
				if course:
					return course
	if point_id.startswith(("binary-tree", "graph-", "algorithm-", "recursion-")):
		return "数据结构"
	return str(question.get("courseName") or question.get("knowledgePointName") or "其他").strip() or "其他"


def _public(record: dict) -> dict:
	return {key: value for key, value in record.items() if key != "answerKey"}


def add_item(repository, user_id: str, question: dict, automatic: bool = False) -> dict:
	exercise_id = str(question.get("exerciseId") or "")
	existing = repository.get("wrong_book", _key(user_id, exercise_id)) or {}
	record = {
		"userId": user_id,
		"exerciseId": exercise_id,
		"courseName": existing.get("courseName") or _course_for(user_id, question),
		"knowledgePointId": question.get("knowledgePointId", ""),
		"knowledgePointName": question.get("knowledgePointName", ""),
		"difficulty": question.get("difficulty", "medium"),
		"stem": question.get("stem", ""),
		"options": question.get("options", []),
		"answerKey": question.get("answerKey", ""),
		"explanation": question.get("explanation") or f"正确答案是 {question.get('answerKey', '')}。请结合题干与选项重新核对概念。",
		"correctCount": int(existing.get("correctCount", 0)),
		"wrongCount": int(existing.get("wrongCount", 0)) + (1 if automatic else 0),
		"addedAutomatically": bool(existing.get("addedAutomatically", automatic)),
		"addedAt": existing.get("addedAt") or datetime.now(timezone.utc).isoformat(),
		"lastPracticedAt": existing.get("lastPracticedAt"),
	}
	repository.save("wrong_book", _key(user_id, exercise_id), record)
	return record


def record_submission(repository, user_id: str, questions: list[dict], submitted: dict[str, str],
					  correct_ids: set[str]) -> None:
	for question in questions:
		exercise_id = str(question.get("exerciseId") or "")
		if exercise_id not in submitted:
			continue
		key = _key(user_id, exercise_id)
		existing = repository.get("wrong_book", key)
		if exercise_id not in correct_ids:
			add_item(repository, user_id, question, automatic=True)
		elif existing is not None:
			correct_count = int(existing.get("correctCount", 0)) + 1
			if correct_count >= 3:
				repository.delete("wrong_book", key)
			else:
				existing["correctCount"] = correct_count
				existing["lastPracticedAt"] = datetime.now(timezone.utc).isoformat()
				repository.save("wrong_book", key, existing)


@wrong_book_api.get("/api/v1/wrong-book")
def list_wrong_book():
	user_id = resolve_user_id(request.args.get("userId"))
	items = [_public(item) for item in (_repository.list("wrong_book") if _repository else [])
		if isinstance(item, dict) and item.get("userId") == user_id]
	items.sort(key=lambda item: (str(item.get("courseName")), str(item.get("addedAt"))), reverse=True)
	courses: dict[str, list[dict]] = {}
	for item in items:
		courses.setdefault(str(item.get("courseName") or "其他"), []).append(item)
	return jsonify({"userId": user_id, "total": len(items),
		"courses": [{"courseName": name, "items": rows} for name, rows in courses.items()]})


@wrong_book_api.post("/api/v1/wrong-book/<exercise_id>")
def toggle_wrong_book(exercise_id: str):
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(data.get("userId"))
	added = data.get("added")
	if not isinstance(added, bool):
		return jsonify({"errorCode": "BAD_REQUEST", "message": "added must be boolean", "details": None}), 400
	key = _key(user_id, exercise_id)
	if not added:
		if _repository:
			_repository.delete("wrong_book", key)
		return jsonify({"exerciseId": exercise_id, "added": False, "removed": True})
	question = _question(exercise_id, user_id)
	if question is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise not found", "details": None}), 404
	record = add_item(_repository, user_id, question) if _repository else {}
	return jsonify({"exerciseId": exercise_id, "added": True, "removed": False,
		"item": _public(record)})


@wrong_book_api.post("/api/v1/wrong-book/<exercise_id>/attempt")
def practice_wrong_book(exercise_id: str):
	data, guard = json_object()
	if guard is not None:
		return guard
	user_id = resolve_user_id(data.get("userId"))
	record = _repository.get("wrong_book", _key(user_id, exercise_id)) if _repository else None
	if record is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "wrong-book item not found", "details": None}), 404
	answer = str(data.get("answer") or "").strip().upper()
	correct = answer == str(record.get("answerKey") or "").upper()
	removed = False
	if correct:
		record["correctCount"] = int(record.get("correctCount", 0)) + 1
		if record["correctCount"] >= 3:
			_repository.delete("wrong_book", _key(user_id, exercise_id))
			removed = True
		else:
			record["lastPracticedAt"] = datetime.now(timezone.utc).isoformat()
			_repository.save("wrong_book", _key(user_id, exercise_id), record)
	else:
		record["wrongCount"] = int(record.get("wrongCount", 0)) + 1
		record["lastPracticedAt"] = datetime.now(timezone.utc).isoformat()
		_repository.save("wrong_book", _key(user_id, exercise_id), record)
	return jsonify({"exerciseId": exercise_id, "correct": correct,
		"correctAnswer": record.get("answerKey", ""), "explanation": record.get("explanation", ""),
		"correctCount": int(record.get("correctCount", 0)), "removed": removed})
