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
		# ⚠️ 五因子必须用**该用户的真实画像**，不能喂常量。
		#
		# 原实现把 `masteryScore`/`errorIntensity`/`importance`/`urgency` 全部写死
		# （`58 if knowledgePointId == "binary-tree-postorder" else 80`、`importance: 90` …），
		# 后果：`GET /api/v1/plans/current` 返回的 `factors` 与 `reason`
		# （前端「为什么是它」决策因子卡的数据源，也是答辩主叙事之一）
		# **与调用者是谁完全无关** —— 一个新账号、mastery 为 0，
		# 也会看到 "mastery 0.42 / importance 0.90" 这套数字。
		# 这等于用假输入污染了"确定性引擎"的对外解释力。
		#
		# 现在改为：掌握度取画像真实值，错误强度由该知识点的错题证据推导，
		# importance / urgency / 先修影响沿用既有决策口径。
		profile = _repository.get("profiles", user_id) if _repository else None
		mastery_by_point: dict[str, float] = {}
		if isinstance(profile, dict):
			for item in (profile.get("mastery") or []):
				if isinstance(item, dict):
					point = item.get("knowledgePointId")
					if isinstance(point, str):
						mastery_by_point[point] = float(item.get("masteryScore", 0) or 0)

		error_intensity_by_point: dict[str, float] = {}
		evidence_count_by_point: dict[str, int] = {}
		for evidence in (_repository.list("evidences") if _repository else []):
			if not isinstance(evidence, dict):
				continue
			point = evidence.get("knowledgePointId")
			if not isinstance(point, str):
				continue
			evidence_count_by_point[point] = evidence_count_by_point.get(point, 0) + 1

		# ⚠️ 量纲必须是 **0~100**：`calculate_learning_priority` 内部统一 `/100` 归一化
		# （见 app/decision/priority.py:48-52）。传 0~1 会让 mastery 项恒为 ~1.0、
		# 其余项恒为 ~0.0，五因子卡会显示成"掌握度贡献压倒一切"的错误结论。
		for point, count in evidence_count_by_point.items():
			error_intensity_by_point[point] = min(100.0, 40.0 + 20.0 * count)

		days_left = 5
		for task in plan["tasks"]:
			raw_days = task.get("daysLeft")
			if isinstance(raw_days, int) and raw_days >= 0:
				days_left = raw_days
				break

		knowledge_points = [
			{
				"knowledgePointId": task.get("knowledgePointId", "binary-tree-postorder"),
				"masteryScore": mastery_by_point.get(
					task.get("knowledgePointId", ""), 0.0),
				"errorIntensity": error_intensity_by_point.get(
					task.get("knowledgePointId", ""), 0.0),
				"importance": 90 if task.get("source") == "agent" else 60,
				# ⚠️ 这里**故意不传 `urgency`**：引擎的写法是
				# `item.get("urgency", urgency)`，只在**键缺失**时才用按 daysLeft
				# 算出的默认值。传 `"urgency": 0` 会被当成真实值，
				# 于是紧迫度项恒为 0（五因子卡永远少一行贡献）。
				# 不传键，才让它走默认分支。
				"prerequisiteImpact": 20 if task.get("canCollaborate") else 10,
			}
			for task in plan["tasks"]
		]
		top_priority = __import__("app.decision.priority", fromlist=["calculate_learning_priority"]).calculate_learning_priority(
			knowledge_points, {"daysLeft": days_left}
		)
		if top_priority:
			# ⚠️ `factors` / `reason` 解释的是**当前计划的首个任务**，不是"重新排名后的第一名"。
			#
			# 为什么必须这样：前端「为什么是它」面板是计划页上"这个任务"的展开说明 ——
			# 用户看到的是 `tasks[0]`（task-postorder / 二叉树后序遍历），
			# 若因子卡讲的是另一个知识点，两者就对不上了。
			#
			# 之前不会暴露这个问题，是因为旧实现给所有知识点喂了同一组常量
			# （都是 58/67/90/53/20），并列时取列表首项，恰好等于 `tasks[0]`。
			# 换成真实数据后，画像里**没有掌握度记录**的知识点（本例 graph-algorithm
			# 回退 0）mastery 因子恒为 1.0，必然排到第一，于是因子卡开始讲错对象。
			# 这里改为按计划首任务的 knowledgePointId 显式回查。
			lead_point = plan["tasks"][0].get("knowledgePointId", "")
			lead = next(
				(row for row in top_priority if row.get("knowledgePointId") == lead_point),
				top_priority[0],
			)
			plan["factors"] = _factor_rows(lead.get("factors", {}))
			plan["reason"] = lead.get("reason", plan.get("reason", ""))
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
