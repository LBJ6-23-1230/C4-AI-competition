# -*- coding: utf-8 -*-
"""测试公共 fixture。

本文件包含两部分，来源不同、都必须保留：

1. `isolate_external_llm`（后端同学所写）
   即使本机 `.env` 配了真实 Key，也强制测试期用空 Key，
   保证测试结果不受外部模型影响。

2. `tmp_path` / `tmp_path_factory`（联调环境所需）
   pytest 内置的 `tmp_path` 通过 `getbasetemp()` 在系统临时根目录建目录，
   在受限文件沙箱下会抛 `PermissionError: [WinError 5]`，
   导致 47 项测试变成红色 error、整套测试结果不可信。
   因此把基准目录改到工程内的 `tests/.pytest-tmp/`。

   还必须**每次运行使用独立的会话目录**（见下），否则会出现跨运行脏数据。
"""

import os
import re
import time

import pytest


@pytest.fixture(autouse=True)
def isolate_external_llm(monkeypatch):
	"""Keep the test suite deterministic even when the local .env has a real key."""
	monkeypatch.setenv("DASHSCOPE_API_KEY", "")


@pytest.fixture(autouse=True)
def isolate_repository_backend(monkeypatch):
	"""测试一律走默认的 JSON 后端，不受外部 `ZHIXUE_DB` 影响。

	为什么必须隔离：`ZHIXUE_DB=sqlite` 是**进程级**环境变量。若开发机或 CI 上
	设了它，整个测试套件会切到 SQLite，而：
	* `tmp_path` 给的是目录，默认 sqlite 文件名派生自 JSON 路径 → 多个测试
	  可能落到同一个库里互相污染
	* 更重要的是**结果不可复现**：同一份代码在有无该变量时表现不同

	SQLite 后端由 `tests/test_sqlite_backend.py` 用**显式子进程**覆盖，
	那里会主动带上 `ZHIXUE_DB=sqlite`，因此不会漏测。
	"""
	monkeypatch.delenv("ZHIXUE_DB", raising=False)


@pytest.fixture(autouse=True)
def isolate_chat_history(tmp_path_factory, monkeypatch):
	"""把对话历史重定向到测试临时目录，**别写进交付包**。

	为什么必须隔离（实测出来的）
	--------------------------
	`chat/history.json` 的可写路径原先写死在 `chat_llm._CHAT_DIR`。
	而 `tests/test_technical_improvements.py` 里有几个用例会真的走
	`POST /api/agent/chat`、再 `DELETE /api/agent/history` —— 于是
	**每跑一次 pytest，交付包的 `chat/history.json` 就被写一次**。

	受控实验（先清成 `{"demo-user": []}`，再单独执行）::

	    复位后     23 B   分桶={'demo-user': 0}
	    跑 pytest  1,100 B 分桶={'demo-user': 2, 'user-a': 0, 'user-b': 1}   ← pytest 写的
	    跑联调     1,100 B 不变（联调已用 ZHIXUE_CHAT_DIR 重定向）

	同样的机制在队友那份交付物里留下了
	**18,162 B / 5 个分桶**（`demo-user` / `user-a` / `user-b` / `probe-a` / `probe-b`）。

	这里用 `tmp_path_factory`（会话级、每次运行独立目录）而不是 `tmp_path`：
	后者是函数级，每个用例都会换目录，会让"跨用例的历史累积"类断言失效。
	"""
	directory = tmp_path_factory.mktemp("chat-history", numbered=False)
	monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(directory))


# --------------------------------------------------------------------------
# 沙箱可写的 tmp_path（覆盖 pytest 内置实现）
#
# 为什么基准目录必须"每次运行独立"：
# 若固定分配 test1 / test2 …，上一次运行写下的文件（例如
# `create_app(tmp_path / "events.json")` 生成的 events.json）仍在原地。
# `JsonRepository._load()` 会读到那份陈旧文件，`EventStore.append`
# 再往上追加，于是
# test_event_store_appends_trace_events_with_runtime_versions
# 拿到两个事件而不是一个 —— 这是测试污染，不是产品缺陷。
#
# 清理说明：刻意不去删除历史会话目录。`shutil.rmtree` 在受限环境下会抛
# 与 pytest 自身清理相同的 PermissionError，而在 fixture 里抛异常比留下
# 几个小 JSON 文件更糟。每次运行独立目录已足以保证正确性。
# --------------------------------------------------------------------------

_BASE = None


def _base_dir():
	global _BASE
	if _BASE is None:
		from pathlib import Path

		root = Path(__file__).resolve().parent / ".pytest-tmp"
		root.mkdir(parents=True, exist_ok=True)
		_BASE = root
	return _BASE


@pytest.fixture(scope="session")
def tmp_path_factory():
	from pathlib import Path

	worker = re.sub(r"[^A-Za-z0-9_.-]", "_", os.environ.get("PYTEST_XDIST_WORKER", "local"))
	pid = os.getpid()
	stamp = time.strftime("%Y%m%d-%H%M%S")
	root = Path(_base_dir()) / f"run-{worker}-{pid}-{stamp}"
	root.mkdir(parents=True, exist_ok=True)
	counter = {"n": 0}

	class _Factory:
		def mktemp(self, basename, numbered=True):
			counter["n"] += 1
			name = f"{basename}{counter['n']}" if numbered else basename
			path = root / name
			path.mkdir(parents=True, exist_ok=True)
			return path

		def getbasetemp(self):
			return root

	return _Factory()


@pytest.fixture
def tmp_path(tmp_path_factory):
	return tmp_path_factory.mktemp("test")
