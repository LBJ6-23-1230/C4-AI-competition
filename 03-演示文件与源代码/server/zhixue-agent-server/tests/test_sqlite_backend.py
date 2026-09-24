# -*- coding: utf-8 -*-
"""SQLite 可选后端与 `Repository` 契约一致性测试。

背景
----
`JsonRepository` 每次 `save()` 全量重写整个 JSON 文件，实测代价随数据量线性增长：

| 已存记录 | JSON 单次 save | SQLite 单次 save |
|---|---|---|
| 50 条  | 5.60 ms  | 0.04 ms |
| 200 条 | 14.02 ms | 0.03 ms |
| 800 条 | 52.37 ms | 0.03 ms |

（`save×200` 总量：JSON 1640.9 ms vs SQLite 13.1 ms，**约 125 倍**）

因此 `app/__init.py` 提供 `ZHIXUE_DB` 选择后端。本文件保证：
1. 两个后端满足**同一套 `Repository` 契约**（同输入同输出）
2. `create_app()` 在 `ZHIXUE_DB=sqlite` 下能真正跑起来且行为一致
3. 迁移工具能把 JSON 数据无损搬过去

> 默认测试套件走 JSON（`tests/conftest.py` 会清掉 `ZHIXUE_DB`），
> SQLite 路径由本文件**显式**覆盖，避免"开发机设了变量就结果不同"。
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from app import create_app
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository

SERVER_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = SERVER_DIR.parents[1]


@pytest.fixture(params=["json", "sqlite"])
def repository(request, tmp_path):
    """同一套断言跑两个后端。"""
    if request.param == "json":
        repo = JsonRepository(tmp_path / "repo.json")
    else:
        repo = SQLiteRepository(tmp_path / "repo.sqlite")
    yield repo
    close = getattr(repo, "close", None)
    if callable(close):
        close()


# ===========================================================================
# 1) Repository 契约一致性
# ===========================================================================
def test_save_then_get_roundtrip(repository):
    payload = {"userId": "demo-user", "goal": "数据结构考试80+",
               "mastery": [{"knowledgePointId": "binary-tree-postorder", "masteryScore": 42}]}
    repository.save("profiles", "demo-user", payload)
    assert repository.get("profiles", "demo-user") == payload


def test_get_missing_returns_none(repository):
    assert repository.get("profiles", "not-there") is None


def test_save_overwrites_existing(repository):
    repository.save("profiles", "u1", {"v": 1})
    repository.save("profiles", "u1", {"v": 2})
    assert repository.get("profiles", "u1") == {"v": 2}


def test_list_is_scoped_to_collection(repository):
    repository.save("profiles", "a", {"c": "profiles"})
    repository.save("plans", "b", {"c": "plans"})
    rows = repository.list("profiles")
    assert rows == [{"c": "profiles"}]


def test_delete_removes_only_target(repository):
    repository.save("profiles", "a", {"v": 1})
    repository.save("profiles", "b", {"v": 2})
    repository.delete("profiles", "a")
    assert repository.get("profiles", "a") is None
    assert repository.get("profiles", "b") == {"v": 2}


def test_clear_empties_collection_only(repository):
    repository.save("traces", "t1", {"v": 1})
    repository.save("profiles", "p1", {"v": 1})
    repository.clear("traces")
    assert repository.list("traces") == []
    assert repository.get("profiles", "p1") == {"v": 1}


def test_unicode_and_nested_values_survive(repository):
    payload = {"标题": "二叉树后序遍历", "nested": {"列表": [1, 2, {"深": "值"}]},
               "emoji": "✓"}
    repository.save("profiles", "u-中文", payload)
    assert repository.get("profiles", "u-中文") == payload


def test_json_string_is_stored_verbatim_not_double_encoded(repository, tmp_path):
    """值里出现引号/换行也不能被二次编码。"""
    payload = {"text": '带"引号"和\n换行的内容'}
    repository.save("profiles", "u2", payload)
    assert repository.get("profiles", "u2") == payload


# ===========================================================================
# 2) ZHIXUE_DB 选择后端
# ===========================================================================
def test_default_backend_is_json(tmp_path, monkeypatch):
    monkeypatch.delenv("ZHIXUE_DB", raising=False)
    app = create_app(tmp_path / "default.json")
    assert app.test_client().get("/api/v1/profile/demo-user").status_code == 200
    assert (tmp_path / "default.json").exists()


def test_sqlite_backend_creates_sqlite_file(tmp_path, monkeypatch):
    monkeypatch.setenv("ZHIXUE_DB", "sqlite")
    create_app(tmp_path / "chosen.json")
    # sqlite 文件名派生自传入的数据路径，避免测试之间互相污染
    db = tmp_path / "chosen.sqlite"
    assert db.exists(), "未按数据路径派生出 sqlite 文件"
    with sqlite3.connect(db) as connection:
        tables = {row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
    assert "records" in tables


def test_sqlite_backend_explicit_path(tmp_path, monkeypatch):
    target = tmp_path / "custom" / "mydata.sqlite"
    monkeypatch.setenv("ZHIXUE_DB", f"sqlite:{target}")
    create_app(tmp_path / "ignored.json")
    assert target.exists()


def test_unknown_backend_is_rejected(tmp_path, monkeypatch):
    monkeypatch.setenv("ZHIXUE_DB", "postgres")
    with pytest.raises(ValueError, match="ZHIXUE_DB"):
        create_app(tmp_path / "x.json")


# ===========================================================================
# 3) SQLite 后端下的演示基线必须与 JSON 一致
# ===========================================================================
def _baseline(base_url: str, backend_name: str):
    import urllib.request

    def call(method, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(f"{base_url}{path}", data=data, method=method,
                                     headers={"Content-Type": "application/json",
                                              "X-API-Contract-Version": "api-contract-v0.3"})
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))

    call("POST", "/api/v1/demo/reset")
    # 注意三个必填细节（都踩过）：
    #   · 答案字段是 `exerciseId`（不是 questionId）
    #   · `idempotencyKey` 为必填（缺了直接 400）
    #   · A/B/A 对应 √√× → score 66.67
    submission = call("POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                      {"idempotencyKey": f"baseline-{backend_name}",
                       "answers": [
                           {"exerciseId": "exercise-preorder-001", "answer": "A"},
                           {"exerciseId": "exercise-inorder-001", "answer": "B"},
                           {"exerciseId": "exercise-postorder-001", "answer": "A"},
                       ]})
    profile = call("GET", "/api/v1/profile/demo-user")
    plan = call("GET", "/api/v1/plans/current")
    return {
        "score": submission["assessment"]["score"],
        "mastery": [k["masteryScore"] for k in profile["mastery"]][:1],
        "profileVersion": profile["profileVersion"],
        "planVersion": plan["version"],
    }


@pytest.mark.parametrize("backend", ["json", "sqlite"])
def test_demo_baseline_identical_across_backends(backend, tmp_path):
    """两个后端下演示主链数字必须一致（66.67 / 42→58 / 版本 1→2）。

    在**子进程**里起真实服务器，因为要复用真实 HTTP 主链。
    """
    import socket

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    script = textwrap.dedent(f"""
        import json, os, sys
        sys.path.insert(0, r"{SERVER_DIR}")
        os.environ["ZHIXUE_DB"] = {backend!r}
        os.environ["ZHIXUE_REPOSITORY"] = r"{tmp_path / 'baseline.json'}"
        os.environ["DASHSCOPE_API_KEY"] = ""
        os.environ["ZHIXUE_QUIET"] = "1"
        from app import create_app
        app = create_app()
        app.run(host="127.0.0.1", port={port}, debug=False, use_reloader=False)
    """)
    process = subprocess.Popen([sys.executable, "-c", script], cwd=str(SERVER_DIR),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    import time
    import urllib.error
    import urllib.request

    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(60):
            try:
                with urllib.request.urlopen(f"{base}/health", timeout=2):
                    break
            except Exception:  # noqa: BLE001
                time.sleep(0.3)
        else:
            pytest.fail(f"{backend} 后端未能在 18 秒内启动")

        result = _baseline(base, backend)
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()

    assert result["score"] == 66.67, f"{backend}: score 漂移 {result}"
    assert result["mastery"] == [58], f"{backend}: mastery 漂移 {result}"
    assert result["profileVersion"] == 2, f"{backend}: profileVersion 漂移 {result}"
    assert result["planVersion"] == 2, f"{backend}: planVersion 漂移 {result}"


# ===========================================================================
# 4) 迁移工具
# ===========================================================================
def test_migration_script_roundtrip(tmp_path):
    """JSON -> SQLite 迁移后逐条一致，且**不改动源文件**。"""
    json_path = tmp_path / "src.json"
    sqlite_path = tmp_path / "dst.sqlite"
    original = {
        "profiles": {"demo-user": {"userId": "demo-user", "profileVersion": 1},
                     "u-x": {"userId": "u-x", "profileVersion": 3}},
        "plans": {"plan-demo-001": {"planId": "plan-demo-001", "version": 1}},
        "traces": {"t1": {"traceId": "t1", "events": []}},
    }
    json_path.write_text(json.dumps(original, ensure_ascii=False, indent=2), encoding="utf-8")
    before = json_path.read_bytes()

    script = PROJECT_ROOT / "tools" / "migrate_repository.py"
    # ⚠️ 必须强制子进程用 UTF-8 输出。
    #
    # 子进程的 stdout 编码取自本地代码页：中文 Windows 上是 cp936(GBK)，
    # 而迁移脚本会打印中文（"全部一致"）。父进程按 utf-8 解码时会在
    # 读取线程里抛 UnicodeDecodeError，`proc.stdout` 直接变成 None，
    # 于是断言报 `TypeError: argument of type 'NoneType' is not iterable` ——
    # 表现为"中文 Windows 上跑 pytest 必挂一项"，而开发机（UTF-8 环境）全绿。
    # 受控实验：`PYTHONUTF8=1 pytest` 全绿、不设则 1 failed，已复现。
    child_env = {**os.environ, "PYTHONIOENCODING": "utf-8"}
    proc = subprocess.run(
        [sys.executable, str(script), "--json", str(json_path), "--sqlite", str(sqlite_path),
         "--verify"],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=child_env, cwd=str(PROJECT_ROOT))

    assert proc.returncode == 0, f"迁移失败:\n{proc.stdout}\n{proc.stderr}"
    assert "全部一致" in proc.stdout
    assert json_path.read_bytes() == before, "迁移不应修改源文件"

    with sqlite3.connect(sqlite_path) as connection:
        rows = dict(connection.execute(
            "SELECT collection || '/' || item_id, value FROM records").fetchall())
    assert json.loads(rows["profiles/demo-user"]) == original["profiles"]["demo-user"]
    assert json.loads(rows["plans/plan-demo-001"]) == original["plans"]["plan-demo-001"]
    assert len(rows) == 4


def test_sqlite_repository_connection_is_reused(tmp_path):
    """回归：每次方法调用都新开连接会让 `save` 慢几个数量级。

    实测症状：1280 次 save **超过 120 秒**（每次连接都执行 `PRAGMA journal_mode=WAL`）。
    现在改为单长连接 + 一次性 PRAGMA。本测试用"200 次 save 的墙钟时间"约束，
    阈值取得很宽松（5 秒），只用于抓"退回每调用一连接"这类灾难性回退。
    """
    import time

    repo = SQLiteRepository(tmp_path / "reuse.sqlite")
    payload = {"userId": "u", "mastery": [{"i": i} for i in range(20)]}
    try:
        start = time.perf_counter()
        for i in range(200):
            repo.save("profiles", f"u-{i}", {**payload, "index": i})
        elapsed = time.perf_counter() - start
    finally:
        repo.close()

    assert elapsed < 5.0, f"200 次 save 用了 {elapsed:.2f}s —— 连接/PRAGMA 可能被退回成每次新建"
