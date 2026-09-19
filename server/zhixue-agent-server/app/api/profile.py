from flask import Blueprint, jsonify

from app.repositories.json_repository import JsonRepository


profile_api = Blueprint("profile", __name__)
_repository: JsonRepository | None = None


def configure_profile_repository(repository: JsonRepository) -> None:
	global _repository
	_repository = repository


@profile_api.get("/api/v1/profile/<user_id>")
def get_profile(user_id: str):
	profile = _repository.get("profiles", user_id) if _repository else None
	if profile is None:
		return jsonify({"errorCode": "NOT_FOUND", "message": "profile not found", "details": {"userId": user_id}}), 404
	return jsonify({"profileVersion": profile.get("profileVersion", 1),
		"profile": profile, "mastery": profile.get("mastery", []),
		"history": profile.get("history", []), "evidence": profile.get("evidence", [])})
