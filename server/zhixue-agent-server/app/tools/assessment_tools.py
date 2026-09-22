"""Deterministic grading and mastery update rules."""

from collections.abc import Iterable, Mapping
from datetime import datetime, timezone
from typing import Any

from app.domain.assessment import AssessmentResult
from app.domain.evidence import Evidence, MasteryHistory
from app.domain.profile import KnowledgeMastery, LearnerProfile


def grade_exercise(
	answers: Iterable[Mapping[str, object]],
	answer_keys: Mapping[str, str],
	knowledge_points: Mapping[str, str] | None = None,
	old_mastery: int | float = 0,
	exercise_result_id: str | None = None,
) -> AssessmentResult:
	"""Grade submitted answers without calling an LLM or mutating state."""
	knowledge_points = knowledge_points or {}
	submitted: dict[str, str] = {}
	for answer in answers:
		exercise_id = answer.get("exerciseId")
		if exercise_id is None:
			continue
		submitted[str(exercise_id)] = str(answer.get("answer", "")).strip().upper()

	valid_ids = [exercise_id for exercise_id in submitted if exercise_id in answer_keys]
	correct_ids = [exercise_id for exercise_id in valid_ids if submitted[exercise_id] == answer_keys[exercise_id]]
	score = round(len(correct_ids) / max(1, len(valid_ids)) * 100, 2)
	per_knowledge: dict[str, list[bool]] = {}
	for exercise_id in valid_ids:
		knowledge_point_id = knowledge_points.get(exercise_id, "unknown")
		per_knowledge.setdefault(knowledge_point_id, []).append(exercise_id in correct_ids)
	accuracy = {key: round(sum(values) / len(values), 4) for key, values in per_knowledge.items()}
	error_types = ["traversal-order"] if len(correct_ids) < len(valid_ids) else []
	return AssessmentResult(
		score=score,
		per_knowledge_accuracy=accuracy,
		error_types=error_types,
		old_mastery=old_mastery,
		# 标量仍按**整卷总分**算 —— 它是演示基线的对外数值（√√× → 58），不能动。
		suggested_new_mastery=update_mastery(old_mastery, score),
		# 落盘用的**按知识点**建议值：每个知识点看自己的正确率，
		# 而不是把整卷的标量套到所有知识点上（见 AssessmentResult 的字段说明）。
		per_knowledge_mastery={
			point: update_mastery(old_mastery, round(point_accuracy * 100, 2))
			for point, point_accuracy in accuracy.items()
		},
		exercise_result_id=exercise_result_id,
	)


def update_mastery(old_score: int | float, assessment_score: float) -> int | float:
	"""Apply the transparent demo rule used by the assessment boundary."""
	if not 0 <= old_score <= 100:
		raise ValueError("old_score must be between 0 and 100")
	if not 0 <= assessment_score <= 100:
		raise ValueError("assessment_score must be between 0 and 100")
	if assessment_score == 100:
		delta = 29
	elif assessment_score >= 60:
		delta = 16
	elif assessment_score >= 40:
		delta = 4
	else:
		delta = -4
	return max(0, min(100, old_score + delta))


def persist_mastery(repository: Any, user_id: str, assessment: AssessmentResult,
					evidence_id: str, result_id: str,
					timestamp: datetime | None = None) -> dict[str, Any] | None:
	"""Persist the assessment-owned mastery, evidence, and history updates."""
	profile = repository.get("profiles", user_id)
	if profile is None:
		return None
	timestamp = timestamp or datetime.now(timezone.utc)
	profile_model = LearnerProfile.from_dict(profile)
	# 逐个知识点写自己的建议值；缺失时回退整卷标量（保持既有调用方行为不变）。
	touched_points: list[str] = []
	for mastery in profile_model.mastery:
		if mastery.knowledge_point_id in assessment.per_knowledge_accuracy:
			mastery.mastery_score = assessment.per_knowledge_mastery.get(
				mastery.knowledge_point_id, assessment.suggested_new_mastery)
			mastery.last_updated = timestamp
			touched_points.append(mastery.knowledge_point_id)
	# ⚠️ 画像里**没有记录**的知识点必须补建，否则"练了但没记上"。
	# 原实现只更新已存在的条目 —— 提交一个新知识点的题集时，
	# 掌握度变化在响应里可见、在画像里却查无此点，历史与事实不符。
	existing_points = {m.knowledge_point_id for m in profile_model.mastery}
	for point in assessment.per_knowledge_accuracy:
		if point in existing_points or point == "unknown":
			continue
		profile_model.mastery.append(KnowledgeMastery(
			knowledge_point_id=point,
			knowledge_point_name=point,
			mastery_score=assessment.per_knowledge_mastery.get(
				point, assessment.suggested_new_mastery),
			confidence=0.5,
			last_updated=timestamp,
		))
		touched_points.append(point)
	profile_model.advance_version()
	profile_dict = profile_model.to_dict()
	profile_dict["history"] = profile.get("history", []) + [
		MasteryHistory(assessment.old_mastery, assessment.suggested_new_mastery,
			[evidence_id], "assessment", timestamp).to_dict()]
	evidence = Evidence(evidence_id, "assessment", result_id,
		next(iter(assessment.per_knowledge_accuracy), "unknown"), "accuracy",
		assessment.score / 100, timestamp, 1.0).to_dict()
	profile_dict["evidence"] = profile.get("evidence", []) + [evidence]
	repository.save("profiles", user_id, profile_dict)
	repository.save("evidences", evidence_id, evidence)
	return profile_dict
