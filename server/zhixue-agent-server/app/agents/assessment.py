"""Learning assessment agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult
from app.runtime.tool_registry import ToolRegistry, create_default_registry


class AssessmentAgent:
	name = "assessment"

	def __init__(self, registry: ToolRegistry | None = None) -> None:
		self.registry = registry or create_default_registry()

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		assessment = self.registry.execute("grade_exercise", self.name, {
			"answers": state.get("answers", []), "answer_keys": state.get("answerKeys", {}),
			"knowledge_points": state.get("knowledgePointsByExercise", {}),
			"old_mastery": state.get("oldMastery", 0),
			"exercise_result_id": state.get("exerciseResultId"),
		})
		mastery = self.registry.execute("update_mastery", self.name, {
			"old_score": assessment.old_mastery, "assessment_score": assessment.score,
		})
		output = assessment.to_dict()
		output["suggestedNewMastery"] = mastery
		return AgentResult(self.name, output, ("grade_exercise", "update_mastery"))
