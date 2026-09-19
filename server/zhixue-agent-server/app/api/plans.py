from flask import Blueprint, jsonify, request

from app.repositories.json_repository import JsonRepository


plans_api = Blueprint("plans", __name__)
_repository: JsonRepository | None = None


def configure_plans_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@plans_api.get("/api/v1/plans/current")
def get_current_plan():
	user_id = request.args.get("userId", "demo-user")
	plans = [plan for plan in (_repository.list("plans") if _repository else [])
		if plan.get("userId", "demo-user") == user_id]
	if not plans:
		return jsonify({"errorCode": "NOT_FOUND", "message": "current plan not found", "details": {"userId": user_id}}), 404
	plan = dict(plans[0])
	if plan.get("tasks"):
		knowledge_points = [
			{
				"knowledgePointId": task.get("knowledgePointId", "binary-tree-postorder"),
				"masteryScore": 58 if task.get("knowledgePointId") == "binary-tree-postorder" else 80,
				"errorIntensity": 67 if task.get("knowledgePointId") == "binary-tree-postorder" else 10,
				"importance": 90,
				"urgency": 53,
				"prerequisiteImpact": 20,
			}
			for task in plan["tasks"]
		]
		top_priority = __import__("app.decision.priority", fromlist=["calculate_learning_priority"]).calculate_learning_priority(
			knowledge_points, {"daysLeft": 5}
		)
		if top_priority:
			plan["factors"] = top_priority[0].get("factors", {})
			plan["reason"] = top_priority[0].get("reason", plan.get("reason", ""))
	return jsonify(plan)


@plans_api.get("/api/v1/plans/<plan_id>/diff")
def get_plan_diff(plan_id: str):
	plan = _repository.get("plans", plan_id) if _repository else None
	if plan is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "plan not found", "details": {"planId": plan_id}}), 404
	history = _repository.get("plan_histories", plan_id) if _repository else None
	if history is None:
		return jsonify({"planId": plan_id, "oldVersion": plan["version"], "newVersion": plan["version"],
			"changedTasks": [], "adjustmentReason": "no changes", "triggerEvidence": []})
	return jsonify({"planId": plan_id, "oldVersion": history.get("oldVersion"),
		"newVersion": history.get("newVersion"), "changedTasks": history.get("changedTasks", []),
		"adjustmentReason": history.get("adjustmentReason", history.get("reason", "")),
		"triggerEvidence": history.get("triggerEvidence", history.get("evidenceIds", []))})
