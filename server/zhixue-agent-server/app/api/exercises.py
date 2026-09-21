from datetime import datetime, timezone
import json
from pathlib import Path

from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
from app.api.validation import (MAX_ID_CHARS, bounded_str, json_object, validate_answers)
from app.domain.evidence import Evidence, MasteryHistory
from app.domain.plan import LearningPlan
from app.domain.profile import LearnerProfile
from app.decision.replan_rules import replan_learning_path, should_replan
from app.repositories.json_repository import JsonRepository
from app.tools.assessment_tools import grade_exercise, persist_mastery
from app.tools.exercise_tools import select_exercises
from app.tools.plan_tools import create_plan_history


exercises_api = Blueprint("exercises", __name__)
DEMO_EXERCISE_SET_ID = "set-demo-binary-tree-001"
EXERCISE_SET_IDS = {DEMO_EXERCISE_SET_ID, "set-demo-data-structures-001"}
_repository: JsonRepository | None = None

_EXERCISE_BANK = [
	{"exerciseId": "exercise-preorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "easy", "stem": "以下哪项是给定二叉树的前序遍历结果？",
	 "options": ["A. 根-左-右", "B. 左-右-根", "C. 左-根-右", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-inorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "easy", "stem": "二叉树中序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	{"exerciseId": "exercise-postorder-001", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "二叉树后序遍历访问节点的顺序是什么？",
	 "options": ["A. 根-左-右", "B. 左-根-右", "C. 左-右-根", "D. 根-右-左"], "source": "demo"},
	*[
		{"exerciseId": f"exercise-bst-{number:03d}", "knowledgePointId": "binary-tree-search",
		 "knowledgePointName": "二叉搜索树", "difficulty": "medium" if number % 2 else "hard",
		 "stem": "二叉搜索树的中序遍历具有什么性质？", "options": ["A. 有序", "B. 逆序", "C. 随机", "D. 层序"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-graph-{number:03d}", "knowledgePointId": "graph-algorithm",
		 "knowledgePointName": "图算法", "difficulty": "easy" if number % 2 else "medium",
		 "stem": "BFS 通常使用哪种数据结构？", "options": ["A. 栈", "B. 队列", "C. 堆", "D. 集合"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-complexity-{number:03d}", "knowledgePointId": "algorithm-complexity",
		 "knowledgePointName": "算法复杂度先修", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "二分查找的时间复杂度是？", "options": ["A. O(1)", "B. O(log n)", "C. O(n)", "D. O(n^2)"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-traversal-{number:03d}", "knowledgePointId": "binary-tree-traversal",
		 "knowledgePointName": "二叉树遍历基础", "difficulty": "easy" if number < 3 else "medium",
		 "stem": "层序遍历通常按什么方向访问节点？", "options": ["A. 逐层", "B. 只访问叶子", "C. 只访问根", "D. 随机"], "source": "demo"}
		for number in range(1, 6)
	],
	*[
		{"exerciseId": f"exercise-prerequisite-{number:03d}", "knowledgePointId": "recursion-basics", "knowledgePointName": "递归基础先修",
		 "difficulty": "easy" if number % 2 else "medium", "stem": "递归函数必须具备什么？",
		 "options": ["A. 终止条件", "B. 全局变量", "C. 图结构", "D. 排序"], "source": "demo"}
		for number in range(1, 8)
	],
]

_QUESTION_BANK_PATH = Path(__file__).resolve().parents[2] / "data" / "question_bank.json"
if _QUESTION_BANK_PATH.exists():
	with _QUESTION_BANK_PATH.open("r", encoding="utf-8") as stream:
		_question_bank = json.load(stream).get("exercises", [])
	if len(_question_bank) >= 30 and len({item.get("exerciseId") for item in _question_bank}) == len(_question_bank):
		_EXERCISE_BANK = _question_bank

_DEMO_EXERCISES = select_exercises(_EXERCISE_BANK, "binary-tree-postorder", count=3)

_ANSWER_KEYS = {
	exercise["exerciseId"]: exercise["answerKey"]
	for exercise in _EXERCISE_BANK
	if exercise.get("answerKey")
}


def configure_exercises_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@exercises_api.get("/api/v1/exercises/<set_id>")
def get_exercise_set(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	knowledge_point_id = request.args.get("knowledgePointId")
	difficulty = request.args.get("difficulty")
	excluded_ids = request.args.getlist("excludeExerciseId")
	try:
		count = int(request.args.get("count", 3))
		if count < 1:
			raise ValueError
	except ValueError:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "count must be an integer", "details": None}), 400
	exercises = _DEMO_EXERCISES if set_id == DEMO_EXERCISE_SET_ID and not knowledge_point_id and not difficulty and not excluded_ids else select_exercises(
		_EXERCISE_BANK, knowledge_point_id, difficulty, count, excluded_ids)
	return jsonify({"setId": set_id, "exercises": exercises})


@exercises_api.post("/api/v1/exercises/<set_id>/submit")
def submit_exercises(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	data, guard = json_object()
	if guard is not None:
		return guard
	# 身份解析：已登录用登录身份（忽略请求体里的 userId，防冒用）；
	# 未登录时才用请求体/演示身份。修复"登录后掌握度仍写进 demo-user"的缺陷。
	user_id = resolve_user_id(data.get("userId"))
	idempotency_key, guard = bounded_str(data.get("idempotencyKey"), "idempotencyKey",
										MAX_ID_CHARS)
	if guard is not None:
		return guard
	# answers 必须逐项校验：缺了"元素必须是对象"这条时，传 ["a"] / [1] / [None]
	# 会一路深入到判分逻辑才炸成 500。
	answers, guard = validate_answers(data.get("answers"))
	if guard is not None:
		return guard

	result_id = f"{user_id}:{set_id}:{idempotency_key}"
	if _repository:
		previous = _repository.get("submissions", result_id)
		if previous is not None:
			return jsonify(previous["response"])

	profile = _repository.get("profiles", user_id) if _repository else None
	if profile is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
	old_mastery = 42
	profile_model = LearnerProfile.from_dict(profile)
	for mastery in profile_model.mastery:
		if mastery.knowledge_point_id == "binary-tree-postorder":
			old_mastery = mastery.mastery_score
	knowledge_points = {item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK}
	assessment = grade_exercise(answers, _ANSWER_KEYS, knowledge_points, old_mastery, result_id)
	score = assessment.score
	new_mastery = assessment.suggested_new_mastery
	response = {
		"userId": user_id,
		"submissionId": result_id,
		"assessment": assessment.to_dict(),
		"masteryUpdate": {"knowledgePointId": "binary-tree-postorder", "oldScore": old_mastery,
			"newScore": new_mastery},
		"needReplan": False,
	}
	response["replanDecision"] = should_replan({"masteryScore": new_mastery,
		"knowledgePointId": "binary-tree-postorder", "repeatedError": score < 80})
	response["needReplan"] = response["replanDecision"]["needReplan"]
	if _repository:
		trace_id = f"trace-submit-{idempotency_key}"
		evidence_id = f"evidence-submit-{idempotency_key}"
		response["traceId"] = trace_id
		response["evidenceIds"] = [evidence_id]
		timestamp = datetime.now(timezone.utc)
		profile_model_dict = persist_mastery(_repository, user_id, assessment,
				evidence_id, result_id, timestamp)
		if profile_model_dict:
			if response["needReplan"]:
				plans = [item for item in _repository.list("plans")
					if item.get("userId", "demo-user") == user_id]
				plan = next((item for item in plans if item.get("planId") == "plan-demo-001"), None)
				plan = plan or (plans[0] if plans else None)
				if plan is not None:
					replan_result = replan_learning_path(plan, {"masteryScore": new_mastery,
						"knowledgePointId": "binary-tree-postorder", "repeatedError": score < 80})
					updated_plan = replan_result["plan"]
					updated_tasks = updated_plan["tasks"]
					new_plan = LearningPlan(plan["planId"], updated_plan["version"], updated_tasks,
						profile_model_dict["profileVersion"], "根据练习结果重规划")
					_repository.save("plans", new_plan.plan_id, new_plan.to_dict())
					history = create_plan_history(plan, new_plan.to_dict(), "掌握度低于阈值", [evidence_id])
					history.update({"planId": new_plan.plan_id,
						"adjustmentReason": history["reason"],
						"triggerEvidence": history["evidenceIds"]})
					_repository.save("plan_histories",
						f"{new_plan.plan_id}:v{history['newVersion']}", history)
					response["plan"] = new_plan.to_dict()
					response["planDiff"] = {"planId": new_plan.plan_id, **history}
		trace = {"traceId": trace_id, "events": [{"agent": "assessment", "toolCalls": ["grade_exercise"],
			"inputSummary": f"提交题集 {set_id}", "outputSummary": f"得分 {score}",
			"evidenceIds": [evidence_id], "stateVersion": 1, "timestamp": timestamp.isoformat(),
			"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-1",
			"inputStateVersion": 1, "outputStateVersion": 1}]}
		_repository.save("traces", trace_id, trace)
		_repository.save("submissions", result_id, {"response": response})
	return jsonify(response)
