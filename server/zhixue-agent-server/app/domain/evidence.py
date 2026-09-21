"""Evidence and mastery history domain models."""

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from app.domain.profile import _parse_datetime


@dataclass
class Evidence:
	id: str
	source_type: str
	source_id: str
	knowledge_point_id: str
	metric: str
	value: Any
	timestamp: datetime
	reliability: float

	def __post_init__(self) -> None:
		if not self.id or not self.source_type or not self.source_id or not self.knowledge_point_id or not self.metric:
			raise ValueError("evidence identity fields are required")
		if not 0 <= self.reliability <= 1:
			raise ValueError("reliability must be between 0 and 1")
		self.timestamp = _parse_datetime(self.timestamp)

	def to_dict(self) -> dict[str, Any]:
		return {"id": self.id, "sourceType": self.source_type, "sourceId": self.source_id,
				"knowledgePointId": self.knowledge_point_id, "metric": self.metric, "value": self.value,
				"timestamp": self.timestamp.isoformat(), "reliability": self.reliability}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "Evidence":
		return cls(data["id"], data["sourceType"], data["sourceId"], data["knowledgePointId"],
				data["metric"], data.get("value"), data["timestamp"], data["reliability"])


@dataclass
class MasteryHistory:
	old_score: float
	new_score: float
	evidence_ids: list[str]
	source: str
	timestamp: datetime

	def __post_init__(self) -> None:
		if not 0 <= self.old_score <= 100 or not 0 <= self.new_score <= 100:
			raise ValueError("mastery scores must be between 0 and 100")
		self.timestamp = _parse_datetime(self.timestamp)

	def to_dict(self) -> dict[str, Any]:
		return {"oldScore": self.old_score, "newScore": self.new_score, "evidenceIds": list(self.evidence_ids),
				"source": self.source, "timestamp": self.timestamp.isoformat()}

	@classmethod
	def from_dict(cls, data: dict[str, Any]) -> "MasteryHistory":
		return cls(data["oldScore"], data["newScore"], list(data.get("evidenceIds", [])),
				data["source"], data["timestamp"])
