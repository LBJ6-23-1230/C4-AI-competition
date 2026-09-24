"""Deterministic model fallback."""

from collections.abc import Mapping
from typing import Any

from app.model_adapters.llm import ModelAdapter
from app.runtime.orchestrator import fallback_decision


class FallbackAdapter(ModelAdapter):
	"""Return a strict JSON decision derived only from current state."""

	def complete(self, state: Mapping[str, Any]) -> None:
		return None

	def decide(self, state: Mapping[str, Any]) -> dict[str, Any]:
		decision = fallback_decision(state)
		return {"step": decision.step, "reason": decision.reason}
