"""Read-only profile projections used by agents and API boundaries."""

from collections.abc import Mapping
from typing import Any


def get_mastery(profile: Mapping[str, Any], knowledge_point_id: str,
				default: int | float = 0) -> int | float:
	for mastery in profile.get("mastery", []):
		if mastery.get("knowledgePointId") == knowledge_point_id:
			return mastery.get("masteryScore", default)
	return default


def profile_summary(profile: Mapping[str, Any]) -> dict[str, Any]:
	return {"userId": profile.get("userId"), "goal": profile.get("goal"),
		"profileVersion": profile.get("profileVersion", 1),
		"mastery": list(profile.get("mastery", []))}
