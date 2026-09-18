from datetime import datetime, timezone

from flask import Blueprint, jsonify

from app.domain.plan import LearningPlan
from app.domain.profile import KnowledgeMastery, LearnerProfile
from app.repositories.json_repository import JsonRepository
from app.api.exercises import configure_exercises_repository
from app.api.plans import configure_plans_repository
from app.api.profile import configure_profile_repository
from app.api.traces import configure_traces_repository
from app.api.experiments import configure_experiments_repository


demo_api = Blueprint("demo", __name__)
_repository: JsonRepository | None = None


def configure_demo_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository
	configure_exercises_repository(repository)
	configure_traces_repository(repository)
	configure_profile_repository(repository)
	configure_plans_repository(repository)
	configure_experiments_repository(repository)


def ensure_demo_data() -> None:
	if _repository is None or _repository.get("profiles", "demo-user") is not None:
		return
	profile, plan, trace = _demo_state()
	_repository.save("profiles", profile.user_id, profile.to_dict())
	plan_data = plan.to_dict()
	plan_data["userId"] = profile.user_id
	_repository.save("plans", plan.plan_id, plan_data)
	_repository.save("traces", trace["traceId"], trace)


def _demo_state() -> tuple[LearnerProfile, LearningPlan, dict[str, object]]:
	timestamp = datetime(2026, 9, 2, 9, 0, tzinfo=timezone.utc)
	profile = LearnerProfile(
		"demo-user",
		"数据结构考试80+",
		"2026-09-30",
		["20:00-22:00"],
		1,
		[KnowledgeMastery("binary-tree-postorder", 42, 0.7, timestamp, "二叉树后序遍历")],
	)
	plan = LearningPlan(
		"plan-demo-001",
		1,
		[{"taskId": "task-postorder", "knowledgePointId": "binary-tree-postorder",
		  "knowledgePointName": "二叉树后序遍历", "durationMinutes": 30,
		  "status": "pending", "priority": "high"},
		 {"taskId": "task-graph", "knowledgePointId": "graph-algorithm",
		  "knowledgePointName": "图算法", "durationMinutes": 30,
		  "status": "pending", "priority": "medium"}],
		1,
		"巩固二叉树后序遍历",
	)
	plan_data = plan.to_dict()
	plan_data["userId"] = profile.user_id
	plan = LearningPlan.from_dict(plan_data)
	return profile, plan, {"traceId": "trace-demo-reset-001", "events": []}


@demo_api.post("/api/v1/demo/reset")
def reset_demo():
	if _repository is None:
		return jsonify({"errorCode": "INTERNAL_ERROR", "message": "demo repository is not configured", "details": None}), 500

	profile, plan, trace = _demo_state()
	for collection in ("traces", "submissions", "evidences", "plan_histories"):
		_repository.clear(collection)
	_repository.save("profiles", profile.user_id, profile.to_dict())
	plan_data = plan.to_dict()
	plan_data["userId"] = profile.user_id
	_repository.save("plans", plan.plan_id, plan_data)
	_repository.save("traces", trace["traceId"], trace)
	return jsonify({"status": "reset", "userId": profile.user_id, "profile": profile.to_dict(),
					"plan": plan.to_dict(), "traceId": trace["traceId"]})
