from datetime import datetime, timezone
import json
import threading
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
from app.agent import exercise_gen
from app.tools.exercise_tools import _CLIENT_FIELDS, select_exercises
from app.tools.plan_tools import create_plan_history


exercises_api = Blueprint("exercises", __name__)
DEMO_EXERCISE_SET_ID = "set-demo-binary-tree-001"
EXERCISE_SET_IDS = {DEMO_EXERCISE_SET_ID, "set-demo-data-structures-001"}
_repository: JsonRepository | None = None

# 提交接口的"幂等检查 → 判分 → 掌握度回写 → 落盘"必须**整体原子**。
#
# 原实现是典型的 check-then-act：先读 `submissions` 判断幂等键是否已存在，
# 中间隔着判分与 `persist_mastery`（两者都在改画像），最后才写 `submissions`。
# 并发下多个请求会同时通过幂等检查，于是掌握度增量被叠加多次并**永久写错**。
# 实测：6 个并发同 idempotencyKey 提交同一份全对答案 →
#   响应体出现 2 种、mastery 被加到 100（正确值 71）、
#   profileVersion=3、history 2 条。
#
# 这里用一把进程内锁把整段串行化。同一进程内的提交本来就不需要并行
# （判分是纯计算，微秒级），串行化的吞吐代价可忽略，换来的是幂等语义真正成立。
_SUBMIT_LOCK = threading.RLock()

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
	{"exerciseId": "exercise-postorder-002", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "easy", "stem": "后序遍历中，根节点通常在什么时候被访问？",
	 "options": ["A. 最先", "B. 左子树之后、右子树之前", "C. 左右子树都访问后", "D. 任意时刻"], "source": "demo"},
	{"exerciseId": "exercise-postorder-003", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "表达式树用后序遍历得到的结果最接近哪种表达式？",
	 "options": ["A. 前缀表达式", "B. 中缀表达式", "C. 后缀表达式", "D. 自然语言"], "source": "demo"},
	{"exerciseId": "exercise-postorder-004", "knowledgePointId": "binary-tree-postorder",
	 "knowledgePointName": "二叉树后序遍历", "difficulty": "medium", "stem": "递归实现后序遍历时，输出当前节点应放在哪一步？",
	 "options": ["A. 递归左子树前", "B. 递归左右子树之间", "C. 递归左右子树后", "D. 只在叶节点执行"], "source": "demo"},
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


def _merged_grading_tables() -> tuple[dict, dict]:
	"""判分用的两张表：`exerciseId → answerKey` 与 `exerciseId → knowledgePointId`。

	题库是常量；**模型现场出的题**存在 repository 的 `exercises` 集合里
	（判分发生在另一次请求，必须能把那批题找回来）。

	⚠️ 判分逻辑本身**一行没改** —— 仍然是 `grade_exercise` 按 `answerKey`
	逐题比对。这里只是让"被判分的题"多了"刚生成的那几道"，
	所以"判分是算式、不是模型觉得"这条纪律完好无损。
	"""
	answer_keys = dict(_ANSWER_KEYS)
	knowledge_points = {item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK}
	if _repository:
		for record in _repository.list("exercises"):
			if not isinstance(record, dict):
				continue
			exercise_id = record.get("exerciseId")
			if not isinstance(exercise_id, str) or not exercise_id:
				continue
			if record.get("answerKey"):
				answer_keys[exercise_id] = record["answerKey"]
			knowledge_points[exercise_id] = record.get("knowledgePointId", "")
	return answer_keys, knowledge_points


def _generate_and_store(knowledge_point_name: str, count: int) -> list[dict]:
	"""让模型针对该知识点出题；**含答案**的版本存仓库，返回可下发的题面（不含答案）。"""
	items = exercise_gen.generate_exercises(knowledge_point_name, count)
	if not items:
		return []
	if _repository:
		owner = resolve_user_id(None)
		for item in items:
			_repository.save("exercises", item["exerciseId"], dict(item, userId=owner))
	# 只下发题面字段：`answerKey` / `explanation` **绝不出后端**
	return [{key: item[key] for key in _CLIENT_FIELDS if key in item} for item in items]


def configure_exercises_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _resolve_knowledge_point_id(raw: str | None) -> str | None:
	"""把 `knowledgePointId` 参数**容错**成题库里真实存在的知识点 id。

	为什么需要：前端的错题诊断给出的是知识点**名字**（「图算法」「二叉树遍历」…），
	不是 id。若要求前端自己维护一份"名字 → id"的映射，就会有两处真源、必然漂移
	（题库改一个名字，前端就悄悄少出题）。题库就在本模块，在这里统一解析最稳。

	匹配顺序：精确 id → 精确名字 → 互相包含（「二叉树遍历」↔「二叉树遍历基础」）
	→ 共同二字前缀（「递归调用」↔「递归基础先修」）。
	**认不出就返回 None**（= 不加过滤）→ 走默认题集，
	而不是返回空列表把练习页整空 —— 宁可回落到默认题，也不要给一个打不开的页面。
	"""
	if raw is None:
		return None
	value = raw.strip()
	if not value:
		return None
	bank = list(_EXERCISE_BANK)
	for item in bank:
		if item.get("knowledgePointId") == value:
			return value
	for item in bank:
		if item.get("knowledgePointName") == value:
			return item.get("knowledgePointId")
	for item in bank:
		name = item.get("knowledgePointName") or ""
		if name and (value in name or name in value):
			return item.get("knowledgePointId")
	if len(value) >= 2:
		for item in bank:
			name = item.get("knowledgePointName") or ""
			if len(name) >= 2 and name[:2] == value[:2]:
				return item.get("knowledgePointId")
	return None


@exercises_api.get("/api/v1/exercises/<set_id>")
def get_exercise_set(set_id: str):
	if set_id not in EXERCISE_SET_IDS:
		return jsonify({"errorCode": "NOT_FOUND", "message": "exercise set not found", "details": {"setId": set_id}}), 404
	raw_point = (request.args.get("knowledgePointId") or "").strip()
	knowledge_point_id = _resolve_knowledge_point_id(raw_point)
	difficulty = request.args.get("difficulty")
	excluded_ids = request.args.getlist("excludeExerciseId")
	# 记录调用方**是否显式传了 count**。
	# 原缺陷：`count` 只被"解析并校验"，但无过滤条件时直接返回整份 `_DEMO_EXERCISES`，
	# count 被**静默忽略** —— `?count=1` 照样返回 3 道题（实测）。
	# 这是"参数接受了但不生效"，比不声明该参数更糟：调用方以为筛选生效了。
	# 只有显式传入时才截断，默认行为（演示基线 3 题）保持不变。
	count_explicit = request.args.get("count") is not None
	try:
		count = int(request.args.get("count", 3))
		if count < 1:
			raise ValueError
	except ValueError:
		return jsonify({"errorCode": "BAD_REQUEST", "message": "count must be an integer", "details": None}), 400
	# `generate=1` 才允许现场出题 —— **默认行为一个字节都不变**，
	# 演示基线那条路径（不带参数）永远不会触发模型调用。
	generate_requested = (request.args.get("generate") or "").strip().lower() in ("1", "true", "yes")
	# ⚠️ 这里必须用 **raw_point** 判"调用方到底有没有给筛选条件"。
	# 用解析后的 `knowledge_point_id` 会踩坑：知识点解析不出来时它是 None，
	# 于是 `has_filter` 为假 → 直接走演示分支返回那 3 道题，
	# **后面的出题分支永远不可达**（实测过一次：0.0s 返回演示题，压根没调模型）。
	has_filter = bool(raw_point or difficulty or excluded_ids)
	if set_id == DEMO_EXERCISE_SET_ID and not has_filter:
		exercises = _DEMO_EXERCISES[:count] if count_explicit else _DEMO_EXERCISES
	else:
		exercises = []
		# 题库覆盖不到这个知识点（固定题库只有 6 个知识点）→ 允许时让模型现场出题。
		# 这正是"每个人薄弱的知识点不一样，要有针对性的题目"那个短板的解法：
		# 覆盖面从 6 个知识点扩到**任意**知识点。
		# 判定依据是 `knowledge_point_id is None`（解析不出 = 题库里没有），
		# 而不是"select 返回空" —— 后者在无过滤时会返回题库前 N 题，永远不为空。
		if raw_point and knowledge_point_id is None and generate_requested:
			exercises = _generate_and_store(raw_point, count)
		if not exercises:
			exercises = select_exercises(_EXERCISE_BANK, knowledge_point_id, difficulty, count, excluded_ids)
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
	# ⚠️ 整段"幂等检查 → 判分 → 掌握度回写 → 落盘"必须持锁串行执行。
	# 详见 `_SUBMIT_LOCK` 的注释：不加锁时并发重复提交会让掌握度增量叠加多次。
	# 把原逻辑收进内部函数再持锁调用（而不是整段缩进一层），
	# 是为了让这次改动的 diff 只落在两行上，便于复核。
	def _do_submit():
		if _repository:
			previous = _repository.get("submissions", result_id)
			if previous is not None:
				return jsonify(previous["response"])

		profile = _repository.get("profiles", user_id) if _repository else None
		if profile is None:
			return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
		profile_model = LearnerProfile.from_dict(profile)
		# 判分表 = 题库常量 + 生成题（见 `_merged_grading_tables`）
		answer_keys, knowledge_points = _merged_grading_tables()

		# ⚠️ `old_mastery` 必须取自**本次作答覆盖的那个知识点**，不能写死
		# `binary-tree-postorder`。
		#
		# 原缺陷：`old_mastery` 固定取二叉树那条（否则 42），而判分按每题真实
		# knowledgePointId 归集，响应的 `masteryUpdate.knowledgePointId` 也被硬编码 ——
		# 于是提交其它知识点题集时，返回的"掌握度提升"落不到画像上、
		# 真正的薄弱点永远不被记录、重规划也按错的知识点触发。
		# 实测：提交 graph-algorithm 题集，响应称 binary-tree-postorder 42→46，
		# 而画像里该知识点仍是 42。
		#
		# 先按"题面知识点"取一次初值给判分用；判分完成后用 dominant_knowledge_point()
		# 精确定位主知识点，再校正响应字段（见下）。
		covered_points = {knowledge_points.get(str(a.get("exerciseId")), "")
						  for a in answers if isinstance(a, dict)}
		covered_points.discard("")
		lead_point = sorted(covered_points)[0] if covered_points else "binary-tree-postorder"
		old_mastery = 42
		for mastery in profile_model.mastery:
			if mastery.knowledge_point_id == lead_point:
				old_mastery = mastery.mastery_score

		assessment = grade_exercise(answers, answer_keys, knowledge_points, old_mastery, result_id)
		score = assessment.score
		new_mastery = assessment.suggested_new_mastery
		# 本次提交真正主要练的知识点（按被判分题量，并列取字典序）
		report_point = assessment.dominant_knowledge_point()
		if report_point == "unknown":
			report_point = lead_point
		# 该知识点自己的新旧分值（供响应与重规划使用）
		report_old = old_mastery
		report_new = assessment.per_knowledge_mastery.get(report_point, new_mastery)
		response = {
			"userId": user_id,
			"submissionId": result_id,
			"assessment": assessment.to_dict(),
			"masteryUpdate": {"knowledgePointId": report_point, "oldScore": report_old,
				"newScore": report_new},
			"needReplan": False,
		}
		response["replanDecision"] = should_replan({"masteryScore": report_new,
			"knowledgePointId": report_point, "repeatedError": score < 80})
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
						replan_result = replan_learning_path(plan, {"masteryScore": report_new,
							"knowledgePointId": report_point, "repeatedError": score < 80,
							# 传得分才能按错误程度分级加时；不传则回退到固定 ±15
							"assessmentScore": score})
						updated_plan = replan_result["plan"]
						updated_tasks = updated_plan["tasks"]
						new_plan = LearningPlan(plan["planId"], updated_plan["version"], updated_tasks,
							profile_model_dict["profileVersion"], "根据练习结果重规划")
						_repository.save("plans", new_plan.plan_id, new_plan.to_dict())
						history = create_plan_history(plan, new_plan.to_dict(),
                            "按本次得分 %.2f 重分配时间：薄弱点加时、其余任务减时" % score,
                            [evidence_id])
						history.update({"planId": new_plan.plan_id,
							"adjustmentReason": history["reason"],
							"triggerEvidence": history["evidenceIds"]})
						_repository.save("plan_histories",
							f"{new_plan.plan_id}:v{history['newVersion']}", history)
						response["plan"] = new_plan.to_dict()
						response["planDiff"] = {"planId": new_plan.plan_id, **history}
			trace = {"traceId": trace_id, "userId": user_id, "events": [{"agent": "assessment", "toolCalls": ["grade_exercise"],
				"inputSummary": f"提交题集 {set_id}", "outputSummary": f"得分 {score}",
				"evidenceIds": [evidence_id], "stateVersion": 1, "timestamp": timestamp.isoformat(),
				"status": "completed", "sessionId": data.get("sessionId"), "stepId": "step-1",
				"inputStateVersion": 1, "outputStateVersion": 1}]}
			_repository.save("traces", trace_id, trace)
			_repository.save("submissions", result_id, {"response": response})
		return jsonify(response)

	with _SUBMIT_LOCK:
		return _do_submit()
