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


def _item_owner(item: dict[str, object]) -> str:
	"""尽力判断一条记录归属于哪个 userId；判不出返回空串。

	各集合的归属信息完整度不同（实测 `data/repository.json`）：
	  * `workflows`  —— 有顶层 `userId`，最好判
	  * `plans`      —— 有顶层 `userId`
	  * `traces` / `submissions` / `evidences` / `plan_histories`
	                —— **完全没有归属字段**，只能靠 id 关联推断
	判不出时返回空串，调用方按"保留"处理。
	"""
	if not isinstance(item, dict):
		return ""
	owner = item.get("userId")
	if isinstance(owner, str) and owner.strip():
		return owner.strip()
	state = item.get("state")
	if isinstance(state, dict):
		nested = state.get("userId")
		if isinstance(nested, str) and nested.strip():
			return nested.strip()
	return ""


def _purge_demo_owned(profile_user_id: str) -> dict[str, int]:
	"""只删除**能证明属于演示身份**的记录，返回各集合删除条数。

	## 为什么不能整集合 clear（原实现的做法）

	`POST /api/v1/demo/reset` **无需任何凭据**即可调用。原先的实现是
	`_repository.clear(collection)` —— 那是清空**整个集合**，
	于是任何匿名请求都会把**所有注册用户**的 workflows / traces /
	submissions / evidences / plan_histories 一起删掉，而 profiles 仍保留，
	用户数据直接变成孤儿（自己的 workflow 由 200 变 404，且无法找回）。
	实测已复现。

	## 判定规则（保守优先）

	先算出"演示身份拥有哪些 workflow / plan"，再据此判定派生记录：
	  * workflows            —— 按 `userId` 直接判
	  * plans / plan_histories —— 按 `userId` / `planId` 判
	  * traces               —— `traceId` 命中被删 workflow 的 `traceId` 时删
	  * submissions / evidences —— 主键形态为 `<userId>:<setId>:<key>`，
	    或 id 命中被删 workflow 会话时删
	**其余一律保留**：拿不准归属就留着，宁可残留演示数据，也不误删他人记录。
	"""
	repo = _repository
	if repo is None:
		return {}

	# ---- 第一步：找出演示身份拥有的 workflow 与 plan ----
	demo_workflow_ids: set[str] = set()
	demo_trace_ids: set[str] = set()
	for session_id in repo.ids("workflows"):
		item = repo.get("workflows", session_id)
		if item is None:
			continue
		if _item_owner(item) == profile_user_id:
			demo_workflow_ids.add(session_id)
			item_trace = item.get("traceId")
			if isinstance(item_trace, str) and item_trace:
				demo_trace_ids.add(item_trace)

	demo_plan_ids: set[str] = set()
	for plan_id in repo.ids("plans"):
		item = repo.get("plans", plan_id)
		if item is not None and _item_owner(item) == profile_user_id:
			demo_plan_ids.add(plan_id)

	removed: dict[str, int] = {}

	def _drop(collection: str, item_id: str) -> None:
		repo.delete(collection, item_id)
		removed[collection] = removed.get(collection, 0) + 1

	# ---- 第二步：按归属删除 ----
	for session_id in list(demo_workflow_ids):
		_drop("workflows", session_id)

	for plan_id in list(demo_plan_ids):
		_drop("plans", plan_id)

	for trace_id in repo.ids("traces"):
		# 只删能关联到被删 workflow 的 trace；演示基线 trace（trace-demo-reset-001）
		# 由 `ensure_demo_data()` 重建，不在此列，故不会被误删。
		if trace_id in demo_trace_ids:
			_drop("traces", trace_id)

	for result_id in repo.ids("submissions"):
		# 主键形态 `<userId>:<setId>:<idempotencyKey>`
		if result_id.startswith(f"{profile_user_id}:"):
			_drop("submissions", result_id)

	for history_id in repo.ids("plan_histories"):
		item = repo.get("plan_histories", history_id)
		if item is None:
			continue
		if item.get("planId") in demo_plan_ids or item.get("userId") == profile_user_id:
			_drop("plan_histories", history_id)

	for evidence_id in repo.ids("evidences"):
		item = repo.get("evidences", evidence_id)
		if item is None:
			continue
		# evidences 无 userId，用 sourceId（即 submissions 主键）反查归属
		source_id = item.get("sourceId")
		if isinstance(source_id, str) and source_id.startswith(f"{profile_user_id}:"):
			_drop("evidences", evidence_id)

	return removed


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

	# ---------------------------------------------------------------- 清理范围
	#
	# 只清**演示身份自己的数据**，绝不整集合清空：
	#
	# ⚠️ 原实现是 `for collection in (...): _repository.clear(collection)`
	# —— 那是**清空整个集合**，而不是"清演示数据"。后果（实测）：
	#   * 本接口**无需任何凭据**即可调用（匿名可打）
	#   * 于是任何匿名请求都会把**所有注册用户**的 workflows / traces /
	#     submissions / evidences / plan_histories 一起删掉
	#   * 而 profiles 仍保留 → 用户数据变成孤儿：自己的 workflow 由 200 变 404，
	#     且无法通过任何接口找回
	# 即"一个匿名请求就能清掉全部用户的学习记录"。
	#
	# 现在改为按归属删除：只删**能证明属于演示身份**的条目（详见 `_purge_demo_owned`）。
	# 拿不准归属的一律保留 —— 宁可少清，不可误删他人数据。
	#
	# ⚠️ `sessions` / `users` 从来不在此列（属于鉴权与账号数据）。
	_purge_demo_owned(profile.user_id)
	_repository.save("profiles", profile.user_id, profile.to_dict())
	plan_data = plan.to_dict()
	plan_data["userId"] = profile.user_id
	_repository.save("plans", plan.plan_id, plan_data)
	_repository.save("traces", trace["traceId"], trace)
	return jsonify({"status": "reset", "userId": profile.user_id, "profile": profile.to_dict(),
					"plan": plan.to_dict(), "traceId": trace["traceId"]})
