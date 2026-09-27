"""One atomic boundary for discovery and assessment profile writes."""
import threading
from datetime import datetime, timezone

PROFILE_LOCK = threading.RLock()


def merge_points_into_profile(repository, user_id, points):
	from app.api.exercises import _EXERCISE_BANK
	from app.agents.planner import PlannerAgent
	bank = {row["knowledgePointName"]: row["knowledgePointId"] for row in _EXERCISE_BANK}
	with PROFILE_LOCK:
		profile = repository.get("profiles", user_id)
		if profile is None:
			return None
		rows = profile.setdefault("mastery", [])
		ids = {row.get("knowledgePointId") for row in rows}
		names = {row.get("knowledgePointName") for row in rows}
		changed = False
		for point in points:
			point = {"name": point} if isinstance(point, str) else point
			name = str(point.get("name") or point.get("knowledgePointName") or "").strip()
			key = point.get("knowledgePointId") or bank.get(name, name)
			if not name or key in ids or name in names or len(rows) >= 60:
				continue
			rows.append({"knowledgePointId": key, "knowledgePointName": name,
				"masteryScore": 0, "confidence": 0, "lastUpdated": datetime.now(timezone.utc).isoformat(),
				"source": point.get("source", "document"), "sourceCourse": point.get("sourceCourse", ""),
				"importance": point.get("importance", 0.6)})
			ids.add(key)
			names.add(name)
			changed = True
		if changed:
			profile["profileVersion"] = profile.get("profileVersion", 1) + 1
			repository.save("profiles", user_id, profile)
		# Import must produce a real first plan, without waiting for a later button press.
		plans = [p for p in repository.list("plans") if p.get("userId", "demo-user") == user_id and p.get("tasks")]
		if rows and not plans:
			state = {"knowledgePoints": [dict(row, importance=round(row.get("importance", 0.6) * 100),
				errorIntensity=0) for row in rows]}
			result = PlannerAgent().run(state)
			plan = dict(result.output["plan"], planId=f"plan-import-{user_id}", userId=user_id,
				generatedFromProfileVersion=profile.get("profileVersion", 1), reason="根据已导入知识点生成学习计划")
			repository.save("plans", plan["planId"], plan)
		return profile
