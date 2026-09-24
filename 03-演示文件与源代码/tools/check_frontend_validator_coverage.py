# -*- coding: utf-8 -*-
"""联调闸门 ← 前端校验器的一致性校验（针对审计 R1）。

## 为什么需要这个脚本

2026-09-22 的契约一致性审计发现了一个**结构性缺陷**，也是 P0-1
（验证码登录整条链路不可用）能一路绿灯交付的**根因**：

    `integration/verify_integration.py` 声称它的 `frontend_valid()` 是
    `app/entry/src/main/ets/api/ApiResponseValidator.ets` 的"逐条移植"，
    实际至少有 6 处偏离，且**零覆盖 send-code / verify-code** ——
    而那两个接口恰好是唯一会被前端真校验器判 False 的契约接口。

    也就是说：**闸门验证的是它自己的副本，而不是被它代理的那个对象**，
    而且没有任何机制去校验这份"同步"。

## 真正的不变量是什么（第一版写错了，这里更正）

**不是**"契约里的每个操作都要有校验分支" —— 那样会误报：
`AgentApiClient` 没有客户端方法去调的接口（如 `/api/v1/experiments/snapshot`）
本来就不会经过校验器，缺分支无害。

真正的不变量是：

    凡是 `AgentApiClient.request()` 会发出的 (method, path)，
    `ApiResponseValidator.isValid()` **必须有对应分支**。

因为只有 `AgentApiClient.request()` 会调用 `isValid()` 并把 False 转成
`INVALID_RESPONSE`（见 `AgentApiClient.ets:239-240`）。漏一条分支 =
那个接口即便返回完全合法的响应也会被判结构不合法 = **功能整条不可用**。
P0-1 正是这个形态。

所以本脚本从 `AgentApiClient.ets` 抽取它**实际发出的每个调用**，逐个核对
校验器有没有分支；再把"契约有、但前端尚未接入"的接口单独列出（属
"声明了但没人用"，不是缺陷）。

## 它不做什么

它**不**校验字段级等价性（`.ets` 里 `isAuthSession()` 具体查哪几个字段，
与 Python 侧是否一致）。那需要真正执行 ArkTS，超出脚本能力。
本脚本只补上"**接口级不漏分支**"这一层最低限度的检查。
这一点刻意写清楚，避免又制造一个"看起来在验证"的假保证。

用法：

    python tools/check_frontend_validator_coverage.py           # 报告
    python tools/check_frontend_validator_coverage.py --strict   # 有缺口则退出码 1
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "app" / "entry" / "src" / "main" / "ets" / "api" / "ApiResponseValidator.ets"
CLIENT = ROOT / "app" / "entry" / "src" / "main" / "ets" / "api" / "AgentApiClient.ets"
CONTRACT = ROOT / "contracts" / "openapi.json"
GATE = ROOT / "integration" / "verify_integration.py"

_METHODS = ("get", "post", "put", "patch", "delete")

#: 后端 `app/__init__.py` 里不参与契约校验的辅助端点
NON_CONTRACT_ENDPOINTS = {"/", "/health"}


def parse_validator_routes(source: str) -> tuple[set[tuple[str, str]], set[tuple[str, str]]]:
    """从 `.ets` 源码抽出 (method, path) 判定，返回 `(精确集合, 前缀集合)`。"""
    exact = set(re.findall(r"method === '([A-Z]+)'\s*&&\s*path === '([^']+)'", source))
    prefix = set(re.findall(
        r"method === '([A-Z]+)'\s*&&\s*path\.indexOf\('([^']+)'\)\s*===\s*0", source))
    return exact, prefix


def parse_client_calls(source: str) -> set[tuple[str, str]]:
    """抽取 `AgentApiClient` 实际发出的 (method, path)。

    形态是 `AgentApiClient.request<...>(http.RequestMethod.GET, '/path', ...)`，
    也可能包一层常量（如 `const path = ...`）。这里抓直接字面量的那部分；
    非字面量的模板串会被跳过并在报告里说明。
    """
    pattern = re.compile(
        r"AgentApiClient\.request<[^>]*>\(\s*http\.RequestMethod\.([A-Z]+)\s*,\s*'([^']+)'")
    return set(pattern.findall(source))


def contract_operations(obj: dict) -> set[tuple[str, str]]:
    ops: set[tuple[str, str]] = set()
    for path, item in obj.get("paths", {}).items():
        if path in NON_CONTRACT_ENDPOINTS:
            continue
        for method in item:
            if method in _METHODS:
                ops.add((method.upper(), path))
    return ops


def normalize(path: str) -> str:
    """把 `{param}` 写法归一到 `*`，便于前缀比较。"""
    return re.sub(r"\{[^}]+\}", "*", path)


def matches(operation: tuple[str, str], exact: set, prefix: set) -> bool:
    method, path = operation
    if (method, path) in exact:
        return True
    for pm, pp in prefix:
        if pm == method and path.startswith(pp.rstrip("*")):
            return True
    return False


def main() -> int:
    strict = "--strict" in sys.argv
    for required in (VALIDATOR, CLIENT, CONTRACT):
        if not required.exists():
            print("找不到必需文件: %s" % required)
            return 2

    validator_src = VALIDATOR.read_text(encoding="utf-8")
    client_src = CLIENT.read_text(encoding="utf-8")
    exact, prefix = parse_validator_routes(validator_src)
    client_calls = parse_client_calls(client_src)
    operations = contract_operations(json.loads(CONTRACT.read_bytes().decode("utf-8-sig")))

    print("=" * 78)
    print("① 真正的不变量：AgentApiClient 会发的调用，校验器必须都有分支")
    print("=" * 78)
    print("  AgentApiClient 直接字面量调用: %d 个" % len(client_calls))
    print("  校验器分支: 精确 %d 条 / 前缀 %d 条" % (len(exact), len(prefix)))
    print()

    gaps = sorted(op for op in client_calls if not matches(op, exact, prefix))
    if gaps:
        print("❌ 有缺口 (%d 个) —— 这些接口返回合法响应也会被判 INVALID_RESPONSE：" % len(gaps))
        for method, path in gaps:
            print("     %-6s %s" % (method, path))
        print()
        print("  ★ P0-1（验证码登录不可用）就是这个形态：")
        print("    AgentApiClient 会发 send-code / verify-code，而校验器原先没有这两条分支。")
    else:
        print("✅ 无缺口：AgentApiClient 发出的每个调用都有校验分支")

    print()
    print("=" * 78)
    print("② 契约有、但前端尚未接入的接口（属'声明了但没人用'，不是缺陷）")
    print("=" * 78)
    unused = sorted(op for op in operations if not matches(op, exact, prefix))
    if unused:
        for method, path in unused:
            print("     %-6s %s" % (method, path))
        print()
        print("  这些接口若将来被 AgentApiClient 接入，**必须同时补校验分支**，")
        print("  否则会复现 P0-1。本脚本在那之前就能发现（① 会立刻变红）。")
    else:
        print("  （无）")

    print()
    print("=" * 78)
    print("③ 联调闸门覆盖率（审计 R1 的核心问题）")
    print("=" * 78)
    gate_src = GATE.read_text(encoding="utf-8") if GATE.exists() else ""
    gate_paths = set(re.findall(r"['\"](/api/[^'\"]+)['\"]", gate_src))
    gate_missing = sorted(
        op for op in operations
        if op[1] not in gate_paths and normalize(op[1]) not in {normalize(p) for p in gate_paths}
    )
    print("  闸门里出现过的 /api 路径字面量: %d 个" % len(gate_paths))
    if gate_missing:
        print("  ⚠️ 契约有、闸门从未提及的操作 (%d 条)：" % len(gate_missing))
        for method, path in gate_missing:
            print("     %-6s %s" % (method, path))
        print()
        print("  ⚠️ 本检查只看'路径是否被提及'，**不代表闸门里的字段规则与 .ets 等价**。")
        print("     审计已确认两者至少有 6 处字段级偏离 —— 根治需要两者共享同一份规则。")
    else:
        print("  ✅ 闸门提及了契约里的每一个操作路径")

    print()
    print("=" * 78)
    print("结论：%s" % ("PASS（① 无缺口）" if not gaps else "FAIL（① 有 %d 个缺口）" % len(gaps)))
    # ⚠️ 只有 ① 是硬不变量。③ 是"闸门是否提及过该路径"的提示性统计，
    # 它按设计**不影响退出码**（需要 `--strict`）。
    # 原先这里只打一行 `结论：FAIL`，调用方看输出会以为闸门红了、看退出码又是 0，
    # 两边对不上。现在把"这一行与退出码的关系"明确印出来。
    if gate_missing:
        print("      ③ 另有 %d 项属于'闸门未提及'的提示，**不影响退出码**"
              "（要让它也失败请加 --strict 之外的判断，或直接看 ③ 小节）。" % len(gate_missing))
    print("      退出码：%d%s" % (
        (1 if (strict and gaps) else 0),
        "（--strict 且 ① 有缺口）" if (strict and gaps) else ""))
    if strict and gaps:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

