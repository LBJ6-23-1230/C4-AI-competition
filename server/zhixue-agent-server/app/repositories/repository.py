"""Persistence boundary used by domain and runtime layers."""

from abc import ABC, abstractmethod
from typing import Any


class Repository(ABC):
	@abstractmethod
	def get(self, collection: str, item_id: str) -> dict[str, Any] | None:
		...

	@abstractmethod
	def save(self, collection: str, item_id: str, value: dict[str, Any]) -> None:
		...

	@abstractmethod
	def list(self, collection: str) -> list[dict[str, Any]]:
		...

	@abstractmethod
	def delete(self, collection: str, item_id: str) -> None:
		...
