"""SQLite implementation of the repository boundary."""

import json
import sqlite3
from pathlib import Path
from typing import Any

from app.repositories.repository import Repository


class SQLiteRepository(Repository):
	def __init__(self, path: str | Path) -> None:
		self.path = str(path)
		with self._connect() as connection:
			connection.execute("""
				CREATE TABLE IF NOT EXISTS records (
					collection TEXT NOT NULL,
					item_id TEXT NOT NULL,
					value TEXT NOT NULL,
					PRIMARY KEY (collection, item_id)
				)
			""")

	def _connect(self) -> sqlite3.Connection:
		return sqlite3.connect(self.path)

	def get(self, collection: str, item_id: str) -> dict[str, Any] | None:
		with self._connect() as connection:
			row = connection.execute("SELECT value FROM records WHERE collection = ? AND item_id = ?",
				(collection, item_id)).fetchone()
		return json.loads(row[0]) if row else None

	def save(self, collection: str, item_id: str, value: dict[str, Any]) -> None:
		with self._connect() as connection:
			connection.execute("""
				INSERT INTO records(collection, item_id, value) VALUES (?, ?, ?)
				ON CONFLICT(collection, item_id) DO UPDATE SET value = excluded.value
			""", (collection, item_id, json.dumps(value, ensure_ascii=False)))

	def list(self, collection: str) -> list[dict[str, Any]]:
		with self._connect() as connection:
			rows = connection.execute("SELECT value FROM records WHERE collection = ? ORDER BY item_id",
				(collection,)).fetchall()
		return [json.loads(row[0]) for row in rows]

	def delete(self, collection: str, item_id: str) -> None:
		with self._connect() as connection:
			connection.execute("DELETE FROM records WHERE collection = ? AND item_id = ?",
				(collection, item_id))
