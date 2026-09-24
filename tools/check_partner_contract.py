# -*- coding: utf-8 -*-
"""核对 partner-match 响应结构与前端新定义的模型是否逐字段对应。"""
import json
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:5000"

DEMO_USER = {
    "userId": "u001",
    "basicInfo": {"name": "小明", "grade": "大二", "major": "计算机科学与技术"},
    "learningGoal": {"course": "数据结构", "goal": "期末80+"},
    "time": {"freeTime": ["20:00-22:00"]},
    "knowledge": {"weakness": ["二叉树遍历", "递归理解"], "strength": ["图算法"]},
}


def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-API-Contract-Version", "api-contract-v0.3")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


print("=" * 88)
print("POST /api/v1/agent/partner-match   （传当前用户，不传 candidates）")
print("=" * 88)
st, d = post("/api/v1/agent/partner-match", {"userId": "u001", "user": DEMO_USER})
print("  HTTP %s" % st)
print("  顶层键: %s" % sorted(d.keys()))

# 前端 PartnerMatchResponse 期望的字段
EXPECT_TOP = ["userId", "matchedCandidate", "candidates", "generatedAt", "realModeUnavailable"]
print()
print("① 顶层字段 vs 前端 PartnerMatchResponse")
for k in EXPECT_TOP:
    ok = k in d
    print("   %s %-22s %s" % ("OK  " if ok else "!!  ", k, type(d.get(k)).__name__))

# 校验器分支要求的三个字段
print()
print("② 前端校验器要求 userId(str) / candidates(arr) / realModeUnavailable(bool)")
for k, t in (("userId", str), ("candidates", list), ("realModeUnavailable", bool)):
    v = d.get(k)
    ok = isinstance(v, t) and not (t is bool and isinstance(v, int) and not isinstance(v, bool))
    print("   %s %-22s %s" % ("OK  " if ok else "!!  ", k, repr(v)[:40]))

best = d.get("matchedCandidate")
print()
print("③ matchedCandidate（前端 PartnerRankedCandidate）")
if best is None:
    print("   !! 为 null")
else:
    print("   candidate.userId   = %s" % best["candidate"]["userId"])
    print("   score              = %s" % best["score"])
    print("   factors 的字段      = %s" % sorted(best["factors"].keys()))

EXPECT_FACTORS = ["goal", "timeOverlap", "knowledgeComplement", "basicMatch",
                  "stability", "overlapMinutes"]
print()
print("④ factors vs 前端 PartnerMatchFactors")
for k in EXPECT_FACTORS:
    ok = k in (best["factors"] if best else {})
    print("   %s %-22s %s" % ("OK  " if ok else "!!  ", k,
                              (best["factors"].get(k) if best else None)))

print()
print("⑤ 候选人资料字段 vs 前端 PartnerCandidateProfile")
cand = best["candidate"] if best else {}
for section, fields in (("basicInfo", ["name", "grade", "major"]),
                        ("learningGoal", ["course", "goal"]),
                        ("time", ["freeTime"]),
                        ("knowledge", ["weakness", "strength"])):
    got = cand.get(section)
    ok = isinstance(got, dict) and all(f in got for f in fields)
    print("   %s %-14s %s" % ("OK  " if ok else "!!  ", section, got))

print()
print("=" * 88)
print("全部候选人排名与分数（文档与 PPT 要引用这些数字）")
print("=" * 88)
for rank, item in enumerate(d.get("candidates") or [], 1):
    f = item["factors"]
    name = item["candidate"].get("basicInfo", {}).get("name")
    print("  %d. %-6s 总分 %3d  =  目标 %d + 时间 %d(重叠 %d 分钟) + 互补 %d + 基础 %d + 稳定 %d"
          % (rank, name, item["score"], f["goal"], f["timeOverlap"],
             f["overlapMinutes"], f["knowledgeComplement"], f["basicMatch"], f["stability"]))
