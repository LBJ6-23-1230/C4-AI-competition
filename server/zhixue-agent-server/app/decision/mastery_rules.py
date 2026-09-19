"""Pure mastery decision helpers shared by assessment workflows."""


def is_mastery_below_threshold(score: int | float, threshold: int | float = 60) -> bool:
	if not 0 <= score <= 100:
		raise ValueError("score must be between 0 and 100")
	if not 0 <= threshold <= 100:
		raise ValueError("threshold must be between 0 and 100")
	return score < threshold


def mastery_band(score: int | float) -> str:
	if not 0 <= score <= 100:
		raise ValueError("score must be between 0 and 100")
	if score < 60:
		return "weak"
	if score < 80:
		return "developing"
	return "mastered"
