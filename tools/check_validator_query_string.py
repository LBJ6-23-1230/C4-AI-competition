# -*- coding: utf-8 -*-
"""闸门：校验器不得因 URL 带查询串而走错分支。

## 为什么需要

2026-09-23 发现一个真实缺陷（前端同学报「知识库页报『服务返回的数据结构与
api-contract-v0.3 不一致』，进不去」）：

* `AgentApiClient.listKnowledgeBases(userId)` 会拼出
  `/api/v1/knowledge-bases?userId=xxx`
* 而 `ApiResponseValidator` 对路径用**精确比较**
  `path === '/api/v1/knowledge-bases'`
* 带查询串时该比较不成立 → 掉进下面的「详情」分支去要 `kbId`/`name`
  → 列表响应没有这两个字段 → 校验失败 → 页面报契约不一致

**只有登录真实账号才复现**（游客不传 userId），所以很容易漏测。

## 这个闸门检查什么

1. `ApiResponseValidator.isValid` 内部**不得**直接对入参 `path` 做
   `===` / `indexOf` / `endsWith` / `startsWith` 匹配 ——
   必须先用去掉查询串的 `route`。
2. `AgentApiClient` 里凡是**会拼查询串**的方法，其路径都必须能被
   `route`（去查询串后）正确匹配。

用法：

    python tools/check_validator_query_string.py [工程根]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
ETS = ROOT / "app" / "entry" / "src" / "main" / "ets"
VALIDATOR = ETS / "api" / "ApiResponseValidator.ets"
CLIENT = ETS / "api" / "AgentApiClient.ets"

print("=" * 84)
print("闸门：校验器与带查询串的 URL")
print("=" * 84)
print("  工程根: %s" % ROOT)
print()

if not VALIDATOR.exists():
    print("  !! 找不到 %s" % VALIDATOR)
    raise SystemExit(2)

src = VALIDATOR.read_text(encoding="utf-8")

# ---- ① 校验器内部是否只用在 route 上做匹配 ----
print("① 校验器内部：路径匹配是否统一走 route（已剥离查询串）")
body = src
head, sep, tail = body.partition("static isValid(")
if not sep:
    print("  !! 找不到 isValid 方法")
    raise SystemExit(2)

# 在 isValid 之后，不应再出现对裸 path 的直接匹配
bad_patterns = [
    (r"\bpath\s*===", "path ===（精确比较）"),
    (r"\bpath\.indexOf", "path.indexOf"),
    (r"\bpath\.endsWith", "path.endsWith"),
    (r"\bpath\.startsWith", "path.startsWith"),
]
problems = []
for pat, label in bad_patterns:
    for m in re.finditer(pat, tail):
        line_no = tail[: m.start()].count("\n") + 1
        problems.append("%s（isValid 内第 %d 行）" % (label, line_no))

if problems:
    print("  ❌ 仍有对裸 path 的匹配：")
    for p in problems:
        print("       %s" % p)
else:
    print("  OK   未发现对裸 path 的匹配，全部走 route")

# 确认 route 确实由 basePath 产出
has_base = "basePath(path)" in src
has_route = "const route" in src
print("  %s route 由 basePath(path) 派生"
      % ("OK  " if (has_base and has_route) else "!!  "))
if not (has_base and has_route):
    problems.append("route 未由 basePath(path) 派生")

# ---- ② 客户端里带查询串的调用，路径能否被 route 匹配 ----
print()
print("② 客户端：**真正拼了查询串**的调用是否都能被 route 命中")
if not CLIENT.exists():
    print("  !! 找不到 %s" % CLIENT)
    raise SystemExit(2)

client = CLIENT.read_text(encoding="utf-8")

# ⚠️ 必须逐「函数」判断，不能对全文做简单正则 ——
#    `${encodeURIComponent(id)}` 这种是**路径参数**，不是查询串。
#    早先版本只匹配 `${`，把 getProfile / getPlanDiff / getTrace 全误报成
#    "带查询串"，而它们其实只是路径参数（实测核对过）。
#    这里按函数切块，块内出现「查询串拼装」才算：
#      · parameters.push(...) 参数数组
#      · 形如 `?KEY=` 或 `?${` 的查询串拼接
FUNC_RE = re.compile(r"static async (\w+)\(", re.M)
chunks: list[tuple[str, str]] = []
matches = list(FUNC_RE.finditer(client))
for idx, m in enumerate(matches):
    end = matches[idx + 1].start() if idx + 1 < len(matches) else len(client)
    chunks.append((m.group(1), client[m.start():end]))

QUERY_SIGNS = ("parameters.push(", "?userId=", "?${", "?count=", "?knowledgePointId=")

checked = 0
for fn_name, block in chunks:
    if not any(sign in block for sign in QUERY_SIGNS):
        continue                      # 该函数不拼查询串，跳过
    checked += 1
    # 取该函数里出现的路由前缀（去掉路径参数与查询串）
    routes = set()
    for m in re.finditer(r"`(/api/v1/[a-z-]+)", block):
        routes.add(m.group(1))
    for r in sorted(routes):
        # 按「前缀语义」判断校验器能否命中：
        #   校验器里可能写 `route.indexOf('/api/v1/exercises/')`（带尾斜杠）
        #   也可能写 `route === '/api/v1/knowledge-bases'`（精确）
        # 实际的 route 是 `/api/v1/exercises/<id>` 或 `/api/v1/knowledge-bases`，
        # 所以两种写法都要能命中才算通。
        # ⚠️ 早先版本只查不带尾斜杠的字面量，把 getExerciseSet 误报成失败。
        candidates = (r, r + "/")
        hit = any(
            ("route === '%s'" % c) in src or ("route.indexOf('%s')" % c) in src
            for c in candidates
        )
        print("  %s %-22s %-28s %s"
              % ("OK  " if hit else "!!  ", fn_name, r,
                 "route 可匹配" if hit else "route 无法匹配 —— 会走错分支"))
        if not hit:
            problems.append("%s() 带查询串，但 %s 无法被 route 匹配"
                            % (fn_name, r))

if checked == 0:
    print("  （未发现真正拼查询串的调用）")
else:
    print("  共检查 %d 个拼查询串的函数" % checked)

# ---- 结论 ----
print()
print("=" * 84)
if problems:
    print("结论：FAIL（%d 项）" % len(problems))
    for p in problems:
        print("  · %s" % p)
    raise SystemExit(1)
print("结论：PASS（校验器不会因查询串走错分支）")
