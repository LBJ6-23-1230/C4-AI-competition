"""Learning secretary agent."""

from collections.abc import Mapping
from typing import Any

from app.agents import AgentResult
from app.runtime.orchestrator import decide_next_step


class SecretaryAgent:
	name = "secretary"

	def run(self, state: Mapping[str, Any]) -> AgentResult:
		decision = decide_next_step(state)
		return AgentResult(self.name, {"nextStep": decision.step, "reason": decision.reason})
