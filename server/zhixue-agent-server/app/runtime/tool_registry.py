"""Agent tool registration and permission boundary."""

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from app.decision.priority import calculate_learning_priority
from app.decision.replan_rules import replan_learning_path, should_replan
from app.tools.assessment_tools import grade_exercise, update_mastery
from app.tools.exercise_tools import select_exercises
from app.tools.plan_tools import build_plan_diff, create_plan_history


class ToolError(Exception):
	"""A safe, structured error raised at the tool boundary."""

	def __init__(self, code: str, message: str) -> None:
		self.code = code
		self.message = message
		super().__init__(message)

	def to_dict(self) -> dict[str, str]:
		return {"errorCode": self.code, "message": self.message}


@dataclass(frozen=True)
class ToolDefinition:
	name: str
	schema: dict[str, Any]
	handler: Callable[..., Any]
	allowed_agents: frozenset[str]


class ToolRegistry:
	"""Register tools once and enforce agent permissions on every call."""

	def __init__(self) -> None:
		self._tools: dict[str, ToolDefinition] = {}

	def register(self, name: str, schema: Mapping[str, Any], handler: Callable[..., Any],
				allowed_agents: set[str] | frozenset[str] | list[str] | tuple[str, ...]) -> ToolDefinition:
		if not name:
			raise ValueError("tool name is required")
		if name in self._tools:
			raise ValueError(f"tool already registered: {name}")
		if not callable(handler):
			raise TypeError("tool handler must be callable")
		definition = ToolDefinition(name, dict(schema), handler, frozenset(allowed_agents))
		self._tools[name] = definition
		return definition

	def get(self, name: str) -> ToolDefinition:
		try:
			return self._tools[name]
		except KeyError as error:
			raise ToolError("TOOL_NOT_FOUND", f"unknown tool: {name}") from error

	def list(self) -> list[ToolDefinition]:
		return list(self._tools.values())

	def execute(self, name: str, agent: str, arguments: Mapping[str, Any] | None = None) -> Any:
		definition = self.get(name)
		if agent not in definition.allowed_agents:
			raise ToolError("TOOL_FORBIDDEN", f"agent {agent} cannot call {name}")
		try:
			return definition.handler(**dict(arguments or {}))
		except ToolError:
			raise
		except Exception as error:
			raise ToolError("TOOL_FAILED", f"tool execution failed: {name}") from error


def create_default_registry() -> ToolRegistry:
	"""Create the registry for the deterministic tools available in this phase."""
	registry = ToolRegistry()
	registry.register("calculate_learning_priority", {"type": "object"},
					 calculate_learning_priority, {"planner", "secretary"})
	registry.register("select_exercises", {"type": "object"}, select_exercises, {"exercise"})
	registry.register("grade_exercise", {"type": "object"}, grade_exercise, {"assessment"})
	registry.register("update_mastery", {"type": "object"}, update_mastery, {"assessment"})
	registry.register("should_replan", {"type": "object"}, should_replan, {"planner", "secretary"})
	registry.register("replan_learning_path", {"type": "object"},
					 replan_learning_path, {"planner"})
	registry.register("build_plan_diff", {"type": "object"}, build_plan_diff, {"planner", "secretary"})
	registry.register("create_plan_history", {"type": "object"},
					 create_plan_history, {"planner"})
	return registry
