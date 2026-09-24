# -*- coding: utf-8 -*-
"""验证契约声明与实际行为一致（针对本次补声明项）。

为什么要单独验：本次给契约补了 14 项声明（405 / 409 / 400 / 查询参数 /
版本头 / 5 个新端点）。补声明本身如果与实现对不上，就是把"声明偏窄"
换成了"声明偏宽"，属于反向偏差。这里逐条实跑核对。
"""
import json
import os
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\C4-liantiao\liantiao5\server\zhixue-agent-server")

tmp = tempfile.mkdtemp(prefix="contractverify-")
os.environ["ZHIXUE_CHAT_DIR"] = tmp
os.environ.pop("ZHIXUE_REPOSITORY", None)

from app import create_app  # noqa: E402

CONTRACT = r"E:\C4-liantiao\liantiao5\contracts\openapi.json"
spec = json.loads(open(CONTRACT, "rb").read().decode("utf-8-sig"))

app = create_app(os.path.join(tmp, "repo.json"))
client = app.test_client()

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print("  [%s] %s%s" % ("PASS" if ok else "FAIL", label,
                           ("  | " + detail) if detail else ""))
    if not ok:
        failures.append(label)


print("=" * 78)
print("1) 新声明的 5 个端点必须真实可达")
print("=" * 78)
for method, path in [("GET", "/"), ("GET", "/health"), ("GET", "/api/agent/health"),
                     ("GET", "/api/agent/history"), ("DELETE", "/api/agent/history"),
                     ("GET", "/api/agent/user-data")]:
    r = client.open(path, method=method)
    check("%-6s %-26s -> %s" % (method, path, r.status_code), r.status_code == 200)

print()
print("=" * 78)
print("2) 声明的 405 必须真的返回（后端统一 JSON 错误体）")
print("=" * 78)
r = client.get("/api/v1/workflows")   # 只声明了 POST
body = r.get_json() or {}
check("GET /api/v1/workflows -> 405", r.status_code == 405, "实际 %s" % r.status_code)
check("405 响应体是 JSON 错误体", isinstance(body, dict) and "errorCode" in body,
      "keys=%s" % sorted(body.keys()) if isinstance(body, dict) else type(body).__name__)

print()
print("=" * 78)
print("3) register 的 409")
print("=" * 78)
client.post("/api/v1/auth/register", json={"nickname": "v1", "phone": "13900007777"})
r = client.post("/api/v1/auth/register", json={"nickname": "v2", "phone": "13900007777"})
check("重复手机号 -> 409 CONFLICT",
      r.status_code == 409 and (r.get_json() or {}).get("errorCode") == "CONFLICT",
      "实际 %s %s" % (r.status_code, (r.get_json() or {}).get("errorCode")))

print()
print("=" * 78)
print("4) exercises 的 400 与 count 参数真实生效")
print("=" * 78)
base = "/api/v1/exercises/set-demo-binary-tree-001"
r = client.get(base + "?count=abc")
check("count=abc -> 400", r.status_code == 400, "实际 %s" % r.status_code)
r = client.get(base + "?count=1")
n = len((r.get_json() or {}).get("exercises") or [])
check("count=1 -> 恰好 1 道题（修复前静默返回 3）", r.status_code == 200 and n == 1,
      "实际 %s 道" % n)
r = client.get(base)
n0 = len((r.get_json() or {}).get("exercises") or [])
check("不带 count 时保持演示基线 3 道题", n0 == 3, "实际 %s 道" % n0)
for qs in ["?knowledgePointId=binary-tree-postorder", "?difficulty=easy",
           "?excludeExerciseId=exercise-preorder-001"]:
    r = client.get(base + qs)
    check("声明的 query %-42s -> 200" % qs, r.status_code == 200)

print()
print("=" * 78)
print("5) knowledge-bases 的 400")
print("=" * 78)
r = client.get("/api/v1/knowledge-bases?userId=" + "x" * 129)
check("超长 userId -> 400", r.status_code == 400, "实际 %s" % r.status_code)

print()
print("=" * 78)
print("6) 版本头闸门（声明的 ContractVersionHeader）")
print("=" * 78)
for hdr, expect in [({}, 200),
                    ({"X-API-Contract-Version": "api-contract-v0.3"}, 200),
                    ({"X-API-Contract-Version": "api-contract-v0.2"}, 409)]:
    r = client.post("/api/v1/workflows", json={"goal": "版本"}, headers=hdr)
    label = hdr.get("X-API-Contract-Version", "(不带头)")
    check("%-22s -> %s" % (label, expect), r.status_code == expect, "实际 %s" % r.status_code)

print()
print("=" * 78)
print("7) 契约结构：LLM_FALLBACK 已移除、documents 已声明")
print("=" * 78)
enum = spec["components"]["schemas"]["ErrorResponse"]["properties"]["errorCode"]["enum"]
check("errorCode 枚举不含 LLM_FALLBACK", "LLM_FALLBACK" not in enum, "共 %d 个" % len(enum))
detail = spec["components"]["schemas"]["KnowledgeBaseDetailResponse"]
has_docs = any("documents" in (p.get("properties") or {}) for p in detail.get("allOf", []))
check("KnowledgeBaseDetailResponse 声明了 documents", has_docs)
check("paths 数量为 33", len(spec["paths"]) == 33, "实际 %d" % len(spec["paths"]))

print()
print("=" * 78)
if failures:
    print("结论：FAIL（%d 项不符）" % len(failures))
    for item in failures:
        print("  - %s" % item)
    raise SystemExit(1)
print("结论：PASS —— 本次补声明的每一项都与实际行为一致")
