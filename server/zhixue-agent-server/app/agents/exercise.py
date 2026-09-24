"""Exercise orchestration agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult
from app.runtime.tool_registry import ToolRegistry, create_default_registry


class ExerciseAgent:
	name = "exercise"

	def __init__(self, registry: ToolRegistry | None = None) -> None:
		self.registry = registry or create_default_registry()

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		knowledge_point_id = state.get("knowledgePointId")
		selected = self.registry.execute("select_exercises", self.name, {
			"exercises": state.get("exercises", []),
			"knowledge_point_id": knowledge_point_id,
			"difficulty": state.get("difficulty"),
			"count": state.get("count", 3),
			"excluded_ids": state.get("excludedIds", []),
		})
		return AgentResult(self.name, {"exercises": selected}, ("select_exercises",))
