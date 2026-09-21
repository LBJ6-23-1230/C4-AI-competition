"""Deterministic learning-partner matching used by the online PartnerMatch page."""

from __future__ import annotations

from datetime import datetime
from typing import Any


def _time_ranges(value: Any) -> list[tuple[int, int]]:
	if not isinstance(value, list):
		return []
	ranges = []
	for item in value:
		try:
			start, end = str(item).split("-", 1)
			start_minutes = int(start.split(":")[0]) * 60 + int(start.split(":")[1])
			end_minutes = int(end.split(":")[0]) * 60 + int(end.split(":")[1])
			if end_minutes > start_minutes:
				ranges.append((start_minutes, end_minutes))
		except (ValueError, IndexError):
			continue
	return ranges


def _overlap_minutes(left: dict[str, Any], right: dict[str, Any]) -> int:
	# `_dict()` 而非 `or {}`：`time` 收到字符串/数字时 `or {}` 挡不住
	# （非空字符串是 truthy），会继续 `.get()` 抛 AttributeError → 500。
	left_ranges = _time_ranges(_dict(left.get("time")).get("freeTime"))
	right_ranges = _time_ranges(_dict(right.get("time")).get("freeTime"))
	return max((min(left_end, right_end) - max(left_start, right_start)
		for left_start, left_end in left_ranges
		for right_start, right_end in right_ranges
		if min(left_end, right_end) > max(left_start, right_start)), default=0)


def _list(profile: dict[str, Any], section: str, key: str) -> set[str]:
	value = _dict(profile.get(section)).get(key, [])
	if not isinstance(value, list):
		# 单个字符串也容忍（按单元素处理），其余非列表一律视为空
		value = [value] if isinstance(value, str) else []
	return {str(item).strip().lower() for item in value if str(item).strip()}


def _dict(value: Any) -> dict[str, Any]:
	"""把"应该是对象"的字段安全地取成 dict。

	为什么需要：调用方（HTTP 层）只校验了 `user` 本身是对象，
	**没有校验它的嵌套字段**。于是 `learningGoal` / `knowledge` / `time` /
	`basicInfo` 收到字符串、数组或数字时，`xxx.get(...)` 抛 AttributeError，
	冒泡成 HTTP 500。实测这 4 类输入稳定复现：

	    {"user":{"learningGoal":"x"}}   → 500
	    {"user":{"knowledge":"x"}}      → 500
	    {"user":{"time":"x"}}           → 500
	    {"user":{"basicInfo":1}}        → 500

	注意 `value or {}` 这种写法只能挡住 None，挡不住字符串/数字。
	"""
	return value if isinstance(value, dict) else {}


def score_partner(user: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
	user_goal = _dict(user.get("learningGoal"))
	candidate_goal = _dict(candidate.get("learningGoal"))
	goal_score = 30 if user_goal.get("course") and user_goal == candidate_goal else (
		20 if user_goal.get("course") and user_goal.get("course") == candidate_goal.get("course") else 0)
	overlap = _overlap_minutes(user, candidate)
	time_score = 30 if overlap >= 120 else 20 if overlap >= 60 else 10 if overlap >= 30 else 0
	complement = len(_list(user, "knowledge", "weakness") & _list(candidate, "knowledge", "strength"))
	complement += len(_list(candidate, "knowledge", "weakness") & _list(user, "knowledge", "strength"))
	complement_score = 20 if complement >= 2 else 10 if complement == 1 else 0
	user_info = _dict(user.get("basicInfo"))
	candidate_info = _dict(candidate.get("basicInfo"))
	basic_score = 10 if (user_info.get("grade") == candidate_info.get("grade") and
		user_info.get("major") == candidate_info.get("major")) else 5 if user_info.get("grade") == candidate_info.get("grade") else 0
	stability_score = 10 if len(_time_ranges(_dict(candidate.get("time")).get("freeTime"))) == 1 else 5 if candidate.get("time") else 0
	total = goal_score + time_score + complement_score + basic_score + stability_score
	return {"candidate": candidate, "score": total, "factors": {
		"goal": goal_score, "timeOverlap": time_score, "knowledgeComplement": complement_score,
		"basicMatch": basic_score, "stability": stability_score, "overlapMinutes": overlap,
	}}


def match_partners(user: dict[str, Any], candidates: list[dict[str, Any]]) -> dict[str, Any]:
	ranked = sorted((score_partner(user, item) for item in candidates),
		key=lambda item: item["score"], reverse=True)
	best = ranked[0] if ranked and ranked[0]["score"] > 0 else None
	return {"userId": user.get("userId", "demo-user"), "matchedCandidate": best,
		"candidates": ranked, "generatedAt": datetime.now().isoformat(),
		"realModeUnavailable": False}