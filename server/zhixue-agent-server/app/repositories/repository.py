"""Persistence boundary used by domain and runtime layers."""

# 注解延迟求值（PEP 563）。
# ⚠️ 必须有：本协议定义了名为 `list` 的方法，而 `ids()` 的返回注解写作 `list[str]`。
# 类体内立即求值时 `list` 解析到同名方法对象，导入期即报
# `TypeError: 'function' object is not subscriptable`。
from __future__ import annotations

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
	def ids(self, collection: str) -> list[str]:
		"""列出集合内的 item_id。

		为什么协议里需要它：`list()` 只回 value 不含主键，而"按归属删除"
		（`demo/reset`）必须知道要删哪个键。曾经只有 `JsonRepository` 实现了它，
		切到 SQLite 后端时 `demo/reset` 直接 AttributeError → 500。
		"""
		...

	@abstractmethod
	def delete(self, collection: str, item_id: str) -> None:
		...
