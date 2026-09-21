from flask import Blueprint, jsonify, request

from app.api.identity import resolve_user_id
from app.repositories.json_repository import JsonRepository


plans_api = Blueprint("plans", __name__)
_repository: JsonRepository | None = None


def configure_plans_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@plans_api.get("/api/v1/plans/current")
def get_current_plan():
	# 身份解析统一走 identity.resolve_user_id：
	# 已登录用登录身份（并忽略 query 里的 userId，防冒用）；
	# 未登录仍可用 `?userId=` 看指定用户，不带参数则回退 demo-user。
	# 修复的缺陷：原先写死 `request.args.get("userId", "demo-user")`，
	# 而前端不带该参数，于是**登录后读到的仍是演示账号的计划**。
	user_id = resolve_user_id(request.args.get("userId"))
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
			plan["factors"] = _factor_rows(top_priority[0].get("factors", {}))
			plan["reason"] = top_priority[0].get("reason", plan.get("reason", ""))
	return jsonify(plan)


def _factor_rows(factors: object) -> list[dict]:
	"""把优先级因子从 `{name: {value, weight, contribution}}` 摊平成数组。

	为什么必须转：前端 `LearningPlan.factors` 声明为 `DecisionFactor[]`，
	`StudySuggestion.ets` 用 `factors().length > 0` 判断是否渲染五因子卡，
	`ApiResponseValidator` 也按数组校验（`hasArray(data,'factors')`）。

	而 `calculate_learning_priority` 返回的是**字典**。直接透传会导致：
	  * 联机模式：`.length` 为 undefined → 「为什么是它」因子卡**永不显示**
	  * 离线 Fixture：`FixtureApiTransport.factors()` 返回数组 → 正常显示
	于是表现为"离线好看、联机消失"的假象，极难定位。

	数组元素结构与 `/api/v1/agent/proactive` 的 factors 保持一致
	（name / value / weight / contribution），前端同一个 `DecisionFactor` 即可消费。
	"""
	if not isinstance(factors, dict):
		return []
	rows: list[dict] = []
	for name, values in factors.items():
		if not isinstance(values, dict):
			continue
		rows.append({
			"name": str(name),
			"value": values.get("value", 0),
			"weight": values.get("weight", 0),
			"contribution": values.get("contribution", 0),
		})
	# 贡献度从大到小，便于前端直接按顺序展示"最影响决策的因子"
	rows.sort(key=lambda row: row.get("contribution", 0), reverse=True)
	return rows


@plans_api.get("/api/v1/plans/<plan_id>/diff")
def get_plan_diff(plan_id: str):
	plan = _repository.get("plans", plan_id) if _repository else None
	if plan is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "plan not found", "details": {"planId": plan_id}}), 404
	history = _latest_plan_history(plan_id)
	if history is None:
		return jsonify({"planId": plan_id, "oldVersion": plan["version"], "newVersion": plan["version"],
			"changedTasks": [], "adjustmentReason": "no changes", "triggerEvidence": []})
	return jsonify({"planId": plan_id, "oldVersion": history.get("oldVersion"),
		"newVersion": history.get("newVersion"), "changedTasks": history.get("changedTasks", []),
		"adjustmentReason": history.get("adjustmentReason", history.get("reason", "")),
		"triggerEvidence": history.get("triggerEvidence", history.get("evidenceIds", []))})


def _latest_plan_history(plan_id: str) -> dict | None:
	"""Return the newest retained replan event for a plan.

	Plan histories are event records, so a plan can have one entry per
	replanned version. The old single-key representation is still accepted
	for data written before this change.
	"""
	if _repository is None:
		return None
	histories = [
		item for item in _repository.list("plan_histories")
		if item.get("planId") == plan_id
	]
	if not histories:
		legacy = _repository.get("plan_histories", plan_id)
		return legacy

	def version(item: dict) -> int:
		try:
			return int(item.get("newVersion", 0))
		except (TypeError, ValueError):
			return 0

	return max(histories, key=lambda item: (
		version(item), str(item.get("timestamp", ""))))
