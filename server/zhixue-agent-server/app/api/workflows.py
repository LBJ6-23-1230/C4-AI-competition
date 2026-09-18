import uuid
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from app.agents.assessment import AssessmentAgent
from app.agents.diagnosis import DiagnosisAgent
from app.agents.exercise import ExerciseAgent
from app.agents.planner import PlannerAgent
from app.agents.secretary import SecretaryAgent
from app.api.exercises import _ANSWER_KEYS, _EXERCISE_BANK
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


def configure_workflows_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


def _error(code: str, message: str, details: dict | None = None, status: int = 400):
	return jsonify({"errorCode": code, "message": message, "details": details}), status


def _next_step(user_id: str) -> tuple[str, str]:
	if _repository is None or _repository.get("profiles", user_id) is None:
		return "diagnosis", "开始学情诊断"
	if not (_repository.list("plans") if _repository else []):
		return "planner", "生成学习计划"
	return "exercise", "获取练习题并开始学习"


@workflows_api.post("/api/v1/workflows")
def create_workflow():
	data = request.get_json(silent=True) or {}
	goal = data.get("goal")
	if not isinstance(goal, str) or not goal.strip():
		return _error("BAD_REQUEST", "goal is required", {"field": "goal"})
	max_steps = data.get("maxSteps", 6)
	if isinstance(max_steps, bool) or not isinstance(max_steps, int) or not 1 <= max_steps <= 20:
		return _error("BAD_REQUEST", "maxSteps must be an integer between 1 and 20", {"field": "maxSteps"})

	session_id = data.get("sessionId") or f"session-{uuid.uuid4().hex[:12]}"
	user_id = data.get("userId", "demo-user")
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
		_repository.save("traces", trace_id, {"traceId": trace_id, "events": []})
	if data.get("autoRun") is True:
		if isinstance(data.get("answers"), list):
			return jsonify(_run_saved_workflow(session_id, data["answers"]))
		return run_workflow_api(session_id)
	return jsonify({key: workflow[key] for key in
		("sessionId", "traceId", "status", "currentStep", "nextAction")})


@workflows_api.get("/api/v1/workflows/<session_id>")
def get_workflow(session_id: str):
	workflow = _repository.get("workflows", session_id) if _repository else None
	if workflow is None:
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
	if profile is None or not decision["needReplan"]:
		return updates
	plan_id = state.get("plan", {}).get("planId", "plan-demo-001")
	plan = _repository.get("plans", plan_id)
	if plan is None:
		return updates
	replan_result = replan_learning_path(plan, {
		"masteryScore": assessment.suggested_new_mastery,
		"knowledgePointId": knowledge_point_id,
		"repeatedError": assessment.score < 80,
	})
	updated_plan = replan_result["plan"]
	updated_plan["planId"] = plan["planId"]
	updated_plan["generatedFromProfileVersion"] = profile["profileVersion"]
	_repository.save("plans", plan["planId"], updated_plan)
	history = create_plan_history(plan, updated_plan, "掌握度低于阈值", [evidence_id])
	_repository.save("plan_histories", plan["planId"], history)
	updates.update({"plan": updated_plan, "planDiff": history})
	return updates


def _run_saved_workflow(session_id: str, answers: list[dict] | None = None,
					submission_id: str | None = None) -> dict:
	workflow = _repository.get("workflows", session_id) if _repository else None
	if workflow is None:
		raise KeyError(session_id)
	state = _workflow_state(workflow)
	trace_id = workflow.get("traceId", f"trace-{session_id}")
	if submission_id:
		submission = _repository.get("submissions", submission_id) if _repository else None
		if submission is None or submission.get("response", {}).get("userId") != workflow.get("userId"):
			raise KeyError(submission_id)
		result = submission["response"]
		state.update({"assessment": result["assessment"], "needReplan": False,
			"pendingSubmission": False, "assessmentPersisted": True,
			"submissionId": submission_id, "evidenceIds": result.get("evidenceIds", [])})
		answers = None
	if isinstance(answers, list):
		state.update({"answers": answers, "pendingSubmission": True,
			"exerciseResultId": f"workflow:{session_id}"})
	session = WorkflowSession.from_dict({**workflow, "state": state})
	model_adapter = QwenAdapter.from_environment()
	result = run_workflow(session, lambda: session.state, _agent_action,
		model_decider=model_adapter.safe_decide if model_adapter else None,
		trace_recorder=lambda **event: append_trace_event(_repository, trace_id, **event))
	updated = result.to_dict()
	updated["traceId"] = trace_id
	updated["nextAction"] = updated.get("finalAction")
	updated["state"].pop("profile", None)
	updated["state"].pop("exercises", None)
	if _repository:
		_repository.save("workflows", session_id, updated)
	return {key: updated.get(key) for key in
		("sessionId", "traceId", "status", "currentStep", "currentAgent", "stateVersion", "finalAction", "state")}


@workflows_api.post("/api/v1/workflows/<session_id>/run")
def run_workflow_api(session_id: str):
	data = request.get_json(silent=True) or {}
	try:
		return jsonify(_run_saved_workflow(session_id, data.get("answers")
			if isinstance(data.get("answers"), list) else None, data.get("submissionId")))
	except KeyError:
		return _error("NOT_FOUND", "workflow not found", {"sessionId": session_id}, 404)
