"""Small durable JSON repository for the first local implementation."""

import json
import os
from pathlib import Path
from typing import Any

from app.repositories.repository import Repository


class JsonRepository(Repository):
	def __init__(self, path: str | Path) -> None:
		self.path = Path(path)
		self._data: dict[str, dict[str, dict[str, Any]]] = {}
		self._load()

	def _load(self) -> None:
		if self.path.exists():
			with self.path.open("r", encoding="utf-8") as stream:
				loaded = json.load(stream)
				if not isinstance(loaded, dict):
					raise ValueError("repository root must be an object")
				self._data = loaded

	def _flush(self) -> None:
		self.path.parent.mkdir(parents=True, exist_ok=True)
		temporary_path = self.path.with_suffix(self.path.suffix + ".tmp")
		with temporary_path.open("w", encoding="utf-8") as stream:
			json.dump(self._data, stream, ensure_ascii=False, indent=2)
			stream.write("\n")
		os.replace(temporary_path, self.path)

	def get(self, collection: str, item_id: str) -> dict[str, Any] | None:
		value = self._data.get(collection, {}).get(item_id)
		return dict(value) if value is not None else None

	def save(self, collection: str, item_id: str, value: dict[str, Any]) -> None:
		self._data.setdefault(collection, {})[item_id] = dict(value)
		self._flush()

	def list(self, collection: str) -> list[dict[str, Any]]:
		return [dict(value) for value in self._data.get(collection, {}).values()]

	def delete(self, collection: str, item_id: str) -> None:
		if item_id in self._data.get(collection, {}):
			del self._data[collection][item_id]
			self._flush()

	def clear(self, collection: str) -> None:
		if collection in self._data:
			del self._data[collection]
			self._flush()
