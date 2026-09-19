"""Learning path planning agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult
from app.runtime.tool_registry import ToolRegistry, create_default_registry


class PlannerAgent:
	name = "planner"

	def __init__(self, registry: ToolRegistry | None = None) -> None:
		self.registry = registry or create_default_registry()

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		if state.get("plan") is not None and state.get("needReplan"):
			result = self.registry.execute("replan_learning_path", self.name, {
				"old_plan": state["plan"], "state": state.get("replanState", {})})
			return AgentResult(self.name, result, ("replan_learning_path",))
		priorities = self.registry.execute("calculate_learning_priority", self.name, {
			"knowledge_points": list(state.get("knowledgePoints", [])),
			"context": dict(state.get("context", {})),
		})
		tasks = [{"knowledgePointId": item["knowledgePointId"], "durationMinutes": 30,
			"status": "pending"} for item in priorities]
		return AgentResult(self.name, {"plan": {"version": 1, "tasks": tasks},
			"priorities": priorities}, ("calculate_learning_priority",))
