"""Small durable JSON repository for the first local implementation."""

# 注解延迟求值（PEP 563）。
# ⚠️ 必须有：本类定义了名为 `list` 的方法，而 `ids()` 的返回注解写作 `list[str]`。
# 注解在类体内**立即求值**时，`list` 解析到的是同名方法对象，
# 于是报 `TypeError: 'function' object is not subscriptable`（导入期就炸，全测试收集失败）。
from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any

from app.repositories.repository import Repository


class JsonRepository(Repository):
	def __init__(self, path: str | Path) -> None:
		self.path = Path(path)
		self._data: dict[str, dict[str, dict[str, Any]]] = {}
		# 全量重写整个文件，本身就是一段临界区：必须串行化。
		# 见 `_flush()` 的说明（Windows 上并发 replace 会抛 WinError 5/32）。
		self._write_lock = threading.RLock()
		self._load()

	def _load(self) -> None:
		if self.path.exists():
			with self.path.open("r", encoding="utf-8") as stream:
				loaded = json.load(stream)
				if not isinstance(loaded, dict):
					raise ValueError("repository root must be an object")
				self._data = loaded

	def _flush(self) -> None:
		"""把整个仓库原子写回磁盘（**串行化**）。

		为什么必须加锁
		--------------
		本仓库每次保存都全量重写整个文件，所以写入天然是一段临界区。
		并发写会在 **Windows** 上以两种方式失败（都实测复现过）：

		1. 临时文件名固定 → 多方写同一个 `.tmp`，一方 `os.replace()` 时文件仍被占用
		   → `PermissionError: [WinError 32]`
		2. 临时文件名唯一后 → 仍然有多个 `os.replace()` 同时替换**同一个目标**文件
		   → `PermissionError: [WinError 5]`（拒绝访问）

		两种都会向上冒泡成 HTTP 500。经由 HTTP 并发提交时实测：
		**8 并发 88% 返回 500、10 并发 90% 返回 500**；repository 层用 barrier
		同步 8 线程 + 20KB payload 时 8 次里失败 4 次。
		前端"连点提交"或写卡片的定时刷新都可能踩中。

		修法：`_write_lock` 串行化「序列化 + 替换」整段；同时临时文件名仍保持唯一，
		这样即使将来出现跨进程访问（锁不跨进程）也不会共享同一个临时文件。
		"""
		import tempfile

		with self._write_lock:
			self.path.parent.mkdir(parents=True, exist_ok=True)
			handle, temporary_name = tempfile.mkstemp(
				dir=str(self.path.parent), prefix=self.path.name + ".", suffix=".tmp")
			try:
				with os.fdopen(handle, "w", encoding="utf-8") as stream:
					json.dump(self._data, stream, ensure_ascii=False, indent=2)
					stream.write("\n")
				os.replace(temporary_name, self.path)
			except BaseException:
				# 写失败时清掉自己的临时文件，避免在 data/ 下留垃圾
				try:
					os.unlink(temporary_name)
				except OSError:
					pass
				raise

	def get(self, collection: str, item_id: str) -> dict[str, Any] | None:
		value = self._data.get(collection, {}).get(item_id)
		return dict(value) if value is not None else None

	def save(self, collection: str, item_id: str, value: dict[str, Any]) -> None:
		# 内存状态与落盘必须在同一个临界区内完成。
		# 否则 `_flush()` 抛异常时内存已被改写、磁盘还是旧值，
		# 后续读请求会读到"写了但没存住"的状态（实测会击穿幂等语义）。
		with self._write_lock:
			self._data.setdefault(collection, {})[item_id] = dict(value)
			self._flush()

	def list(self, collection: str) -> list[dict[str, Any]]:
		return [dict(value) for value in self._data.get(collection, {}).values()]

	def ids(self, collection: str) -> list[str]:
		"""列出集合内的 item_id。

		为什么需要它：`list()` 只回 value 不含 key，调用方想"按归属删除"时
		拿不到主键（`demo/reset` 就卡在这里）。各集合的主键名不统一
		（traceId / submissionId / evidenceId / sessionId …），由调用方按需从
		value 里取，本方法只负责给出**权威的键集合**。
		"""
		return list(self._data.get(collection, {}).keys())

	def delete(self, collection: str, item_id: str) -> None:
		# 内存改动与落盘必须在同一临界区（与 save 同理）。
		# 原实现先判存在再 del，两步都在锁外：同键并发删除时，
		# 第二个线程会因键已被删而抛 KeyError → 冒泡成 500。
		with self._write_lock:
			if item_id in self._data.get(collection, {}):
				del self._data[collection][item_id]
				self._flush()

	def clear(self, collection: str) -> None:
		with self._write_lock:
			if collection in self._data:
				del self._data[collection]
				self._flush()
