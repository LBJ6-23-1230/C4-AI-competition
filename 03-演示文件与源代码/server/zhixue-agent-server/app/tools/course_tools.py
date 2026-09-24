"""Deterministic course selection helpers."""

from collections.abc import Iterable


def select_courses(courses: Iterable[dict], knowledge_point_id: str | None = None,
				   difficulty: str | None = None, count: int = 3) -> list[dict]:
	if count < 1:
		raise ValueError("count must be positive")
	selected = []
	for course in courses:
		if knowledge_point_id and course.get("knowledgePointId") != knowledge_point_id:
			continue
		if difficulty and course.get("difficulty") != difficulty:
			continue
		selected.append(dict(course))
		if len(selected) == count:
			break
	return selected
