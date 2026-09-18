"""Model adapter contracts and safe structured-output parsing."""

from abc import ABC, abstractmethod
from collections.abc import Mapping
from typing import Any


class ModelAdapterError(Exception):
	"""A recoverable model failure that must not mutate workflow state."""


class ModelAdapter(ABC):
	@abstractmethod
	def complete(self, state: Mapping[str, Any]) -> str | None:
		"""Return the model response for an observable workflow state."""

	def decide(self, state: Mapping[str, Any]) -> dict[str, Any]:
		import json

		try:
			value = json.loads(self.complete(state))
		except (TypeError, ValueError, json.JSONDecodeError) as error:
			raise ModelAdapterError("model returned invalid JSON") from error
		if not isinstance(value, dict) or not isinstance(value.get("step"), str):
			raise ModelAdapterError("model decision must contain a step")
		return value

	def safe_decide(self, state: Mapping[str, Any]) -> dict[str, Any] | None:
		try:
			return self.decide(state)
		except ModelAdapterError:
			return None
