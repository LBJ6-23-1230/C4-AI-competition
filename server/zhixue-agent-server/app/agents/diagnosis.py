"""Learning diagnosis agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult


class DiagnosisAgent:
	name = "diagnosis"

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		weak_points: dict[str, dict[str, Any]] = {}
		error_types: list[str] = []
		for evidence in state.get("evidence", []):
			knowledge_point_id = evidence.get("knowledgePointId")
			if not knowledge_point_id:
				continue
			item = weak_points.setdefault(knowledge_point_id, {"knowledgePointId": knowledge_point_id,
				"errorCount": 0, "errorTypes": []})
			item["errorCount"] += 1
			error_type = evidence.get("errorType")
			if error_type and error_type not in item["errorTypes"]:
				item["errorTypes"].append(error_type)
			if error_type and error_type not in error_types:
				error_types.append(error_type)
		return AgentResult(self.name, {"weakPoints": list(weak_points.values()),
			"errorTypes": error_types, "urgency": state.get("urgency", 0)})
