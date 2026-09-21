"""Structured learning agents."""

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class AgentResult:
	agent: str
	output: dict[str, Any]
	tool_calls: tuple[str, ...] = ()

	def to_dict(self) -> dict[str, Any]:
		return {"agent": self.agent, "output": dict(self.output),
				"toolCalls": list(self.tool_calls)}
