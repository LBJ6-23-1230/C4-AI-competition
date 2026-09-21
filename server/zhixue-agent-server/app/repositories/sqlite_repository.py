"""SQLite implementation of the repository boundary.

为什么保留这个实现
------------------
`JsonRepository` 每次 `save()` 都**全量重写整个 JSON 文件**。实测后果：

* `data/repository.json` 随账号数线性膨胀（反复联调后被撑到 **324 KB**，
  干净演示基线只要 38 KB），单次 save 约 30ms
* 双进程同时写同一文件时有 **5–19%** 失败率（进程内 `threading.RLock`
  跨不了进程）

SQLite 版每次只写一行，且并发由数据库自身保证。它是**可选后端**（见
`app/__init__.py` 的 `ZHIXUE_DB`），默认仍走 JSON —— 因为 JSON 文件可以
直接肉眼查看、便于答辩演示与人工核对，而 SQLite 更适合数据量增长后的场景。

迁移：
    python tools/migrate_repository.py            # JSON -> SQLite
    $env:ZHIXUE_DB="sqlite"; python run.py        # 用 SQLite 启动
"""

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any

from app.repositories.repository import Repository


class SQLiteRepository(Repository):
	"""基于单表 `records` 的仓储实现，行为与 `JsonRepository` 对齐。

	表结构刻意做成通用的 `(collection, item_id, value)` 三元组，
	而不是为每个集合建一张表 —— 这样两层（`/api/agent/*` 与 `/api/v1/**`）
	新增集合时不需要改 schema，与既有的 `Repository` 抽象保持一致。

	连接管理（实测踩过的坑）
	------------------------
	最初每个方法都 `sqlite3.connect()` 新开连接，并在 `_connect()` 里执行
	`PRAGMA journal_mode=WAL`。后果是**每次读写都要切换 journal 模式并 fsync**，
	基准测试（1280 次 save）**超过 120 秒**都没跑完 —— 比 JSON 版慢了几个数量级，
	完全违背"换 SQLite 是为了快"的初衷。

	现在改为：**单个长连接 + 一次性初始化 PRAGMA + 可重入锁串行化**。
	`check_same_thread=False` 允许 Flask 的多线程共用该连接，锁保证同一时刻
	只有一个线程在写（SQLite 本身也不支持并行写）。
	"""

	def __init__(self, path: str | Path) -> None:
		self.path = str(path)
		parent = Path(self.path).parent
		if str(parent):
			parent.mkdir(parents=True, exist_ok=True)
		self._lock = threading.RLock()
		self._connection = sqlite3.connect(self.path, timeout=15.0,
										  check_same_thread=False)
		# 只在这里设置一次。`journal_mode` 是**持久化**属性（写进库文件头），
		# 重复设置纯属浪费；`synchronous` 是连接级属性，设一次就够。
		self._connection.execute("PRAGMA journal_mode=WAL")
		self._connection.execute("PRAGMA synchronous=NORMAL")
		self._connection.execute("PRAGMA busy_timeout=15000")
		with self._lock:
			self._connection.execute("""
				CREATE TABLE IF NOT EXISTS records (
					collection TEXT NOT NULL,
					item_id TEXT NOT NULL,
					value TEXT NOT NULL,
					PRIMARY KEY (collection, item_id)
				)
			""")
			# 按集合查询是最高频操作（`list()`），补一个索引。
			self._connection.execute(
				"CREATE INDEX IF NOT EXISTS idx_records_collection ON records(collection)")
			self._connection.commit()

	def close(self) -> None:
		with self._lock:
			self._connection.close()

	def get(self, collection: str, item_id: str) -> dict[str, Any] | None:
		with self._lock:
			row = self._connection.execute(
				"SELECT value FROM records WHERE collection = ? AND item_id = ?",
				(collection, item_id)).fetchone()
		return json.loads(row[0]) if row else None

	def save(self, collection: str, item_id: str, value: dict[str, Any]) -> None:
		payload = json.dumps(value, ensure_ascii=False)
		with self._lock:
			self._connection.execute("""
				INSERT INTO records(collection, item_id, value) VALUES (?, ?, ?)
				ON CONFLICT(collection, item_id) DO UPDATE SET value = excluded.value
			""", (collection, item_id, payload))
			self._connection.commit()

	def list(self, collection: str) -> list[dict[str, Any]]:
		with self._lock:
			rows = self._connection.execute(
				"SELECT value FROM records WHERE collection = ? ORDER BY item_id",
				(collection,)).fetchall()
		return [json.loads(row[0]) for row in rows]

	def delete(self, collection: str, item_id: str) -> None:
		with self._lock:
			self._connection.execute(
				"DELETE FROM records WHERE collection = ? AND item_id = ?",
				(collection, item_id))
			self._connection.commit()

	def clear(self, collection: str) -> None:
		"""清空整个集合。

		与 `JsonRepository.clear()` 同名同义 —— `demo/reset` 与
		`auth` 的会话清理都依赖它，缺了会在切换到 SQLite 后直接 AttributeError。
		"""
		with self._lock:
			self._connection.execute("DELETE FROM records WHERE collection = ?",
									 (collection,))
			self._connection.commit()
