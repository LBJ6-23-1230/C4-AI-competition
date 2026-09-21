# -*- coding: utf-8 -*-
"""对话历史路径重定向的回归测试。

背景（受控实验测出来的真实缺陷）
--------------------------------
`chat/history.json` 的可写路径原先写死在 `chat_llm._CHAT_DIR`，于是：

* **每跑一次 pytest**，交付包的 `chat/history.json` 就被写一次
  （`test_technical_improvements.py` 里有用例真的走 `/api/agent/chat` 与
  `DELETE /api/agent/history`）
* 队友交付的那份累积到 **18,162 B / 5 个分桶**
  （`demo-user` / `user-a` / `user-b` / `probe-a` / `probe-b`）

现在 `chat_llm._history_path()` 支持 `ZHIXUE_CHAT_DIR` 重定向，
联调脚本与 `tests/conftest.py` 都会设置它。

本文件固化三件事：
1. 未设 `ZHIXUE_CHAT_DIR` 时，路径回落到包内 `chat/`（保证交付包自足）
2. 设了它之后，**写入只落在重定向目录**，包内文件不被触碰
3. `prompts/` 与 mock 数据**仍从包内读取**（它们是只读资源，不该被重定向）
"""

from __future__ import annotations

import json
import pathlib

import pytest

from app.agent import chat_llm


def _packaged_history() -> pathlib.Path:
    return chat_llm._CHAT_DIR / "history.json"


def _fingerprint(path: pathlib.Path):
    if not path.exists():
        return None
    return (path.stat().st_size, path.read_bytes())


def test_history_path_falls_back_to_packaged_dir(monkeypatch):
    """未设环境变量时，回落到包内 chat/ —— 交付包必须自足。"""
    monkeypatch.delenv("ZHIXUE_CHAT_DIR", raising=False)
    assert chat_llm._history_path() == _packaged_history()


def test_history_path_honours_override(monkeypatch, tmp_path):
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    got = chat_llm._history_path()
    assert got.parent == tmp_path / "redirected"
    # 目录会被自动创建（否则 append 会失败）
    assert got.parent.is_dir()


def test_blank_override_falls_back(monkeypatch):
    """空白字符串不算有效覆盖 —— 否则会解析成当前目录，行为很意外。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", "   ")
    assert chat_llm._history_path() == _packaged_history()


def test_append_does_not_touch_packaged_history(monkeypatch, tmp_path):
    """核心回归：重定向后，append 不能碰包内那份文件。"""
    before = _fingerprint(_packaged_history())

    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    chat_llm.append_history("回归测试输入", "回归测试回复", "regression-user")

    assert _fingerprint(_packaged_history()) == before, (
        "包内 chat/history.json 被 append 改动了 —— 说明 ZHIXUE_CHAT_DIR 重定向失效"
        "（这正是之前每跑一次 pytest 就污染交付包的原因）"
    )
    redirected = tmp_path / "redirected" / "history.json"
    assert redirected.exists(), "写入没有落到重定向目录"
    assert "回归测试输入" in redirected.read_text(encoding="utf-8")


def test_clear_does_not_touch_packaged_history(monkeypatch, tmp_path):
    """重定向后，clear 也只能清重定向那份。

    注意 `clear_history` 对**不存在的键是 no-op**（不落盘），所以这里先 append
    建出内容，再 clear，才能观察到"清掉了"且"包内没动"。
    """
    before = _fingerprint(_packaged_history())

    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    chat_llm.clear_history("regression-user")
    chat_llm.append_history("待清除", "回复", "regression-user")
    assert chat_llm.get_history("regression-user"), "前置条件：应当已写入"

    chat_llm.clear_history("regression-user")

    assert chat_llm.get_history("regression-user") == [], "重定向那份没被清掉"
    assert _fingerprint(_packaged_history()) == before, (
        "包内 chat/history.json 被 clear 改动了 —— 重定向失效"
    )


def test_clear_missing_key_is_noop_and_creates_no_file(monkeypatch, tmp_path):
    """对不存在的用户 clear：不报错，也不创建文件（避免无意义落盘）。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    chat_llm.clear_history("never-existed")
    assert not (tmp_path / "redirected" / "history.json").exists()


def test_redirected_writes_are_readable_back(monkeypatch, tmp_path):
    """重定向后读写同一份，语义不变。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    chat_llm.clear_history("u-roundtrip")
    chat_llm.append_history("问题", "回答", "u-roundtrip")
    rows = chat_llm.get_history("u-roundtrip")
    assert [r["user_input"] for r in rows] == ["问题"]


def test_readonly_resources_still_come_from_package(monkeypatch, tmp_path):
    """prompts/ 与 mock 数据是只读资源，不该跟着被重定向。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    # _CHAT_DIR / _PROMPT_DIR 是模块级常量，不受环境变量影响
    assert chat_llm._PROMPT_DIR == chat_llm._CHAT_DIR / "prompts"
    assert chat_llm._PROMPT_DIR.is_dir(), "包内 prompts/ 目录应存在"
    assert (chat_llm._CHAT_DIR / "mock_courses.json").exists()


def test_history_file_is_keyed_by_user(monkeypatch, tmp_path):
    """分桶存储：不同用户写到同一个重定向文件的不同键下。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    chat_llm.clear_history("bucket-a")
    chat_llm.clear_history("bucket-b")
    chat_llm.append_history("甲", "回甲", "bucket-a")
    chat_llm.append_history("乙", "回乙", "bucket-b")

    raw = json.loads((tmp_path / "redirected" / "history.json").read_text(encoding="utf-8"))
    assert set(raw) >= {"bucket-a", "bucket-b"}
    assert [e["user_input"] for e in raw["bucket-a"]] == ["甲"]
    assert [e["user_input"] for e in raw["bucket-b"]] == ["乙"]


# ===========================================================================
# mock_wrong_questions.json 也是**会被写入**的数据文件，同属污染面
#
# 实测：队友交付的那份累积到 26 项，比基线（15 项）多出 11 项
# `u001_UUID` / `u001_20260722164206` 之类的测试生成记录。
# ===========================================================================
def _packaged_wrong_questions() -> pathlib.Path:
    return chat_llm._CHAT_DIR / "mock_wrong_questions.json"


def test_load_json_prefers_redirected_dir(monkeypatch, tmp_path):
    """读顺序：重定向目录优先，没有才回落包内。"""
    redirected = tmp_path / "redirected"
    redirected.mkdir(parents=True, exist_ok=True)
    (redirected / "probe.json").write_text('[{"from": "redirected"}]', encoding="utf-8")

    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(redirected))
    assert chat_llm._load_json("probe.json", []) == [{"from": "redirected"}]

    # 重定向目录里没有 → 回落包内
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "empty"))
    assert chat_llm._load_json("mock_courses.json", []) != [], "应回落到包内 mock 数据"


def test_mutable_path_seeds_from_package(monkeypatch, tmp_path):
    """首次写入前从包内复制初值 —— 演示数据不能被丢掉。"""
    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    target = chat_llm._mutable_path("mock_wrong_questions.json")
    assert target.parent == tmp_path / "redirected"
    assert target.exists(), "应从包内播种一份"
    assert json.loads(target.read_text(encoding="utf-8")), "播种内容不应为空"


def test_mutable_path_does_not_overwrite_existing(monkeypatch, tmp_path):
    """已有重定向文件时不能被包内内容覆盖（否则运行期新增会丢）。"""
    redirected = tmp_path / "redirected"
    redirected.mkdir(parents=True, exist_ok=True)
    seeded = redirected / "mock_wrong_questions.json"
    seeded.write_text('[{"marker": "runtime-added"}]', encoding="utf-8")

    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(redirected))
    target = chat_llm._mutable_path("mock_wrong_questions.json")
    assert json.loads(target.read_text(encoding="utf-8")) == [{"marker": "runtime-added"}]


def test_wrong_question_write_does_not_touch_packaged_file(monkeypatch, tmp_path):
    """核心回归：错题分析的落盘不能碰包内那份。"""
    before = _fingerprint(_packaged_wrong_questions())

    monkeypatch.setenv("ZHIXUE_CHAT_DIR", str(tmp_path / "redirected"))
    questions = chat_llm._load_json("mock_wrong_questions.json", [])
    assert isinstance(questions, list) and questions, "前置条件：包内有基线数据"
    questions.append({"questionId": "regression-probe", "userId": "u-regression"})
    chat_llm._mutable_path("mock_wrong_questions.json").write_text(
        json.dumps(questions, ensure_ascii=False, indent=2), encoding="utf-8")

    after = _fingerprint(_packaged_wrong_questions())
    assert after == before, (
        "包内 chat/mock_wrong_questions.json 被改动了 —— 重定向失效"
        "（这正是队友那份累积到 26 项的原因）"
    )
    written = json.loads(
        (tmp_path / "redirected" / "mock_wrong_questions.json").read_text(encoding="utf-8"))
    assert written[-1]["questionId"] == "regression-probe"
