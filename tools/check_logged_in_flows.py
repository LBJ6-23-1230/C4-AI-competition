# -*- coding: utf-8 -*-
"""用**真实账号身份**逐条实测登录后才走的接口。

## 为什么单做这一个

前端同学报「游客能进知识库，登录自己账号就报数据结构不一致」。
根因是 URL 带 `?userId=` 让校验器走错分支 —— 已在 2026-09-23 修复。

但那只验证了"校验器能命中"。真正要回答的是：
**拿着真实账号的 token 走一遍所有登录后接口，返回是否都正常？**

本脚本模拟 App 的确切请求形态：
  · 带 `Authorization: Bearer <真 token>`
  · 带 `X-API-Contract-Version`
  · **知识库列表按 App 的写法带 `?userId=`**（这正是当初出问题的形态）
并逐条检查响应的必需字段是否齐全。
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_ap = argparse.ArgumentParser()
_ap.add_argument("--port", type=int, default=5000)
_ap.add_argument("--base", default="")
_a = _ap.parse_args()
BASE = _a.base or ("http://127.0.0.1:%d" % _a.port)


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    req.add_header("X-API-Contract-Version", "api-contract-v0.3")
    if data:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw or "{}")
        except Exception:
            return e.code, {"_raw": raw[:160]}
    except Exception as e:
        return None, {"_err": str(e)}


def has(obj, key, typ):
    if not isinstance(obj, dict) or key not in obj:
        return False
    v = obj[key]
    return {"str": isinstance(v, str),
            "num": isinstance(v, (int, float)) and not isinstance(v, bool),
            "arr": isinstance(v, list),
            "bool": isinstance(v, bool),
            "obj": isinstance(v, dict)}.get(typ, True)


results: list[tuple[str, bool, str]] = []


def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print("  %s %-52s %s" % ("PASS" if ok else "FAIL", label, detail))


print("=" * 100)
print("准备：注册一个真实账号并登录（模拟 App 的注册流程）")
print("=" * 100)
phone = "139" + "".join(random.choice("0123456789") for _ in range(8))
nick = "复查" + "".join(random.choice("0123456789") for _ in range(4))
st, r = call("POST", "/api/v1/auth/register",
             {"nickname": nick, "phone": phone, "grade": "大二"})
token = r.get("token")
user = r.get("user") or {}
uid = user.get("userId")
check("注册成功", st == 201, "HTTP %s" % st)
check("拿到 token 与 userId", bool(token) and bool(uid), "userId=%s" % uid)

print()
print("=" * 100)
print("一、账户自身（登录后才走）")
print("=" * 100)
st, r = call("GET", "/api/v1/auth/me", token=token)
check("GET /auth/me", st == 200 and has(r, "user", "obj"),
      "HTTP %s" % st)

print()
print("=" * 100)
print("二、知识库（当初出问题的功能）—— 按 App 的写法带 ?userId=")
print("=" * 100)
# App 的实际写法：/api/v1/knowledge-bases?userId=<uid>
st, r = call("GET", "/api/v1/knowledge-bases?userId=%s" % uid, token=token)
check("GET 知识库列表（带 ?userId=）", st == 200 and has(r, "knowledgeBases", "arr")
      and has(r, "total", "num"), "HTTP %s keys=%s" % (st, sorted(r.keys())[:5]))

st, r = call("POST", "/api/v1/knowledge-bases",
             {"courseName": "数据结构", "name": "复查库" + nick[-4:]}, token=token)
kb = r.get("kbId")
check("POST 新建知识库", st == 201 and has(r, "kbId", "str") and has(r, "name", "str"),
      "HTTP %s kbId=%s" % (st, kb))

if kb:
    st, r = call("GET", "/api/v1/knowledge-bases/%s" % kb, token=token)
    check("GET 知识库详情", st == 200 and has(r, "kbId", "str")
          and has(r, "courseName", "str"), "HTTP %s" % st)

    st, r = call("GET", "/api/v1/knowledge-bases/%s/documents" % kb, token=token)
    check("GET 文档列表", st == 200 and has(r, "kbId", "str")
          and has(r, "documents", "arr"), "HTTP %s" % st)

    st, r = call("POST", "/api/v1/knowledge-bases/%s/search" % kb,
                 {"query": "二叉树"}, token=token)
    ok = (st == 200 and has(r, "kbId", "str") and has(r, "query", "str")
          and has(r, "hits", "arr") and has(r, "totalScanned", "num")
          and has(r, "retrievalMode", "str") and has(r, "semanticAvailable", "bool")
          and has(r, "semanticWeight", "num"))
    check("POST 检索（7 个必需字段）", ok, "HTTP %s" % st)

    # ⚠️ 字段名是 contentBase64（不是 content）—— 后端要求 base64 编码的正文。
    # 早先探针传 content 得到 400「contentBase64 不能为空」，
    # 一度以为是后端缺陷，实为探针字段名写错。
    import base64
    doc_text = "二叉树遍历：前序 根-左-右；中序 左-根-右；后序 左-右-根。"
    st, r = call("POST", "/api/v1/knowledge-bases/%s/documents" % kb,
                 {"fileName": "讲义.txt",
                  "contentBase64": base64.b64encode(doc_text.encode("utf-8")).decode("ascii"),
                  "mimeType": "text/plain",
                  "sizeBytes": len(doc_text.encode("utf-8"))}, token=token)
    check("POST 上传文档（contentBase64）",
          st in (200, 201) and has(r, "documentId", "str")
          and has(r, "status", "str") and has(r, "fileName", "str"),
          "HTTP %s %s" % (st, r.get("message") or ""))

print()
print("=" * 100)
print("三、学习主链（登录后带 token 走）")
print("=" * 100)
st, r = call("GET", "/api/v1/profile/%s" % uid, token=token)
# ⚠️ userId 在**嵌套的 profile 对象**里（profile.userId），不在顶层。
# 前端 ProfileViewModel.ets:56 正是读 `response.profile?.userId`。
# 早先探针查的是顶层 userId，误报失败；后端其实是好的。
check("GET 学习画像（含 profile.userId）",
      st == 200 and has(r, "profile", "obj")
      and has(r.get("profile") or {}, "userId", "str")
      and has(r, "profileVersion", "num")
      and has(r, "mastery", "arr"),
      "HTTP %s profile.userId=%s" % (st, (r.get("profile") or {}).get("userId")))

st, r = call("GET", "/api/v1/plans/current", token=token)
check("GET 当前计划", st == 200, "HTTP %s" % st)

st, r = call("GET", "/api/v1/exercises/set-demo-binary-tree-001", token=token)
check("GET 题集（登录后）", st == 200 and has(r, "exercises", "arr"),
      "HTTP %s" % st)

st, r = call("POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
             {"idempotencyKey": "relogin-%s" % uid,
              "answers": [{"exerciseId": "exercise-preorder-001", "answer": "A"},
                          {"exerciseId": "exercise-inorder-001", "answer": "B"},
                          {"exerciseId": "exercise-postorder-001", "answer": "A"}]},
             token=token)
check("POST 提交练习（登录后）", st == 200 and has(r, "assessment", "obj"),
      "HTTP %s" % st)

st, r = call("POST", "/api/v1/agent/partner-match", {"userId": uid}, token=token)
check("POST 搭子匹配（登录后）", st == 200 and has(r, "candidates", "arr"),
      "HTTP %s" % st)

print()
print("=" * 100)
print("四、越权检查：这个账号不该看到别人的数据")
print("=" * 100)
st, r = call("GET", "/api/v1/knowledge-bases?userId=demo-user", token=token)
mine = [k.get("name") for k in (r.get("knowledgeBases") or [])]
leaked = [n for n in mine if n and "复查库" not in n]
check("用自己 token 带别人的 userId 查不到别人数据", not leaked,
      "看到: %s" % mine)

st, r = call("GET", "/api/v1/auth/me")
check("无 token 访问 /auth/me 被拒", st == 401, "HTTP %s" % st)

print()
print("=" * 100)
fail = [x for x in results if not x[1]]
print("总计 %d 项，通过 %d，失败 %d" % (len(results), len(results) - len(fail), len(fail)))
for label, _, detail in fail:
    print("  FAIL %s  %s" % (label, detail))
print("=" * 100)
if not fail:
    print("结论：PASS —— 登录后功能全部可用")
raise SystemExit(1 if fail else 0)
