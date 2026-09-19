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
	left_ranges = _time_ranges((left.get("time") or {}).get("freeTime"))
	right_ranges = _time_ranges((right.get("time") or {}).get("freeTime"))
	return max((min(left_end, right_end) - max(left_start, right_start)
		for left_start, left_end in left_ranges
		for right_start, right_end in right_ranges
		if min(left_end, right_end) > max(left_start, right_start)), default=0)


def _list(profile: dict[str, Any], section: str, key: str) -> set[str]:
	value = (profile.get(section) or {}).get(key, [])
	return {str(item).strip().lower() for item in value if str(item).strip()}


def score_partner(user: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
	user_goal = user.get("learningGoal") or {}
	candidate_goal = candidate.get("learningGoal") or {}
	goal_score = 30 if user_goal.get("course") and user_goal == candidate_goal else (
		20 if user_goal.get("course") and user_goal.get("course") == candidate_goal.get("course") else 0)
	overlap = _overlap_minutes(user, candidate)
	time_score = 30 if overlap >= 120 else 20 if overlap >= 60 else 10 if overlap >= 30 else 0
	complement = len(_list(user, "knowledge", "weakness") & _list(candidate, "knowledge", "strength"))
	complement += len(_list(candidate, "knowledge", "weakness") & _list(user, "knowledge", "strength"))
	complement_score = 20 if complement >= 2 else 10 if complement == 1 else 0
	user_info = user.get("basicInfo") or {}
	candidate_info = candidate.get("basicInfo") or {}
	basic_score = 10 if (user_info.get("grade") == candidate_info.get("grade") and
		user_info.get("major") == candidate_info.get("major")) else 5 if user_info.get("grade") == candidate_info.get("grade") else 0
	stability_score = 10 if len(_time_ranges((candidate.get("time") or {}).get("freeTime"))) == 1 else 5 if candidate.get("time") else 0
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