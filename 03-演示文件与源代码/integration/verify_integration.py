# -*- coding: utf-8 -*-
"""liantiao2 前后端联调实跑验证（HTTP 真实调用，非代码推断）。

设计要点
--------
1. **真实 HTTP**：全部通过 `urllib.request` 打真实运行中的后端进程，不使用 Flask test_client。
2. **复用前端契约判定**：`FRONTEND_VALIDATORS` 是 `entry/src/main/ets/api/ApiResponseValidator.ets`
   的逐条移植。前端在 `AgentApiClient.request()` 里对每个响应调用 `ApiResponseValidator.isValid()`，
   返回 false 就报 `INVALID_RESPONSE`。所以**只有走这套规则通过的响应，才证明前端能真正消费**。
3. **锁定演示基线**：66.67 / 42→58 / Plan V1→V2 / [45,15]。

用法::

    python verify_integration.py --base http://127.0.0.1:5057 --out result.json
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# 工程根目录（integration/ 的上一级）——用于直接读契约文件做字段覆盖检查
ROOT = Path(__file__).resolve().parents[1]

CONTRACT = "api-contract-v0.3"

#: 普通接口的超时（秒）。这些接口都是纯确定性计算，毫秒级返回。
HTTP_TIMEOUT = 15

#: **走真实大模型**的接口超时（秒）。
#:
#: 实测 live 模式下 `/api/agent/chat` 单次响应需 **25–30 秒**（qwen-vl-max
#: 生成几百字中文回复 + 意图识别两次调用）。原先所有请求共用 15 秒，
#: 于是联调跑到聊天一节就 `TimeoutError` 崩栈退出 —— 看起来像产品接口挂了，
#: 实际是脚本超时太紧。凡打 LLM 的调用都要传这个值。
LLM_TIMEOUT = 120

_LIVE_IMAGE_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGO4"
    "o6FBEmIY1TCqYfhqAAAyBCwQhvh37QAAAABJRU5ErkJggg==")

RESULTS = []


def record(name, ok, detail="", expected=None, actual=None):
    RESULTS.append({
        "check": name,
        "ok": bool(ok),
        "detail": detail,
        "expected": expected,
        "actual": actual,
    })
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name}" + (f"  | {detail}" if detail else ""))
    return ok


def http(method, url, body=None, contract=CONTRACT, raw_text=None, content_type=None,
         timeout=None):
    """发一个真实 HTTP 请求，返回 `(status, parsed_body, headers)`。

    `raw_text` / `content_type` 用于构造**非 JSON** 请求体（例如验证
    "非 JSON 请求体应返回 JSON 400 而不是 HTML"）。两者互斥于 `body`。

    ## 超时（`timeout`）

    默认 `HTTP_TIMEOUT`（15s）。**走真实大模型的接口必须显式放宽** ——
    实测 `/api/agent/chat` 在 live 模式下单次响应需 **25–30 秒**
    （qwen-vl-max 要生成几百字中文回复），15 秒必然 `TimeoutError`。

    这个缺陷会造成很坏的误导：整个联调在"鉴权/聊天"一节直接崩栈退出，
    看起来像产品接口挂了，实际是**测试脚本自己的超时太紧**。
    因此凡是打 LLM 的调用都传 `timeout=LLM_TIMEOUT`。
    """
    if raw_text is not None:
        data = raw_text.encode("utf-8")
    else:
        data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    if contract:
        request.add_header("X-API-Contract-Version", contract)
    if data is not None:
        request.add_header("Content-Type", content_type or "application/json")
    try:
        with urllib.request.urlopen(
                request, timeout=(timeout if timeout is not None else HTTP_TIMEOUT)) as response:
            raw = response.read().decode("utf-8")
            return response.status, (json.loads(raw) if raw.strip() else None), dict(response.headers)
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            parsed = json.loads(raw) if raw.strip() else None
        except json.JSONDecodeError:
            parsed = raw
        return error.code, parsed, dict(error.headers)


# --------------------------------------------------------------------------
# 前端 ApiResponseValidator.ets 的 Python 移植
# --------------------------------------------------------------------------
def _is_record(value):
    return isinstance(value, dict)


def _has_string(data, key):
    value = data.get(key)
    return isinstance(value, str) and value.strip() != ""


def _is_string(data, key):
    return isinstance(data.get(key), str)


def _has_number(data, key):
    # ArkTS 的 typeof === 'number'：bool 不是 number
    return isinstance(data.get(key), (int, float)) and not isinstance(data.get(key), bool)


def _has_boolean(data, key):
    return isinstance(data.get(key), bool)


def _has_array(data, key):
    return isinstance(data.get(key), list)


def _is_record_field(data, key):
    return key in data and _is_record(data.get(key))


def _is_nullable_record(data, key):
    value = data.get(key)
    return value is None or _is_record(value)


def _is_nullable_string(data, key):
    value = data.get(key)
    return value is None or isinstance(value, str)


def _is_plan(data):
    return (_is_nullable_string(data, "planId") and _has_number(data, "version")
            and _has_number(data, "generatedFromProfileVersion") and _has_array(data, "tasks"))


def _is_auth_user_field(data, key):
    if not _is_record_field(data, key):
        return False
    user = data[key]
    return _has_string(user, "userId") and _has_string(user, "nickname")


def frontend_valid(method, path, payload):
    """忠实移植 ApiResponseValidator.isValid()。"""
    if not _is_record(payload):
        return False
    data = payload
    if method == "POST" and path == "/api/v1/workflows":
        return all(_has_string(data, k) for k in ("sessionId", "traceId", "status", "currentStep", "nextAction"))
    if method == "GET" and path.startswith("/api/v1/workflows/"):
        return (_has_string(data, "status") and _has_number(data, "stateVersion")
                and _is_nullable_string(data, "currentAgent") and _is_nullable_string(data, "finalAction"))
    if method == "POST" and path.startswith("/api/v1/workflows/") and path.endswith("/run"):
        return (_has_string(data, "sessionId") and _has_string(data, "traceId") and _has_string(data, "status")
                and _has_string(data, "currentStep") and _has_string(data, "currentAgent")
                and _has_number(data, "stateVersion") and _is_nullable_string(data, "finalAction"))
    if method == "GET" and path.startswith("/api/v1/profile/"):
        return (_has_number(data, "profileVersion") and _has_array(data, "mastery")
                and _has_array(data, "history") and _has_array(data, "evidence"))
    if method == "GET" and path == "/api/v1/plans/current":
        return _is_plan(data)
    if method == "GET" and path.startswith("/api/v1/exercises/") and not path.endswith("/submit"):
        return _has_string(data, "setId") and _has_array(data, "exercises")
    if method == "POST" and path.startswith("/api/v1/exercises/") and path.endswith("/submit"):
        return (_is_record_field(data, "assessment") and _has_boolean(data, "needReplan")
                and _is_nullable_record(data, "masteryUpdate"))
    if method == "GET" and path.startswith("/api/v1/plans/") and path.endswith("/diff"):
        return (_has_number(data, "oldVersion") and _has_number(data, "newVersion")
                and _has_array(data, "changedTasks") and _has_string(data, "adjustmentReason")
                and _has_array(data, "triggerEvidence"))
    if method == "GET" and path.startswith("/api/v1/traces/"):
        return _has_string(data, "traceId") and _has_array(data, "events")
    if method == "POST" and path == "/api/v1/demo/reset":
        return (_has_string(data, "status") and _has_string(data, "userId") and _has_string(data, "traceId")
                and _is_nullable_record(data, "profile") and _is_nullable_record(data, "plan"))
    if method == "POST" and path == "/api/v1/agent/proactive":
        return (_has_boolean(data, "shouldNotify") and _has_string(data, "channel")
                and _is_string(data, "title") and _is_string(data, "body")
                and _is_record_field(data, "action") and _has_array(data, "contextTags")
                and _has_string(data, "reason") and _has_array(data, "factors")
                and _is_record_field(data, "cardData"))
    if method == "POST" and path == "/api/v1/auth/register":
        return _is_auth_session(data)
    if method == "POST" and path == "/api/v1/auth/login":
        return _is_auth_session(data)
    if method == "POST" and path == "/api/v1/auth/login-or-register":
        return _is_auth_session(data)
    if method == "POST" and path == "/api/v1/auth/login-with-huawei":
        return _is_auth_session(data)
    if method == "POST" and path == "/api/v1/auth/logout":
        return _has_string(data, "status")
    if method == "GET" and path == "/api/v1/auth/me":
        return _is_auth_user_field(data, "user")
    if method == "DELETE" and path == "/api/v1/auth/account":
        return _has_string(data, "status")
    # ---- 知识库（本模块此前没有校验项，语义检索上线后必须补上）----
    if method == "POST" and path.startswith("/api/v1/knowledge-bases/") and path.endswith("/search"):
        # 与 entry/src/main/ets/api/ApiResponseValidator.ets 的 knowledgeSearch 分支逐条对应
        return (_has_string(data, "kbId") and _has_string(data, "query")
                and _has_array(data, "hits") and _has_number(data, "totalScanned")
                and _has_string(data, "retrievalMode")
                and _has_boolean(data, "semanticAvailable")
                and _has_number(data, "semanticWeight"))
    if method == "POST" and path == "/api/v1/knowledge-bases":
        return _has_string(data, "kbId") and _has_string(data, "userId")
    if method == "GET" and path == "/api/v1/knowledge-bases":
        return _has_array(data, "knowledgeBases")
    # ---- 对话历史（按用户隔离后回传 userId）----
    if method == "GET" and path == "/api/agent/history":
        return _has_array(data, "history") and _has_string(data, "userId")
    return False


def _is_auth_session(data):
    return (_is_auth_user_field(data, "user") and _has_string(data, "token")
            and _has_string(data, "expiresAt"))


def check_contract(name, method, path, payload):
    """同时校验 HTTP 成功 + 前端能消费该响应。"""
    ok = frontend_valid(method, path, payload)
    record(f"前端契约校验 {name}", ok, f"{method} {path}",
           expected="ApiResponseValidator.isValid == true",
           actual="true" if ok else f"false; keys={sorted(payload.keys()) if _is_record(payload) else type(payload).__name__}")
    return ok


def run_workflow_probe(base, session_id):
    """探测：不提交答案连续 run，是否会空转（只涨 stateVersion 不做事）。

    这是前端 `WorkflowViewModel.runUntilComplete(maxRuns=5)` 的真实行为：
    它不接受 answers 参数，所以在 exercise 步会连打 5 次。
    """
    versions = []
    for _ in range(5):
        status, run, _ = http("POST", f"{base}/api/v1/workflows/{session_id}/run", {})
        if not isinstance(run, dict):
            break
        versions.append((run.get("stateVersion"), run.get("currentAgent"), run.get("status")))
    return versions


# --------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:5057")
    parser.add_argument("--out", default="integration_result.json")
    parser.add_argument("--skip-degradation-checks", action="store_true",
                        help="跳过「无 Key 时必须诚实降级」的断言（后端已配真 Key 时使用）")
    args = parser.parse_args()
    base = args.base.rstrip("/")
    skip_degradation = args.skip_degradation_checks

    print("=" * 78)
    print(f"  liantiao5 前后端联调验证  →  {base}")
    if skip_degradation:
        print("  模式：真实 LLM（跳过「无 Key 降级」断言）")
    print("=" * 78)

    # ---- 0. 探针 -------------------------------------------------------
    status, body, _ = http("GET", f"{base}/health", contract="")
    record("GET /health", status == 200 and isinstance(body, dict) and body.get("status") == "ok",
           f"HTTP {status}", expected="200 {'status':'ok'}", actual=f"{status} {body}")

    status, body, _ = http("GET", f"{base}/api/agent/health", contract="")
    record("GET /api/agent/health（前端连通探针）", status == 200,
           f"HTTP {status} llm_ready={body.get('llm_ready') if isinstance(body, dict) else '?'}",
           expected="200", actual=str(status))

    status, body, _ = http("GET", f"{base}/", contract="")
    record("GET /（根路径自描述）", status == 200 and isinstance(body, dict) and "contractVersion" in body,
           f"contractVersion={body.get('contractVersion') if isinstance(body, dict) else '?'}",
           expected=CONTRACT, actual=str(body.get("contractVersion") if isinstance(body, dict) else None))

    # ---- 1. 契约版本闸门 ------------------------------------------------
    status, body, _ = http("GET", f"{base}/api/v1/profile/demo-user", contract="api-contract-v0.2")
    record("契约版本不匹配 → 409", status == 409 and isinstance(body, dict) and body.get("errorCode") == "CONTRACT_VERSION_MISMATCH",
           f"HTTP {status} errorCode={body.get('errorCode') if isinstance(body, dict) else '?'}",
           expected="409 CONTRACT_VERSION_MISMATCH", actual=f"{status} {body.get('errorCode') if isinstance(body, dict) else '?'}")

    status, body, _ = http("GET", f"{base}/api/v1/profile/demo-user", contract="")
    record("v0.3 无版本头放行（curl/答辩演示友好）", status == 200, f"HTTP {status}", expected="200", actual=str(status))

    # ---- 2. 错误体结构 --------------------------------------------------
    status, body, _ = http("GET", f"{base}/api/v1/profile/missing-user")
    record("未知画像 → 404 且含 errorCode",
           status == 404 and isinstance(body, dict) and "errorCode" in body and "message" in body,
           f"HTTP {status} body={body}", expected="404 {errorCode,message,details}", actual=str(body))

    # ---- 3. 主链：reset -------------------------------------------------
    status, body, _ = http("POST", f"{base}/api/v1/demo/reset", {})
    record("POST /api/v1/demo/reset", status == 200, f"HTTP {status}", expected="200", actual=str(status))
    if isinstance(body, dict):
        check_contract("demo/reset", "POST", "/api/v1/demo/reset", body)

    # ---- 4. 主链：初始画像 / 计划 ---------------------------------------
    status, profile_v1, _ = http("GET", f"{base}/api/v1/profile/demo-user")
    mastery_v1 = None
    if isinstance(profile_v1, dict):
        check_contract("profile (V1)", "GET", "/api/v1/profile/demo-user", profile_v1)
        for item in profile_v1.get("mastery", []):
            if item.get("knowledgePointId") == "binary-tree-postorder":
                mastery_v1 = item.get("masteryScore")
    record("初始 mastery == 42", mastery_v1 == 42, f"masteryScore={mastery_v1}", expected=42, actual=mastery_v1)
    record("初始 profileVersion == 1",
           isinstance(profile_v1, dict) and profile_v1.get("profileVersion") == 1,
           f"profileVersion={profile_v1.get('profileVersion') if isinstance(profile_v1, dict) else '?'}",
           expected=1, actual=profile_v1.get("profileVersion") if isinstance(profile_v1, dict) else None)

    status, plan_v1, _ = http("GET", f"{base}/api/v1/plans/current")
    if isinstance(plan_v1, dict):
        check_contract("plans/current (V1)", "GET", "/api/v1/plans/current", plan_v1)
    durs_v1 = [t.get("durationMinutes") for t in plan_v1.get("tasks", [])] if isinstance(plan_v1, dict) else None
    record("初始 Plan V1 版本 == 1",
           isinstance(plan_v1, dict) and plan_v1.get("version") == 1,
           f"version={plan_v1.get('version') if isinstance(plan_v1, dict) else '?'}", expected=1,
           actual=plan_v1.get("version") if isinstance(plan_v1, dict) else None)
    record("初始 Plan V1 任务时长 == [30, 30]", durs_v1 == [30, 30], f"durations={durs_v1}",
           expected=[30, 30], actual=durs_v1)

    # ---- 5. 题集：不泄漏答案 --------------------------------------------
    status, ex_set, _ = http("GET", f"{base}/api/v1/exercises/set-demo-binary-tree-001")
    if isinstance(ex_set, dict):
        check_contract("exercises 题集", "GET", "/api/v1/exercises/set-demo-binary-tree-001", ex_set)
    exercises = ex_set.get("exercises", []) if isinstance(ex_set, dict) else []
    record("题集返回 3 题", len(exercises) == 3, f"len={len(exercises)}", expected=3, actual=len(exercises))
    leaked = [e.get("exerciseId") for e in exercises if "answerKey" in e]
    record("题集不泄漏 answerKey", not leaked, f"泄漏题目={leaked}", expected="[]", actual=str(leaked))

    excluded = "&".join(
        f"excludeExerciseId={urllib.parse.quote(str(item.get('exerciseId', '')))}"
        for item in exercises)
    status, refreshed_set, _ = http(
        "GET", f"{base}/api/v1/exercises/set-demo-binary-tree-001"
        f"?knowledgePointId=binary-tree-postorder&count=3&{excluded}")
    refreshed = refreshed_set.get("exercises", []) if isinstance(refreshed_set, dict) else []
    previous_ids = {item.get("exerciseId") for item in exercises}
    refreshed_ids = {item.get("exerciseId") for item in refreshed}
    record("再练一组会换成不同题目", status == 200 and len(refreshed) == 3
           and previous_ids.isdisjoint(refreshed_ids),
           f"上一组={sorted(previous_ids)} 新一组={sorted(refreshed_ids)}",
           expected="两组三题且 ID 不重复", actual=str(sorted(refreshed_ids)))

    # ---- 6. 提交 √√× → 66.67 -------------------------------------------
    submission = {
        "idempotencyKey": "verify-liantiao2-001",
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"},
        ],
    }
    status, submit, _ = http("POST", f"{base}/api/v1/exercises/set-demo-binary-tree-001/submit", submission)
    if isinstance(submit, dict):
        check_contract("exercise submit", "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit", submit)
    assessment = submit.get("assessment", {}) if isinstance(submit, dict) else {}
    score = assessment.get("score")
    record("提交 √√× → score == 66.67", score == 66.67, f"score={score}", expected=66.67, actual=score)

    mastery_update = submit.get("masteryUpdate", {}) if isinstance(submit, dict) else {}
    record("masteryUpdate 42 → 58",
           mastery_update.get("oldScore") == 42 and mastery_update.get("newScore") == 58,
           f"{mastery_update.get('oldScore')} → {mastery_update.get('newScore')}",
           expected="42 → 58", actual=f"{mastery_update.get('oldScore')} → {mastery_update.get('newScore')}")
    record("needReplan == true", submit.get("needReplan") is True,
           f"needReplan={submit.get('needReplan') if isinstance(submit, dict) else '?'}",
           expected=True, actual=submit.get("needReplan") if isinstance(submit, dict) else None)

    # 幂等重放
    status2, submit2, _ = http("POST", f"{base}/api/v1/exercises/set-demo-binary-tree-001/submit", submission)
    record("提交幂等（同 key 逐字节一致）", json.dumps(submit, sort_keys=True) == json.dumps(submit2, sort_keys=True),
           "两次响应一致" if json.dumps(submit, sort_keys=True) == json.dumps(submit2, sort_keys=True) else "两次响应不一致")

    # ---- 7. 写回：画像 / 计划 / diff / trace ----------------------------
    # 注意顺序：先把"提交后"的画像与计划读出来，再做会二次改进掌握度的对照提交，
    # 否则读到的不是本次 √√× 的结果。
    status, profile_v2, _ = http("GET", f"{base}/api/v1/profile/demo-user")
    mastery_v2 = None
    if isinstance(profile_v2, dict):
        check_contract("profile (V2)", "GET", "/api/v1/profile/demo-user", profile_v2)
        for item in profile_v2.get("mastery", []):
            if item.get("knowledgePointId") == "binary-tree-postorder":
                mastery_v2 = item.get("masteryScore")
    record("提交后 mastery 写回 == 58", mastery_v2 == 58, f"masteryScore={mastery_v2}", expected=58, actual=mastery_v2)
    record("提交后 profileVersion == 2",
           isinstance(profile_v2, dict) and profile_v2.get("profileVersion") == 2,
           f"profileVersion={profile_v2.get('profileVersion') if isinstance(profile_v2, dict) else '?'}",
           expected=2, actual=profile_v2.get("profileVersion") if isinstance(profile_v2, dict) else None)

    status, plan_v2, _ = http("GET", f"{base}/api/v1/plans/current")
    if isinstance(plan_v2, dict):
        check_contract("plans/current (V2)", "GET", "/api/v1/plans/current", plan_v2)
    durs_v2 = [t.get("durationMinutes") for t in plan_v2.get("tasks", [])] if isinstance(plan_v2, dict) else None
    record("重规划后 Plan V2 版本 == 2",
           isinstance(plan_v2, dict) and plan_v2.get("version") == 2,
           f"version={plan_v2.get('version') if isinstance(plan_v2, dict) else '?'}", expected=2,
           actual=plan_v2.get("version") if isinstance(plan_v2, dict) else None)
    record("Plan V2 任务时长 == [45, 15]", durs_v2 == [45, 15], f"durations={durs_v2}",
           expected=[45, 15], actual=durs_v2)

    status, diff, _ = http("GET", f"{base}/api/v1/plans/plan-demo-001/diff")
    if isinstance(diff, dict):
        check_contract("plan diff", "GET", "/api/v1/plans/plan-demo-001/diff", diff)
    record("Plan diff V1 → V2",
           isinstance(diff, dict) and diff.get("oldVersion") == 1 and diff.get("newVersion") == 2,
           f"oldVersion={diff.get('oldVersion') if isinstance(diff, dict) else '?'} newVersion={diff.get('newVersion') if isinstance(diff, dict) else '?'}",
           expected="1 → 2",
           actual=f"{diff.get('oldVersion') if isinstance(diff, dict) else '?'} → {diff.get('newVersion') if isinstance(diff, dict) else '?'}")
    record("plan diff adjustmentReason 非空",
           isinstance(diff, dict) and bool(diff.get("adjustmentReason")),
           f"adjustmentReason={diff.get('adjustmentReason') if isinstance(diff, dict) else '?'}")

    trace_id = submit.get("traceId") if isinstance(submit, dict) else None
    status, trace, _ = http("GET", f"{base}/api/v1/traces/{trace_id}")
    if isinstance(trace, dict):
        check_contract("trace", "GET", f"/api/v1/traces/{trace_id}", trace)
    record("提交 trace 可查", status == 200 and isinstance(trace, dict) and len(trace.get("events", [])) >= 1,
           f"HTTP {status} events={len(trace.get('events', [])) if isinstance(trace, dict) else '?'}")

    # ---- 7b. 对照提交：判分真的在算（B1 曾经的致命缺陷是恒返回 67） ----
    status3, all_wrong, _ = http("POST", f"{base}/api/v1/exercises/set-demo-binary-tree-001/submit", {
        "idempotencyKey": "verify-liantiao2-allwrong",
        "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "D"},
            {"exerciseId": "exercise-inorder-001", "answer": "D"},
            {"exerciseId": "exercise-postorder-001", "answer": "D"},
        ],
    })
    wrong_score = all_wrong.get("assessment", {}).get("score") if isinstance(all_wrong, dict) else None
    record("全错提交 → score == 0.0（判分真的在算）", wrong_score == 0.0,
           f"score={wrong_score}", expected=0.0, actual=wrong_score)
    record("全错与 √√× 分数不同（非固定值）", wrong_score != score,
           f"全错={wrong_score} vs √√×={score}", expected="不相等", actual=f"{wrong_score} vs {score}")
    wrong_mastery = all_wrong.get("masteryUpdate", {}).get("newScore") if isinstance(all_wrong, dict) else None
    record("全错提交 → 掌握度下降（不再出现全错也涨分）",
           isinstance(wrong_mastery, (int, float)) and wrong_mastery < mastery_v2,
           f"58 → {wrong_mastery}", expected="< 58", actual=wrong_mastery)

    # ---- 8. 工作流真 Agent 循环 -----------------------------------------
    status, wf_created, _ = http("POST", f"{base}/api/v1/workflows", {"goal": "诊断二叉树后序遍历"})
    if isinstance(wf_created, dict):
        check_contract("workflow create", "POST", "/api/v1/workflows", wf_created)
    session_id = wf_created.get("sessionId") if isinstance(wf_created, dict) else None
    record("POST /api/v1/workflows", status in (200, 201) and bool(session_id),
           f"HTTP {status} sessionId={session_id}", expected="2xx + sessionId", actual=f"{status} {session_id}")

    status, wf_status, _ = http("GET", f"{base}/api/v1/workflows/{session_id}")
    if isinstance(wf_status, dict):
        check_contract("workflow status", "GET", f"/api/v1/workflows/{session_id}", wf_status)

    # ---- 8a. 空转探测（前端 runUntilComplete 的真实调用形态）------------
    # 前端 runUntilComplete() 在等答题时应立即返回，而不是连打 5 次。
    # 若每次 run 都只涨 stateVersion 而不做事，就是"空转烧步数"。
    status, spin_wf, _ = http("POST", f"{base}/api/v1/workflows", {"goal": "空转探测"})
    spin_session = spin_wf.get("sessionId") if isinstance(spin_wf, dict) else None
    if spin_session:
        probe = run_workflow_probe(base, spin_session)
        agents_seen = {item[1] for item in probe}
        statuses_seen = {item[2] for item in probe}
        versions = [item[0] for item in probe]
        terminal = statuses_seen & {"completed", "error", "failed"}
        spun = (len(versions) > 1 and len(set(versions)) == len(versions)
                and len(agents_seen) == 1 and not terminal)
        record("连续 run 不提交答案：stateVersion 必须冻结（P0-1 修复验证）",
               not spun,
               f"stateVersion 轨迹={versions} agents={sorted(agents_seen)} statuses={sorted(statuses_seen)}"
               + ("  ← 每次只涨版本、重复同一 agent、永不进入终态，属空转" if spun else "  ← 已冻结，修复生效"),
               expected="重复 run 应保持 stateVersion 不变",
               actual=f"versions={versions}")
        status, spin_state, _ = http("GET", f"{base}/api/v1/workflows/{spin_session}")
        record("等答题状态对外可见（awaitingAnswers 语义）",
               isinstance(spin_wf, dict),
               f"currentAgent={spin_state.get('currentAgent') if isinstance(spin_state, dict) else '?'} "
               f"finalAction={spin_state.get('finalAction') if isinstance(spin_state, dict) else '?'}",
               expected="currentAgent=exercise + finalAction 提示提交答案",
               actual=str(spin_state.get("finalAction") if isinstance(spin_state, dict) else None))
        status, spin_trace, _ = http("GET", f"{base}/api/v1/traces/{spin_wf.get('traceId')}")
        spin_events = [e for e in (spin_trace or {}).get("events", []) if isinstance(e, dict)]
        record("空转不新增 trace 事件（重复 run 不写脏 trace）",
               len(spin_events) == 1,
               f"events={len(spin_events)}（期望恰好 1 条 exercise 事件）",
               expected=1, actual=len(spin_events))

    run_agents, run_tools = set(), set()
    final_status = None
    run_count = 0
    # 前端真实用法：run 会在 exercise 步进入 waiting（等用户答题），
    # 提交答案后再 run 才会继续 assessment → finish。
    for step in range(1, 9):
        payload = {} if step == 1 else {"answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"},
        ]}
        status, run, _ = http("POST", f"{base}/api/v1/workflows/{session_id}/run", payload)
        run_count += 1
        if not isinstance(run, dict):
            break
        if step == 1:
            check_contract("workflow run", "POST", f"/api/v1/workflows/{session_id}/run", run)
            # 后端把"等待用户答题"编码为 status=running + currentAgent=exercise
            # + finalAction=提交答案后继续评估，而不是 status=waiting。
            record("首次 run 停在等答题的 exercise 步（信号可识别）",
                   run.get("currentAgent") == "exercise"
                   and "提交答案" in str(run.get("finalAction", "")),
                   f"status={run.get('status')} currentAgent={run.get('currentAgent')} "
                   f"finalAction={run.get('finalAction')}",
                   expected="currentAgent=exercise + finalAction 提示提交答案",
                   actual=f"{run.get('currentAgent')} / {run.get('finalAction')}")
        if run.get("currentAgent"):
            run_agents.add(run["currentAgent"])
        for tool in run.get("toolCalls", []) or []:
            run_tools.add(tool)
        final_status = run.get("status")
        if final_status == "completed":
            break
    record("提交答案后 workflow 跑到 completed", final_status == "completed",
           f"status={final_status}（共 run {run_count} 次）", expected="completed", actual=final_status)
    record("单次 workflow 覆盖 ≥2 个 agent（run 响应口径）", len(run_agents) >= 2,
           f"agents={sorted(run_agents)}", expected=">=2", actual=len(run_agents))

    status, wf_trace, _ = http("GET", f"{base}/api/v1/traces/{wf_created.get('traceId')}")
    if isinstance(wf_trace, dict):
        check_contract("workflow trace", "GET", f"/api/v1/traces/{wf_created.get('traceId')}", wf_trace)
    events = [e for e in (wf_trace or {}).get("events", []) if isinstance(e, dict)]
    trace_agents = sorted({e.get("agent") for e in events if e.get("agent")})
    trace_tools = sorted({t for e in events for t in (e.get("toolCalls") or []) if t})
    record("workflow trace 留痕 ≥2 个 agent", len(trace_agents) >= 2,
           f"trace agents={trace_agents}", expected=">=2", actual=len(trace_agents))
    # tool 调用信息只出现在 trace 事件里（run 响应不含 toolCalls），
    # 前端 AgentTrace 页读的也正是 trace，所以口径必须用 trace。
    record("单次 workflow 覆盖 ≥3 个 tool（trace 口径）", len(trace_tools) >= 3,
           f"trace tools={trace_tools}", expected=">=3", actual=len(trace_tools))
    record("trace 事件数 ≥ run 次数（无静默丢失）", len(events) >= run_count,
           f"events={len(events)} run={run_count}", expected=f">= {run_count}", actual=len(events))
    forbidden = [k for e in events for k in e
                 if k.lower() in ("chainofthought", "reasoning", "thinking", "cot")]
    record("trace 不含思维链字段（合规红线）", not forbidden,
           f"命中={forbidden}", expected="[]", actual=str(forbidden))

    # ---- 9. 主动服务 -----------------------------------------------------
    # 注意：payload 必须用后端真正读取的字段名（见 app/agent/proactive.py）。
    # 曾经这里误写成 {freeTime, pendingTaskCount, daysToExam}，后端全都读不到，
    # 于是 shouldNotify 恒为 False —— 那是脚本的错，不是功能的错。
    # 下面这组参数与前端 ProactiveViewModel.buildRequest() 实际发送的一致。
    proactive_context = {
        "now": "2026-09-19T20:00:00+08:00",
        "foreground": False,
        "focusSessionActive": False,
        "daysLeft": 5,          # <=7 且 mastery<80 → exam_within_7d_low_mastery
        "masteryScore": 42,     # 演示基线掌握度
        "lastStudyAt": "2026-09-15T20:00:00+08:00",   # 隔 >=2 天 → no_study_for_2d
        "pendingTasks": [{"status": "pending", "started": False, "daysLeft": 2}],  # → pending_ddl_within_2d
    }
    status, proactive, _ = http("POST", f"{base}/api/v1/agent/proactive", {
        "userId": "demo-user",
        "context": proactive_context,
    })
    if isinstance(proactive, dict):
        check_contract("agent/proactive", "POST", "/api/v1/agent/proactive", proactive)
    tags = proactive.get("contextTags", []) if isinstance(proactive, dict) else []
    record("POST /api/v1/agent/proactive 可用", status == 200,
           f"HTTP {status} shouldNotify={proactive.get('shouldNotify') if isinstance(proactive, dict) else '?'}",
           expected=200, actual=str(status))
    record("主动服务：满足条件时真的会触发通知",
           isinstance(proactive, dict) and proactive.get("shouldNotify") is True
           and proactive.get("channel") == "reminder",
           f"shouldNotify={proactive.get('shouldNotify') if isinstance(proactive, dict) else '?'} "
           f"channel={proactive.get('channel') if isinstance(proactive, dict) else '?'}",
           expected="shouldNotify=true + channel=reminder",
           actual=f"{proactive.get('shouldNotify') if isinstance(proactive, dict) else '?'}")
    record("主动服务：三条触发理由都能命中",
           all(t in tags for t in ("pending_ddl_within_2d", "no_study_for_2d", "exam_within_7d_low_mastery")),
           f"contextTags={tags}",
           expected="含 pending_ddl_within_2d / no_study_for_2d / exam_within_7d_low_mastery",
           actual=str(tags))

    # 前台 / 专注中必须静默（不打扰用户是刻意设计）
    status, quiet, _ = http("POST", f"{base}/api/v1/agent/proactive", {
        "userId": "demo-user",
        "context": {**proactive_context, "foreground": True},
    })
    record("主动服务：前台使用时必须静默",
           isinstance(quiet, dict) and quiet.get("shouldNotify") is False,
           f"shouldNotify={quiet.get('shouldNotify') if isinstance(quiet, dict) else '?'}",
           expected=False, actual=quiet.get("shouldNotify") if isinstance(quiet, dict) else None)
    status, focus_quiet, _ = http("POST", f"{base}/api/v1/agent/proactive", {
        "userId": "demo-user",
        "context": {**proactive_context, "foreground": False, "focusSessionActive": True},
    })
    record("主动服务：专注会话中必须静默",
           isinstance(focus_quiet, dict) and focus_quiet.get("shouldNotify") is False,
           f"shouldNotify={focus_quiet.get('shouldNotify') if isinstance(focus_quiet, dict) else '?'}",
           expected=False, actual=focus_quiet.get("shouldNotify") if isinstance(focus_quiet, dict) else None)

    # ---- 10. 伙伴匹配（后端确定性算分） ---------------------------------
    status, partner, _ = http("POST", f"{base}/api/v1/agent/partner-match", {
        "user": {
            "userId": "demo-user",
            "learningGoal": {"course": "数据结构", "goal": "期末80+"},
            "time": {"freeTime": ["21:00-23:00"]},
            "knowledge": {"weakness": ["图算法"], "strength": ["递归理解"]},
            "basicInfo": {"grade": "大二", "major": "计算机科学与技术"},
        },
    })
    record("POST /api/v1/agent/partner-match 可用（后端确定性算分）", status == 200,
           f"HTTP {status} matched={partner.get('matchedCandidate', {}).get('candidate', {}).get('userId') if isinstance(partner, dict) else '?'}",
           expected=200, actual=str(status))

    # ---- 11. 聊天层（与工作流层同进程） ---------------------------------
    status, chat, _ = http("POST", f"{base}/api/agent/chat", {"message": "今天我应该先学什么？"},
              timeout=LLM_TIMEOUT)
    record("POST /api/agent/chat 同进程可用", status == 200 and isinstance(chat, dict) and bool(chat.get("reply")),
           f"HTTP {status} intent={chat.get('intent') if isinstance(chat, dict) else '?'}",
           expected="200 + reply", actual=f"{status} intent={chat.get('intent') if isinstance(chat, dict) else None}")

    status, chat_bad, _ = http("POST", f"{base}/api/agent/chat", {"message": "测试"},
              contract="api-contract-v0.2", timeout=LLM_TIMEOUT)
    record("聊天层拒绝错误契约版本", status == 409, f"HTTP {status}", expected=409, actual=str(status))

    status, chat_wrong, _ = http("POST", f"{base}/api/agent/chat", {"message": "帮我分析错题"},
              timeout=LLM_TIMEOUT)
    if skip_degradation:
        record("聊天层在真 LLM 模式下能正常识别意图",
               isinstance(chat_wrong, dict) and bool(chat_wrong.get("intent")),
               f"intent={chat_wrong.get('intent') if isinstance(chat_wrong, dict) else '?'}",
               expected="intent 非空", actual=chat_wrong.get("intent") if isinstance(chat_wrong, dict) else None)
    else:
        record("聊天层意图路由（错题）",
               isinstance(chat_wrong, dict) and chat_wrong.get("intent") == "analyze_wrong",
               f"intent={chat_wrong.get('intent') if isinstance(chat_wrong, dict) else '?'}",
               expected="analyze_wrong", actual=chat_wrong.get("intent") if isinstance(chat_wrong, dict) else None)

    # ---- 12. 鉴权 --------------------------------------------------------
    # 注册**必须带手机号**（手机号是唯一身份标识）。
    # 用时间戳构造唯一号码，避免多次运行撞唯一约束。
    unique_phone = "138" + f"{int(time.time()) % 100000000:08d}"
    status, register, _ = http("POST", f"{base}/api/v1/auth/register",
                               {"nickname": "联调验证", "grade": "大二",
                                "phone": unique_phone, "password": "secret88"})
    if isinstance(register, dict) and status in (200, 201):
        check_contract("auth register", "POST", "/api/v1/auth/register", register)
    record("注册返回会话（含 token / expiresAt）",
           status in (200, 201) and isinstance(register, dict) and "token" in register,
           f"HTTP {status}", expected="2xx + token", actual=str(status))

    # 手机号必须脱敏回传、且不得泄漏完整号码
    if isinstance(register, dict):
        user_view = register.get("user") or {}
        masked = user_view.get("phoneMasked", "")
        record("注册响应回传脱敏手机号（不回传完整号码）",
               isinstance(masked, str) and "****" in masked and unique_phone not in json.dumps(register),
               f"phoneMasked={masked}",
               expected="138****xxxx 且不含完整号码", actual=masked or "（缺失）")

    # 注册缺手机号 → 400（唯一身份标识不可省）
    status_no_phone, _, _ = http("POST", f"{base}/api/v1/auth/register",
                                 {"nickname": "无号联调"})
    record("注册缺手机号被拒（400）", status_no_phone == 400,
           f"HTTP {status_no_phone}", expected=400, actual=str(status_no_phone))

    # 按手机号登录（换设备场景的主入口）
    status_phone_login, phone_login, _ = http("POST", f"{base}/api/v1/auth/login",
                                              {"phone": unique_phone, "password": "secret88"})
    same_user = (isinstance(register, dict) and isinstance(phone_login, dict)
                 and (register.get("user") or {}).get("userId")
                 == (phone_login.get("user") or {}).get("userId"))
    record("按手机号登录登回同一账号", status_phone_login == 200 and same_user,
           f"HTTP {status_phone_login} sameUser={same_user}",
           expected="200 且 userId 一致", actual=str(status_phone_login))

    status_wrong_password, _, _ = http("POST", f"{base}/api/v1/auth/login",
                                       {"phone": unique_phone, "password": "wrong000"})
    record("密码登录确实由后端校验", status_wrong_password == 401,
           f"错误密码 HTTP {status_wrong_password}", expected=401,
           actual=str(status_wrong_password))

    # 华为账号一键登录（登录优先，注册兜底）
    hw_open_id = f"verify-hw-open-{int(time.time())}"
    status_hw, hw_first, _ = http("POST", f"{base}/api/v1/auth/login-with-huawei",
                                  {"openId": hw_open_id})
    if isinstance(hw_first, dict) and status_hw in (200, 201):
        check_contract("auth login-with-huawei", "POST",
                       "/api/v1/auth/login-with-huawei", hw_first)
    record("华为账号首次登录自动建号", status_hw == 201
           and isinstance(hw_first, dict) and hw_first.get("created") is True,
           f"HTTP {status_hw} created={hw_first.get('created') if isinstance(hw_first, dict) else '?'}",
           expected="201 + created=true", actual=str(status_hw))

    status_hw2, hw_second, _ = http("POST", f"{base}/api/v1/auth/login-with-huawei",
                                    {"openId": hw_open_id})
    hw_same = (isinstance(hw_first, dict) and isinstance(hw_second, dict)
               and (hw_first.get("user") or {}).get("userId")
               == (hw_second.get("user") or {}).get("userId"))
    record("华为账号再次登录复用账号（不重复建号）",
           status_hw2 == 200 and hw_same and hw_second.get("created") is False,
           f"HTTP {status_hw2} created={hw_second.get('created') if isinstance(hw_second, dict) else '?'}",
           expected="200 + created=false + 同一 userId", actual=str(status_hw2))

    if isinstance(hw_first, dict):
        record("华为账号登录不泄漏 OpenID",
               hw_open_id not in json.dumps(hw_first),
               "响应中无 OpenID" if hw_open_id not in json.dumps(hw_first) else "⚠️ 泄漏了 OpenID",
               expected="不含 OpenID", actual="无" if hw_open_id not in json.dumps(hw_first) else "有")

    token = register.get("token") if isinstance(register, dict) else None
    if token:
        request = urllib.request.Request(f"{base}/api/v1/auth/me", method="GET")
        request.add_header("X-API-Contract-Version", CONTRACT)
        request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                me = json.loads(response.read().decode("utf-8"))
                me_status = response.status
        except urllib.error.HTTPError as error:
            me, me_status = None, error.code
        record("带 token 访问 /api/v1/auth/me", me_status == 200 and isinstance(me, dict),
               f"HTTP {me_status}", expected=200, actual=str(me_status))
        if isinstance(me, dict):
            check_contract("auth me", "GET", "/api/v1/auth/me", me)

    # ---- 13. 实验数据导出 ------------------------------------------------
    status, snapshot, _ = http("GET", f"{base}/api/v1/experiments/snapshot")
    record("GET /api/v1/experiments/snapshot（答辩可量化素材）", status == 200 and isinstance(snapshot, dict),
           f"HTTP {status} keys={sorted(snapshot.keys()) if isinstance(snapshot, dict) else '?'}",
           expected=200, actual=str(status))

    # ---- 14. 降级诚实性 --------------------------------------------------
    # 三项断言只在"后端没有可用 Key"时成立。配了真 Key 后按定义不再适用
    # （llmUsed 会变成 true），所以按模式跳过，避免看到假失败。
    status, img_chat, _ = http(
        "POST", f"{base}/api/agent/chat",
        {"message": "帮我分析这道题", "image": _LIVE_IMAGE_BASE64},
        timeout=LLM_TIMEOUT)
    reply_text = img_chat.get("reply", "") if isinstance(img_chat, dict) else ""
    llm_used = img_chat.get("llmUsed") if isinstance(img_chat, dict) else None
    if skip_degradation:
        record("多模态调用在真 LLM 模式下确实走了模型",
               status == 200 and llm_used is True,
               f"HTTP {status} llmUsed={llm_used} reply[:40]={reply_text[:40]!r}",
               expected="200 + llmUsed=true", actual=f"{status} llmUsed={llm_used}")
    else:
        has_downgrade_note = (llm_used is False) or "本地规则" in reply_text or "未接入多模态" in reply_text
        record("无 LLM Key 时不伪装多模态识别（llmUsed=false + 明示降级）",
               status == 200 and has_downgrade_note,
               f"HTTP {status} llmUsed={llm_used} reply[:40]={reply_text[:40]!r}",
               expected="200 + llmUsed=false", actual=f"{status} llmUsed={llm_used}")

    status, txt_chat, _ = http("POST", f"{base}/api/agent/chat", {"message": "今天我应该先学什么？"},
              timeout=LLM_TIMEOUT)
    if skip_degradation:
        record("纯文本回复在真 LLM 模式下确实走了模型",
               isinstance(txt_chat, dict) and txt_chat.get("llmUsed") is True and bool(txt_chat.get("reply")),
               f"llmUsed={txt_chat.get('llmUsed') if isinstance(txt_chat, dict) else '?'}",
               expected=True, actual=txt_chat.get("llmUsed") if isinstance(txt_chat, dict) else None)
    else:
        record("无 Key 时纯文本回复也标注本地规则兜底",
               isinstance(txt_chat, dict) and txt_chat.get("llmUsed") is False and bool(txt_chat.get("reply")),
               f"llmUsed={txt_chat.get('llmUsed') if isinstance(txt_chat, dict) else '?'}",
               expected=False, actual=txt_chat.get("llmUsed") if isinstance(txt_chat, dict) else None)
    card = txt_chat.get("card") if isinstance(txt_chat, dict) else None
    record("聊天响应携带结构化卡片（可跳转页面）",
           isinstance(card, dict) and bool(card.get("targetPage")),
           f"card.targetPage={card.get('targetPage') if isinstance(card, dict) else '?'}",
           expected="targetPage 非空", actual=card.get("targetPage") if isinstance(card, dict) else None)

    # ---- 15. 工作流：「带答案恢复」完整链路 -------------------------------
    # 前端 ExerciseViewModel 走的就是 submissionId 路径，这里两条都验。
    status, resume_wf, _ = http("POST", f"{base}/api/v1/workflows", {"goal": "带答案恢复验证"})
    resume_session = resume_wf.get("sessionId") if isinstance(resume_wf, dict) else None
    if resume_session:
        status, waiting, _ = http("POST", f"{base}/api/v1/workflows/{resume_session}/run", {})
        status, stuck, _ = http("POST", f"{base}/api/v1/workflows/{resume_session}/run", {})
        record("等答题期间重复 run 不再推进（前端可安全重试）",
               isinstance(waiting, dict) and isinstance(stuck, dict)
               and waiting.get("stateVersion") == stuck.get("stateVersion"),
               f"{waiting.get('stateVersion') if isinstance(waiting, dict) else '?'} → "
               f"{stuck.get('stateVersion') if isinstance(stuck, dict) else '?'}",
               expected="两次 stateVersion 相同",
               actual=f"{waiting.get('stateVersion') if isinstance(waiting, dict) else '?'} vs "
                      f"{stuck.get('stateVersion') if isinstance(stuck, dict) else '?'}")

        status, resumed, _ = http("POST", f"{base}/api/v1/workflows/{resume_session}/run", {"answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "C"},
        ]})
        record("提交答案后从 exercise 走到 completed",
               isinstance(resumed, dict) and resumed.get("status") == "completed"
               and resumed.get("currentAgent") == "finish",
               f"status={resumed.get('status') if isinstance(resumed, dict) else '?'} "
               f"currentAgent={resumed.get('currentAgent') if isinstance(resumed, dict) else '?'}",
               expected="completed / finish",
               actual=str(resumed.get("status") if isinstance(resumed, dict) else None))
        record("恢复后 awaitingAnswers 被清除",
               isinstance(resumed, dict)
               and (resumed.get("state") or {}).get("awaitingAnswers") is False,
               f"state.awaitingAnswers={(resumed.get('state') or {}).get('awaitingAnswers') if isinstance(resumed, dict) else '?'}",
               expected=False,
               actual=(resumed.get("state") or {}).get("awaitingAnswers") if isinstance(resumed, dict) else None)

        status, r_trace, _ = http("GET", f"{base}/api/v1/traces/{resume_wf.get('traceId')}")
        r_agents = [e.get("agent") for e in (r_trace or {}).get("events", []) if isinstance(e, dict)]
        record("恢复后 trace 的 agent 序列干净（无重复 exercise）",
               r_agents == ["exercise", "assessment", "secretary"],
               f"agents={r_agents}",
               expected="['exercise','assessment','secretary']", actual=str(r_agents))

    # ---- 17. 知识库检索：语义字段与诚实降级标注 -------------------------
    import base64 as _b64

    kb = None
    status, created, _ = http("POST", f"{base}/api/v1/knowledge-bases",
                              {"courseName": "数据结构", "name": "联调知识库"})
    if status in (200, 201) and isinstance(created, dict):
        kb = created.get("kbId")
        check_contract("knowledge-bases create", "POST", "/api/v1/knowledge-bases", created)

    if kb:
        duplicate_status, duplicate, _ = http(
            "POST", f"{base}/api/v1/knowledge-bases",
            {"courseName": " 数据结构 ", "name": "另一套资料"})
        record("一门课程只能有一个知识库", duplicate_status == 409
               and isinstance(duplicate, dict)
               and (duplicate.get("details") or {}).get("kbId") == kb,
               f"HTTP {duplicate_status} kbId={(duplicate.get('details') or {}).get('kbId') if isinstance(duplicate, dict) else '?'}",
               expected="409 且返回已有 kbId", actual=str(duplicate_status))

        note = "# 二叉树遍历\n\n## 后序遍历\n\n后序遍历的顺序是左右根。\n"
        http("POST", f"{base}/api/v1/knowledge-bases/{kb}/documents",
             {"fileName": "笔记.md",
              "contentBase64": _b64.b64encode(note.encode("utf-8")).decode("utf-8")})

        status, found, _ = http("POST", f"{base}/api/v1/knowledge-bases/{kb}/search",
                                {"query": "后序遍历的顺序", "topK": 5})
        record("知识库检索可用", status == 200 and isinstance(found, dict) and bool(found.get("hits")),
               f"HTTP {status} hits={len(found.get('hits', [])) if isinstance(found, dict) else '?'}",
               expected="HTTP 200 且 hits 非空", actual=f"HTTP {status}")
        if isinstance(found, dict):
            check_contract("knowledge search", "POST",
                           "/api/v1/knowledge-bases/{kbId}/search", found)
            mode = found.get("retrievalMode")
            record("检索方式被诚实标注（keyword+tag 或 hybrid）",
                   mode in ("keyword+tag", "hybrid:semantic+keyword+tag", "vector"),
                   f"retrievalMode={mode}",
                   expected="keyword+tag | hybrid:semantic+keyword+tag | vector", actual=str(mode))
            # 语义能力与权重必须自洽：没能力时权重必须是 0，有能力时混合模式权重必须 > 0
            available = found.get("semanticAvailable")
            weight = found.get("semanticWeight")
            consistent = ((available is False and weight == 0)
                          or (available is True and isinstance(weight, (int, float))))
            record("语义能力与权重自洽（不伪装）", bool(consistent),
                   f"semanticAvailable={available} semanticWeight={weight}",
                   expected="无能力→权重0；有能力→权重>0", actual=f"{available}/{weight}")

        http("DELETE", f"{base}/api/v1/knowledge-bases/{kb}")

    # ---- 18. 对话历史按用户隔离（原先全局可读可删）------------------------
    http("DELETE", f"{base}/api/agent/history?userId=probe-a")
    http("DELETE", f"{base}/api/agent/history?userId=probe-b")
    http("POST", f"{base}/api/agent/chat", {"message": "甲的问题", "userId": "probe-a"},
         timeout=LLM_TIMEOUT)
    http("POST", f"{base}/api/agent/chat", {"message": "乙的问题", "userId": "probe-b"},
         timeout=LLM_TIMEOUT)

    status, hist_a, _ = http("GET", f"{base}/api/agent/history?userId=probe-a")
    check_contract("agent history", "GET", "/api/agent/history", hist_a)
    inputs_a = [e.get("user_input") for e in (hist_a or {}).get("history", [])] \
        if isinstance(hist_a, dict) else []
    record("对话历史按用户隔离（甲只看得到自己的）", inputs_a == ["甲的问题"],
           f"甲的历史={inputs_a}", expected="['甲的问题']", actual=str(inputs_a))

    http("DELETE", f"{base}/api/agent/history?userId=probe-a")
    status, hist_b, _ = http("GET", f"{base}/api/agent/history?userId=probe-b")
    inputs_b = [e.get("user_input") for e in (hist_b or {}).get("history", [])] \
        if isinstance(hist_b, dict) else []
    record("清理甲的历史不影响乙（原先 DELETE 会清空所有人）", inputs_b == ["乙的问题"],
           f"乙的历史={inputs_b}", expected="['乙的问题']", actual=str(inputs_b))
    http("DELETE", f"{base}/api/agent/history?userId=probe-b")

    # ---- 19. 非 2xx 的 HTTP 错误必须是 JSON（前端校验器按 JSON 解析）------
    status, body, _ = http("GET", f"{base}/api/v1/workflows")
    record("方法不允许 → 405 且返回 JSON errorCode",
           status == 405 and isinstance(body, dict) and body.get("errorCode") == "BAD_REQUEST",
           f"HTTP {status} body={type(body).__name__}",
           expected="405 且 errorCode=BAD_REQUEST", actual=f"HTTP {status}")
    status, body, _ = http("POST", f"{base}/api/v1/workflows", raw_text="not json",
                           content_type="text/plain")
    record("非 JSON 请求体 → JSON 400（不是 HTML 错误页）",
           status == 400 and isinstance(body, dict) and body.get("errorCode") == "BAD_REQUEST",
           f"HTTP {status} body={type(body).__name__}",
           expected="400 且 errorCode=BAD_REQUEST", actual=f"HTTP {status}")

    # ---- 20. CORS 不再反射任意 Origin ------------------------------------
    try:
        import urllib.request as _url

        request = _url.Request(f"{base}/api/agent/health",
                               headers={"Origin": "https://evil.example.com"})
        with _url.urlopen(request, timeout=10) as response:
            allowed = response.headers.get("Access-Control-Allow-Origin")
    except Exception:  # noqa: BLE001
        allowed = None
    record("CORS 不反射任意 Origin（原先裸 CORS(app)）",
           allowed not in ("https://evil.example.com", "*"),
           f"Access-Control-Allow-Origin={allowed!r}",
           expected="不反射 evil.example.com、不为 *", actual=str(allowed))

    try:
        import urllib.request as _url2

        request = _url2.Request(f"{base}/api/agent/health",
                                headers={"Origin": "http://localhost:8080"})
        with _url2.urlopen(request, timeout=10) as response:
            local_allowed = response.headers.get("Access-Control-Allow-Origin")
    except Exception:  # noqa: BLE001
        local_allowed = None
    record("CORS 仍放行本机开发来源（收紧不能误伤联调）",
           local_allowed == "http://localhost:8080",
           f"Access-Control-Allow-Origin={local_allowed!r}",
           expected="http://localhost:8080", actual=str(local_allowed))

    # ---- 21. 契约字段覆盖：前端已在用的字段必须在契约里 -------------------
    contract_path = ROOT / "contracts" / "openapi.json"
    contract_text = contract_path.read_text(encoding="utf-8") if contract_path.exists() else ""
    record("契约声明 llmUsed（前端 ChatMain 已展示该字段）",
           "llmUsed" in contract_text,
           "契约已声明" if "llmUsed" in contract_text else "契约缺 llmUsed —— 前端已消费但契约未声明",
           expected="contracts/openapi.json 含 llmUsed",
           actual="有" if "llmUsed" in contract_text else "无")
    record("契约声明 pendingTasks（前端 ProactiveViewModel 已发送该字段）",
           "pendingTasks" in contract_text,
           "契约已声明" if "pendingTasks" in contract_text else "契约缺 pendingTasks",
           expected="contracts/openapi.json 含 pendingTasks",
           actual="有" if "pendingTasks" in contract_text else "无")
    record("契约声明语义检索字段（前端 KnowledgeBase 已展示 retrievalMode）",
           "semanticAvailable" in contract_text and "semanticWeight" in contract_text
           and "hybrid:semantic+keyword+tag" in contract_text,
           "契约已声明" if "semanticAvailable" in contract_text else "契约缺语义检索字段",
           expected="契约含 retrievalMode.hybrid / semanticAvailable / semanticWeight",
           actual="有" if "semanticAvailable" in contract_text else "无")

    # ---- 汇总 ------------------------------------------------------------
    passed = sum(1 for r in RESULTS if r["ok"])
    total = len(RESULTS)
    summary = {
        "base": base,
        "contract": CONTRACT,
        "total": total,
        "passed": passed,
        "failed": total - passed,
        "passRate": round(passed / total * 100, 2) if total else 0.0,
        "baseline": {
            "score": score,
            "allWrongScore": wrong_score,
            "oldMastery": mastery_v1,
            "newMastery": mastery_v2,
            "profileVersion": [profile_v1.get("profileVersion") if isinstance(profile_v1, dict) else None,
                               profile_v2.get("profileVersion") if isinstance(profile_v2, dict) else None],
            "planVersion": [plan_v1.get("version") if isinstance(plan_v1, dict) else None,
                            plan_v2.get("version") if isinstance(plan_v2, dict) else None],
            "planDurations": [durs_v1, durs_v2],
            "workflowAgents": sorted(run_agents),
            "workflowTools": sorted(run_tools),
        },
        "checks": RESULTS,
    }

    print("=" * 78)
    print(f"  结果：{passed}/{total} 通过（通过率 {summary['passRate']}%）")
    print("=" * 78)
    failed = [r for r in RESULTS if not r["ok"]]
    if failed:
        print("失败项：")
        for item in failed:
            print(f"  [X] {item['check']}")
            print(f"      期望: {item['expected']}")
            print(f"      实际: {item['actual']}")

    with open(args.out, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(f"\n结果已写入 {args.out}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
