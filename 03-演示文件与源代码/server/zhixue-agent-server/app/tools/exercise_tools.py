"""Deterministic exercise-bank selection rules."""

from collections.abc import Iterable

_CLIENT_FIELDS = (
	"exerciseId",
	"knowledgePointId",
	"knowledgePointName",
	"difficulty",
	"stem",
	"options",
	"source",
)


def select_exercises(exercises: Iterable[dict], knowledge_point_id: str | None = None,
					difficulty: str | None = None, count: int = 3,
					excluded_ids: Iterable[str] = ()) -> list[dict]:
	if count < 1:
		raise ValueError("count must be positive")
	excluded = set(excluded_ids)
	selected: list[dict] = []
	seen: set[str] = set()
	for exercise in exercises:
		exercise_id = exercise.get("exerciseId")
		if not exercise_id or exercise_id in excluded or exercise_id in seen:
			continue
		if knowledge_point_id and exercise.get("knowledgePointId") != knowledge_point_id:
			continue
		if difficulty and exercise.get("difficulty") != difficulty:
			continue
		selected.append({key: exercise[key] for key in _CLIENT_FIELDS if key in exercise})
		seen.add(exercise_id)
		if len(selected) == count:
			break
	return selected