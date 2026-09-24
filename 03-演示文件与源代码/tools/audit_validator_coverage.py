# -*- coding: utf-8 -*-
"""审计：前端调用的每个接口，校验器是否都有对应分支。

## 为什么做这个

前端同学报「游客能进知识库，登录自己账号就报『数据结构与 api-contract-v0.3
不一致』」。根因是校验器对路径做精确比较、`?userId=` 让分支失配。

那只是**一处**表现。真正要防的是这一类：**前端调了接口，但校验器没有对应分支**
—— 那样每个响应都会被判为"不一致"，表现为"这个功能用不了"。

本脚本枚举前端所有请求路径，逐条判断校验器能否命中，
并标出哪些是**登录后才走**的（那些最容易漏测，因为游客路径不经过）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(r"E:\C4-liantiao\liantiao5")
ETS = ROOT / "app" / "entry" / "src" / "main" / "ets"
CLIENT = ETS / "api" / "AgentApiClient.ets"
VALIDATOR = ETS / "api" / "ApiResponseValidator.ets"

client_src = CLIENT.read_text(encoding="utf-8")
validator_src = VALIDATOR.read_text(encoding="utf-8")

# ---- 1. 枚举前端调用：方法 + 路径模板 ----
calls: list[tuple[str, str, str]] = []          # (函数名, HTTP 方法, 路径)
FUNC = re.compile(r"static async (\w+)\(", re.M)
starts = list(FUNC.finditer(client_src))
for idx, m in enumerate(starts):
    end = starts[idx + 1].start() if idx + 1 < len(starts) else len(client_src)
    name, block = m.group(1), client_src[m.start():end]
    for cm in re.finditer(r"http\.RequestMethod\.(\w+),\s*[`']([^`']+)[`']", block):
        calls.append((name, cm.group(1), cm.group(2)))

# ---- 2. 解析校验器里的路由条件 ----
# 形如 method === 'GET' && route === '/api/v1/x'
#       method === 'GET' && route.indexOf('/api/v1/x/') === 0
#       route.indexOf('/api/v1/x') === 0 && route.endsWith('/y')
exact: set[tuple[str, str]] = set()
prefix: set[tuple[str, str]] = set()
endswith: set[str] = set()

for m in re.finditer(
        r"method === '(\w+)' && route === '([^']+)'", validator_src):
    exact.add((m.group(1), m.group(2)))
for m in re.finditer(
        r"method === '(\w+)' && route\.indexOf\('([^']+)'\) === 0", validator_src):
    prefix.add((m.group(1), m.group(2)))
for m in re.finditer(r"route\.indexOf\('([^']+)'\) === 0", validator_src):
    prefix.add(("*", m.group(1)))
for m in re.finditer(r"route\.endsWith\('([^']+)'\)", validator_src):
    endswith.add(m.group(1))
# 无 method 限定的精确比较（例如知识库详情分支里）
for m in re.finditer(r"if \(route === '([^']+)'\)", validator_src):
    exact.add(("*", m.group(1)))

print("=" * 96)
print("校验器已声明的路由条件")
print("=" * 96)
print("  精确: %s" % sorted("%s %s" % (m, p) for m, p in exact))
print("  前缀: %s" % sorted("%s %s" % (m, p) for m, p in prefix))
print("  后缀: %s" % sorted(endswith))
print()


def covered(method: str, path: str) -> bool:
    """校验器能否命中这个请求。"""
    if (method, path) in exact or ("*", path) in exact:
        return True
    for m, pre in prefix:
        if m not in ("*", method):
            continue
        if path == pre:
            return True
        if not pre.endswith("/"):
            if path.startswith(pre + "/"):
                return True
        elif path.startswith(pre):
            return True
    # 详情类：前缀命中且后缀匹配
    for m, pre in prefix:
        if m not in ("*", method) or not path.startswith(pre):
            continue
        if any(path.endswith(s) for s in endswith) or not endswith:
            return True
    return False


# ---- 3. 逐条判断 ----
# 登录后才走的接口（游客路径不经过，最易漏测）
AUTH_ONLY = {"/api/v1/auth/me", "/api/v1/auth/logout", "/api/v1/auth/account",
             "/api/v1/auth/verify-code", "/api/v1/auth/login-with-huawei",
             "/api/v1/knowledge-bases"}

def normalize(raw: str) -> str:
    """把调用的路径模板规范化成「实际请求路径」。

    规则：
      · `${encodeURIComponent(x)}` → `x`（路径参数）
      · `${suffix}` 等**运行时字符串变量** → 直接去掉（它们装的是查询串，不是路径段）
      · 去掉查询串
    """
    s = re.sub(r"\$\{encodeURIComponent\([^)]*\)\}", "x", raw)
    s = re.sub(r"\$\{(suffix|query|params|qs)\}", "", s)
    s = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_.]*\}", "x", s)
    return s.split("?")[0]


print("=" * 96)
print("前端调用 vs 校验器覆盖")
print("=" * 96)
missing: list[tuple[str, str, str]] = []
for name, method, raw in calls:
    probe = normalize(raw)
    ok = covered(method, probe)
    tag = "登录后" if any(probe.startswith(a) for a in AUTH_ONLY) else ""
    print("  %s %-6s %-30s %-34s %s"
          % ("OK  " if ok else "!!  ", method, name, probe, tag))
    if not ok:
        # 报错时把原始模板也打出来，便于定位是"真缺分支"还是"脚本误判"
        print("       原始模板: %s" % raw)
        missing.append((name, method, probe))

print()
print("=" * 96)
if missing:
    print("结论：FAIL —— %d 个接口没有校验器分支（这些接口在 App 里会全部报"
          "「数据结构不一致」）" % len(missing))
    for name, method, probe in missing:
        print("  · %s()  %s %s" % (name, method, probe))
    raise SystemExit(1)
print("结论：PASS —— 前端调用的每个接口都有对应校验器分支")
