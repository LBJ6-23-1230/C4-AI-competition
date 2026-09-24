import threading
import uuid
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from app.agents.assessment import AssessmentAgent
from app.agents.diagnosis import DiagnosisAgent
from app.agents.exercise import ExerciseAgent
from app.agents.planner import PlannerAgent
from app.agents.secretary import SecretaryAgent
from app.api.exercises import _ANSWER_KEYS, _EXERCISE_BANK
from app.api.identity import resolve_user_id
from app.api.validation import (MAX_ANSWERS, MAX_ANSWER_CHARS, MAX_ID_CHARS, MAX_TEXT_CHARS,
	bounded_str, json_object, validate_answers)
from app.decision.replan_rules import replan_learning_path, should_replan
from app.domain.assessment import AssessmentResult
from app.domain.profile import KnowledgeMastery, LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.model_adapters.qwen_adapter import QwenAdapter
from app.runtime.loop import run_workflow
from app.runtime.session import WorkflowSession
from app.tools.assessment_tools import persist_mastery
from app.tools.plan_tools import create_plan_history
from app.tools.trace_tools import append_trace_event

workflows_api = Blueprint("workflows", __name__)
_repository: JsonRepository | None = None

# 工作流推进必须**串行**：`_run_saved_workflow` 是"读会话 → 跑 Agent 循环
# → 按 `state.assessmentPersisted` 判断是否已记账 → 写 profile/history/plan
# → 写回会话"的一长串读—改—写，中间没有任何临界区。
# 并发推进同一会话时，多个请求会同时通过 `assessmentPersisted` 检查，
# 于是评估被重复记账。实测：6 次并发 run 同一 session →
# `profileVersion` 从 1 跳到 7、history 6 条且共用同一个 `evidence-<sessionId>`。
#
# 用可重入锁：`_run_saved_workflow` 也可能被其它已持锁的路径调用。
_WORKFLOW_RUN_LOCK = threading.RLock()


class SubmissionNotFound(KeyError):
	"""`submissionId` 不存在或不属于该工作流。

	单独定义类型的原因：原实现把它与"会话不存在"共用 `except KeyError` 分支，
	于是对**存在的** session 传错/过期 submissionId 时会返回
	404 `{"message": "workflow not found"}` —— 语义与事实不符（workflow 确实存在），
	客户端会误判为会话失效并重建会话，掩盖真实错误。
	"""


def configure_workflows_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _error(code: str, message: str, details: dict | None = None, status: int = 400):
	return jsonify({"errorCode": code, "message": message, "details": details}), status


def _next_step(user_id: str) -> tuple[str, str]:
	if _repository is None or _repository.get("profiles", user_id) is None:
		return "diagnosis", "开始学情诊断"
	# ⚠️ 判断"有没有计划"必须**只看这个用户自己的**。
	#
	# 原实现遍历全局 `plans`：只要**任何**别的用户存在计划，就会认定
	# "该用户已有计划"，直接跳到 exercise —— 他自己的计划永远不会被生成，
	# 后续 assessment 也就没有可重规划的对象。这正是"账号登录功能不对"的一类。
	# 归属口径与 `plans.py::get_current_plan` 保持一致（缺 `userId` 的老数据
	# 按 demo-user 归属，避免既有演示计划被误判为"没有"）。
	own_plans = [item for item in (_repository.list("plans") if _repository else [])
		if isinstance(item, dict) and item.get("userId", "demo-user") == user_id]
	if not own_plans:
		return "planner", "生成学习计划"
	return "exercise", "获取练习题并开始学习"


@workflows_api.post("/api/v1/workflows")
def create_workflow():
	# 非对象 JSON 原先会让 data.get 抛 AttributeError → 500
	data, guard = json_object()
	if guard is not None:
		return guard
	goal, guard = bounded_str(data.get("goal"), "goal", MAX_TEXT_CHARS)
	if guard is not None:
		return guard
	max_steps = data.get("maxSteps", 6)
	if isinstance(max_steps, bool) or not isinstance(max_steps, int) or not 1 <= max_steps <= 20:
		return _error("BAD_REQUEST", "maxSteps must be an integer between 1 and 20", {"field": "maxSteps"})

	# sessionId / userId 会成为 repository 的键。不加上限的话，一个 20 万字符的
	# sessionId 就能把 repository.json 从几十 KB 撑到数 MB（每次 save 全量重写）。
	raw_session = data.get("sessionId")
	session_id = f"session-{uuid.uuid4().hex[:12]}"
	if raw_session is not None:
		session_id, guard = bounded_str(raw_session, "sessionId", MAX_ID_CHARS)
		if guard is not None:
			return guard
	# 身份解析：已登录用登录身份（忽略请求体里的 userId，防冒用）
	user_id = resolve_user_id(data.get("userId"))
	if _repository and data.get("sessionId"):
		existing = _repository.get("workflows", session_id)
		if existing is not None:
			return jsonify({key: existing.get(key) for key in
				("sessionId", "traceId", "status", "currentStep", "nextAction")})
	current_step, next_action = _next_step(user_id)
	trace_id = f"trace-{session_id}"
	workflow = {"sessionId": session_id, "traceId": trace_id, "status": "running",
		"currentStep": current_step, "currentAgent": current_step, "nextAction": next_action,
		"stateVersion": 1, "finalAction": None, "goal": goal, "userId": user_id,
		"maxSteps": max_steps}
	if _repository:
		_repository.save("workflows", session_id, workflow)
		# 带上归属：`GET /traces/<id>` 要据此拒绝跨用户读取（否则 trace 里
		# 的 inputSummary/outputSummary 谁都能读）。
		_repository.save("traces", trace_id, {"traceId": trace_id, "events": [], "userId": user_id})
	if data.get("autoRun") is True:
		# 注意：这条分支会**直接**把 answers 交给 `_run_saved_workflow`，
		# 绕过 `/run` 端点上的那套护栏。已修的教训：护栏只加在一处时会漏掉旁路。
		# 所以这里必须做同样的校验。
		#
		# 同样要**持锁**：这条分支同样会推进工作流并写 profile/history，
		# 不加锁就绕过了 `/run` 端点上的串行化保护（同一个旁路陷阱）。
		# `_WORKFLOW_RUN_LOCK` 是可重入的，所以下面再调 `run_workflow_api` 不会自锁。
		with _WORKFLOW_RUN_LOCK:
			if data.get("answers") is not None:
				checked, guard = validate_answers(data.get("answers"))
				if guard is not None:
					return guard
				return jsonify(_run_saved_workflow(session_id, checked))
			return run_workflow_api(session_id)
	return jsonify({key: workflow[key] for key in
		("sessionId", "traceId", "status", "currentStep", "nextAction")})


def _owns_record(record: dict | None, user_id: str) -> bool:
	"""记录是否属于该用户。

	⚠️ 缺失 `userId` 的老数据按 demo-user 归属 —— 与 `plans.py::get_current_plan`、
	`demo.py` 的清理逻辑同一口径，避免把既有演示数据误判成"别人的"而 404。

	返回 404 而不是 403：不向调用方泄漏"这个 sessionId 存在但不属于你"。
	"""
	if not isinstance(record, dict):
		return False
	return record.get("userId", "demo-user") == user_id


@workflows_api.get("/api/v1/workflows/<session_id>")
def get_workflow(session_id: str):
	workflow = _repository.get("workflows", session_id) if _repository else None
	# ⚠️ 归属校验（修复的越权）。
	# 原来只要知道 sessionId 就能读到**任何人的**工作流状态。
	# 匿名请求会被 `resolve_user_id` 解析成 demo-user，所以演示路径不受影响。
	if not _owns_record(workflow, resolve_user_id(request.args.get("userId"))):
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)
	return jsonify({key: workflow.get(key) for key in
		("status", "currentAgent", "stateVersion", "finalAction")})


def _workflow_state(workflow: dict) -> dict:
	profile = _repository.get("profiles", workflow["userId"]) if _repository else None
	plan_id = workflow.get("state", {}).get("planId")
	plan = (_repository.get("plans", plan_id) if plan_id and _repository else None)
	if plan is None and _repository:
		plan = next((item for item in _repository.list("plans")
			if item.get("userId", "demo-user") == workflow["userId"]), None)
	state = dict(workflow.get("state", {}))
	state["sessionId"] = workflow["sessionId"]
	state["userId"] = workflow["userId"]
	state["goal"] = workflow["goal"]
	if profile is not None:
		state["profile"] = profile
		state["oldMastery"] = profile.get("mastery", [{}])[0].get("masteryScore", 42)
	if plan is not None:
		state["plan"] = plan
	state.setdefault("knowledgePoints", [{"knowledgePointId": "binary-tree-postorder",
		"masteryScore": state.get("oldMastery", 42), "errorIntensity": 60, "importance": 90}])
	state.setdefault("exercises", _EXERCISE_BANK)
	state.setdefault("answerKeys", _ANSWER_KEYS)
	state.setdefault("knowledgePointsByExercise", {
		item["exerciseId"]: item["knowledgePointId"] for item in _EXERCISE_BANK})
	return state


def _agent_action(step: str, state: dict):
	agents = {"secretary": SecretaryAgent(), "diagnosis": DiagnosisAgent(),
		"planner": PlannerAgent(), "exercise": ExerciseAgent(), "assessment": AssessmentAgent()}
	if step == "diagnosis":
		result = agents[step].run(state)
		if _repository and state.get("profile") is None:
			profile = LearnerProfile(
				state["userId"], state["goal"], None, [], 1,
				[KnowledgeMastery("binary-tree-postorder", 42, 0.7,
					datetime.now(timezone.utc), "二叉树后序遍历")],
			).to_dict()
			_repository.save("profiles", state["userId"], profile)
			state["profile"] = profile
		return {**result.output, "profile": state.get("profile", {}), "toolCalls": list(result.tool_calls)}
	if step == "planner":
		result = agents[step].run(state)
		plan = dict(result.output["plan"], planId=f"plan-{state.get('sessionId', 'workflow')}" )
		if _repository:
			plan["generatedFromProfileVersion"] = state.get("profile", {}).get("profileVersion", 1)
			plan["userId"] = state["userId"]
			_repository.save("plans", plan["planId"], plan)
		return {**result.output, "plan": plan, "toolCalls": list(result.tool_calls)}
	if step == "exercise":
		result = agents[step].run(state)
		return {"status": "waiting", "exercises": result.output["exercises"],
			"toolCalls": list(result.tool_calls), "nextAction": "提交答案后继续评估"}
	if step == "assessment":
		result = agents[step].run(state)
		persistence = _persist_workflow_assessment(state, result.output)
		return {**result.output, "assessment": result.output, "pendingSubmission": False,
			"needReplan": False, **persistence, "toolCalls": list(result.tool_calls)}
	return {"status": "error", "message": f"unsupported workflow step: {step}"}


def _persist_workflow_assessment(state: dict, assessment_data: dict) -> dict:
	"""Persist workflow grading through the same deterministic rules as submit."""
	if _repository is None or state.get("assessmentPersisted"):
		return {"assessmentPersisted": bool(state.get("assessmentPersisted"))}
	assessment = AssessmentResult(
		score=assessment_data["score"],
		per_knowledge_accuracy=assessment_data.get("perKnowledgeAccuracy", {}),
		error_types=assessment_data.get("errorTypes", []),
		old_mastery=assessment_data.get("oldMastery", 0),
		suggested_new_mastery=assessment_data.get("suggestedNewMastery", 0),
		exercise_result_id=assessment_data.get("exerciseResultId"),
	)
	evidence_id = f"evidence-{state['sessionId']}"
	result_id = assessment.exercise_result_id or f"workflow:{state['sessionId']}"
	profile = persist_mastery(_repository, state.get("userId", "demo-user"), assessment,
		evidence_id, result_id)
	updates: dict = {"assessmentPersisted": profile is not None, "evidenceIds": [evidence_id]}
	knowledge_point_id = next(iter(assessment.per_knowledge_accuracy), "unknown")
	decision = should_replan({
		"masteryScore": assessment.suggested_new_mastery,
		"knowledgePointId": knowledge_point_id,
		"repeatedError": assessment.score < 80,
	})
	if profile is None:
		return updates
	submission_response = {
		"userId": state.get("userId", "demo-user"),
		"submissionId": result_id,
		"assessment": assessment.to_dict(),
		"masteryUpdate": {
			"knowledgePointId": knowledge_point_id,
			"oldScore": assessment.old_mastery,
			"newScore": assessment.suggested_new_mastery,
		},
		"needReplan": bool(decision["needReplan"]),
		"replanDecision": decision,
		"traceId": state.get("traceId", f"trace-{state['sessionId']}"),
		"evidenceIds": [evidence_id],
	}
	if decision["needReplan"]:
		plan_id = state.get("plan", {}).get("planId", "plan-demo-001")
		plan = _repository.get("plans", plan_id)
		if plan is not None:
			replan_result = replan_learning_path(plan, {
				"masteryScore": assessment.suggested_new_mastery,
				"knowledgePointId": knowledge_point_id,
				"repeatedError": assessment.score < 80,
				# 传得分才能按错误程度分级加时；不传则回退到固定 ±15
				"assessmentScore": assessment.score,
			})
			updated_plan = replan_result["plan"]
			updated_plan["planId"] = plan["planId"]
			updated_plan["generatedFromProfileVersion"] = profile["profileVersion"]
			_repository.save("plans", plan["planId"], updated_plan)
			history = create_plan_history(plan, updated_plan, "掌握度低于阈值", [evidence_id])
			history["planId"] = plan["planId"]
			_repository.save("plan_histories",
				f"{plan['planId']}:v{history['newVersion']}", history)
			submission_response.update({"plan": updated_plan, "planDiff": history})
			updates.update({"plan": updated_plan, "planDiff": history})
	_repository.save("submissions", result_id, {"response": submission_response})
	updates["submissionId"] = result_id
	return updates


def _run_saved_workflow(session_id: str, answers: list[dict] | None = None,
					submission_id: str | None = None) -> dict:
	workflow = _repository.get("workflows", session_id) if _repository else None
	if workflow is None:
		raise KeyError(session_id)
	has_new_input = isinstance(answers, list) or submission_id is not None
	if workflow.get("state", {}).get("awaitingAnswers") and not has_new_input:
		return {key: workflow.get(key) for key in
			("sessionId", "traceId", "status", "currentStep", "currentAgent",
			 "stateVersion", "finalAction", "state")}
	state = _workflow_state(workflow)
	trace_id = workflow.get("traceId", f"trace-{session_id}")
	if submission_id:
		submission = _repository.get("submissions", submission_id) if _repository else None
		if submission is None or submission.get("response", {}).get("userId") != workflow.get("userId"):
			# 用专门的异常类型，让路由层能给出**与事实相符**的报错
			# （会话是存在的，错的是 submissionId）。
			raise SubmissionNotFound(submission_id)
		result = submission["response"]
		state.update({"assessment": result["assessment"], "needReplan": False,
			"pendingSubmission": False, "assessmentPersisted": True,
			"submissionId": submission_id, "evidenceIds": result.get("evidenceIds", []),
			"awaitingAnswers": False})
		answers = None
	if isinstance(answers, list):
		state.update({"answers": answers, "pendingSubmission": True,
			"exerciseResultId": f"workflow:{session_id}", "awaitingAnswers": False})
	session = WorkflowSession.from_dict({**workflow, "state": state})
	model_adapter = QwenAdapter.from_environment()
	result = run_workflow(session, lambda: session.state, _agent_action,
		model_decider=model_adapter.safe_decide if model_adapter else None,
		trace_recorder=lambda **event: append_trace_event(_repository, trace_id, **event))
	updated = result.to_dict()
	updated["traceId"] = trace_id
	updated["nextAction"] = updated.get("finalAction")
	# 这几项都是"本次请求的输入或大块只读数据"，评估完就没有再用，
	# 不能留在会话状态里——否则每次 save 都会把它们全量重写进 repository.json，
	# 让文件体积与后续每次 save 的耗时一起线性膨胀
	# （实测 4000 条 answers 会让 repository.json 一次增长 ~1.5MB）。
	#   profile / exercises —— 大块只读缓存，下一轮由 _workflow_state 重新注入
	#   answers             —— 已消费的请求输入；客户端本来就知道自己提交了什么，
	#                          不需要服务端回显（回显还会把响应体撑到 MB 级）
	#   answerKeys          —— ⚠️ **标准答案，绝不能回传或落盘**。
	#     原实现只 pop 了前三个，`state.answerKeys` 一直留在响应里
	#     （实测 30 条 `{"exercise-bst-001": "A", …}`），并且随 save 写进
	#     repository.json。后果：客户端发一次 `POST /workflows/<id>/run`（不传答案）
	#     就能拿到全部正确选项，**确定性判分层被完全绕过**。
	#     而 `GET /api/v1/exercises/<set>` 特意用 `_CLIENT_FIELDS` 剥掉答案
	#     （见 app/tools/exercise_tools.py），说明隐藏答案本就是设计意图。
	# 注意：`awaitingAnswers` 是流程标志，**必须保留**（见 orchestrator._is_actionable）。
	for transient in ("profile", "exercises", "answers", "answerKeys"):
		updated["state"].pop(transient, None)
	if _repository:
		_repository.save("workflows", session_id, updated)
	return {key: updated.get(key) for key in
		("sessionId", "traceId", "status", "currentStep", "currentAgent", "stateVersion",
		 "finalAction", "nextAction", "state")}


@workflows_api.post("/api/v1/workflows/<session_id>/run")
def run_workflow_api(session_id: str):
	# 非对象 JSON 原先会让 data.get 抛 AttributeError → 500
	data, guard = json_object()
	if guard is not None:
		return guard

	# ⚠️ 归属校验必须放在**任何写入之前**。
	#
	# 这是最严重的一处越权：`_run_saved_workflow` → `_persist_workflow_assessment`
	# 会把判分与掌握度写进 `workflow["userId"]` 的画像、并可能重规划他的计划。
	# 原来不校验归属，于是**知道 sessionId 的匿名请求就能把成绩写进别人的账号**。
	# 演示路径不受影响：匿名按 demo-user 解析，与演示工作流的归属一致。
	existing_workflow = _repository.get("workflows", session_id) if _repository else None
	if existing_workflow is not None and not _owns_record(
			existing_workflow, resolve_user_id(data.get("userId"))):
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)

	# ---------------------------------------------------------------- 输入护栏
	#
	# 为什么必须校验：`_run_saved_workflow` 会把 answers **原样存进会话 state**
	# 并随 `repository.save("workflows", ...)` 落盘，同时还会回显在响应里。
	# 实测一次 4000 条的提交就能让 repository.json 增长 ~1.5MB、响应体 1.3MB。
	# 而 JsonRepository 每次 save 都全量序列化整个仓库，所以这会线性拖慢所有接口。
	#
	# 注意：`validate_answers` 也校验"元素必须是对象"——缺了这条时传 `["a"]`
	# 会一路深入到判分逻辑才炸成 500。
	answers = None
	if data.get("answers") is not None:
		answers, guard = validate_answers(data.get("answers"))
		if guard is not None:
			return guard

	try:
		# 持锁跑完整段推进：见 `_WORKFLOW_RUN_LOCK` 的注释
		# （不加锁时并发 run 会让评估被重复记账）。
		with _WORKFLOW_RUN_LOCK:
			return jsonify(_run_saved_workflow(session_id, answers, data.get("submissionId")))
	except SubmissionNotFound:
		return _error("NOT_FOUND", "submission not found",
					  {"sessionId": session_id, "submissionId": data.get("submissionId")}, 404)
	except KeyError:
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)
