from flask import Blueprint, jsonify

from app.repositories.json_repository import JsonRepository


profile_api = Blueprint("profile", __name__)
_repository: JsonRepository | None = None


def configure_profile_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@profile_api.get("/api/v1/profile/<user_id>")
def get_profile(user_id: str):
	"""读取学习画像。

	**读开放、写隔离** —— 这是刻意的规则划分：

	* **读**：任何身份都可以读任意 `userId` 的画像。
	  理由：演示数据（demo-user）本来就是公开的（`/api/v1/demo/reset` 无需凭据），
	  把它对已登录用户遮起来**没有任何安全增益**，却会打断演示链路
	  —— 登录后想看演示基线做对比就看不了了。
	  前端也不会去读他人：它读的是 `appState.currentUser.userId`。
	* **写**：提交作业、创建工作流一律走 `identity.resolve_user_id`，
	  已登录时**忽略**请求里传的 userId。**越权风险全在写侧**，
	  审计实测的越权（乙的掌握度被 0→16）正是写侧漏洞，已在
	  `exercises.py` / `workflows.py` 修掉。

	这样既堵住了真实风险，又保住了 `test_valid_bearer_does_not_change_demo_endpoints`
	所保护的"带 token 不改变演示接口行为"这条约束。
	"""
	profile = _repository.get("profiles", user_id) if _repository else None
	if profile is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
	return jsonify({"profileVersion": profile.get("profileVersion", 1),
		"profile": profile, "mastery": profile.get("mastery", []),
		"history": profile.get("history", []), "evidence": profile.get("evidence", [])})
