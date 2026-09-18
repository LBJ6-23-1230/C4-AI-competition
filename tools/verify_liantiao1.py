# -*- coding: utf-8 -*-
"""liantiao1 联调自检脚本（单一后端，单一 baseUrl）。

覆盖五层验证：

  ⓪ 静态一致性 —— 契约双份文件逐字节一致、契约版本、无硬编码 IP
  ① 单元测试   —— 后端 pytest 全量测试套件
  ② 契约主链   —— demo/reset → exercises → submit(√√×) → profile → plan → diff → trace
  ③ 回归护栏   —— 旧缺陷不得复现（判分随答案变化 / 全错不涨掌握度 / 时长不漂移 / 幂等重放）
  ④ Agent 循环 + trace + 聊天层 + proactive + 错误结构 + 实验数据导出

用法（在 liantiao1 根目录执行）::

    python tools\\verify_liantiao1.py --start-server
    E:\\C4联调\\.venv-lt\\Scripts\\python.exe tools\\verify_liantiao1.py --start-server

退出码 0 = 全部通过；原始结果写入 evidence/verify_result.json。
"""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "buffer"):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server" / "zhixue-agent-server"
CONTRACT = "api-contract-v0.3"

# 文档固定的 √√× 演示提交（2 对 1 错）
DEMO_ANSWERS = [
    {"exerciseId": "exercise-preorder-001", "answer": "A"},
    {"exerciseId": "exercise-inorder-001", "answer": "B"},
    {"exerciseId": "exercise-postorder-001", "answer": "A"},
]
ALL_CORRECT = [
    {"exerciseId": "exercise-preorder-001", "answer": "A"},
    {"exerciseId": "exercise-inorder-001", "answer": "B"},
    {"exerciseId": "exercise-postorder-001", "answer": "C"},
]
ALL_WRONG = [
    {"exerciseId": "exercise-preorder-001", "answer": "B"},
    {"exerciseId": "exercise-inorder-001", "answer": "C"},
    {"exerciseId": "exercise-postorder-001", "answer": "A"},
]

RESULTS: list[dict] = []


def call(base: str, method: str, path: str, body=None, contract: bool = True, timeout: int = 30,
         charset: bool = False, headers: dict | None = None):
    """发起一次 HTTP 调用。

    `charset=True` 时显式带上 `Content-Type: application/json; charset=utf-8`——
    这是 PowerShell `Invoke-RestMethod` 等客户端的实际行为，用于验证服务端不会因为它
    而丢掉中文消息（曾导致意图识别静默退化为 get_suggestion）。

    `headers` 用于附加自定义请求头（例如 `Authorization: Bearer <token>`）。
    """
    request = urllib.request.Request(
        base + path,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None,
        method=method,
    )
    request.add_header("Accept", "application/json")
    if body is not None:
        if charset:
            request.add_header("Content-Type", "application/json; charset=utf-8")
        else:
            request.add_header("Content-Type", "application/json")
    if contract:
        request.add_header("X-API-Contract-Version", CONTRACT)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw, status = response.read().decode("utf-8", "ignore"), response.status
    except urllib.error.HTTPError as error:
        raw, status = error.read().decode("utf-8", "ignore"), error.code
    except Exception as error:  # noqa: BLE001
        return None, {"_transportError": str(error)}
    try:
        return status, (json.loads(raw) if raw.strip() else None)
    except json.JSONDecodeError:
        return status, {"_raw": raw[:300]}


def check(group: str, label: str, actual, expected) -> bool:
    ok = actual == expected
    RESULTS.append({"group": group, "check": label, "ok": ok,
                    "actual": repr(actual)[:200], "expected": repr(expected)[:200]})
    print("  [%s] %-58s actual=%-30s expected=%s"
          % ("PASS" if ok else "FAIL", label, repr(actual)[:30], repr(expected)[:30]))
    return ok


def note(group: str, label: str, observed) -> None:
    RESULTS.append({"group": group, "check": label, "ok": True,
                    "actual": repr(observed)[:200], "expected": "(observation)"})
    print("  [INFO] %-58s %s" % (label, repr(observed)[:70]))


# --------------------------------------------------------------------------- ⓪ 静态一致性
def run_static_consistency() -> None:
    """不依赖后端进程的静态护栏：契约单一真源 + 前端默认地址单一真源。"""
    group = "static-consistency"
    print("\n" + "=" * 100)
    print("⓪ 静态一致性护栏（契约与默认地址不得出现双份真源）")
    print("=" * 100)

    import hashlib

    root_contract = ROOT / "contracts" / "openapi.json"
    server_contract = ROOT / "server" / "contracts" / "openapi.json"
    root_digest = hashlib.md5(root_contract.read_bytes()).hexdigest() if root_contract.exists() else None
    server_digest = hashlib.md5(server_contract.read_bytes()).hexdigest() if server_contract.exists() else None
    check(group, "前后端契约文件逐字节一致（无 v0.2/v0.3 漂移）",
          root_digest == server_digest and root_digest is not None, True)

    contract_text = root_contract.read_text(encoding="utf-8") if root_contract.exists() else ""
    check(group, "契约版本为 api-contract-v0.3",
          '"version": "api-contract-v0.3"' in contract_text, True)

    defaults = ROOT / "entry" / "src" / "main" / "ets" / "api" / "ApiDefaults.ets"
    defaults_text = defaults.read_text(encoding="utf-8") if defaults.exists() else ""
    check(group, "前端存在 ApiDefaults 单一真源文件", defaults.exists(), True)
    check(group, "ApiDefaults 契约版本与后端一致",
          "api-contract-v0.3" in defaults_text, True)

    # 页面里不得再硬编码宿主机 IP（仅允许出现在注释与输入框占位提示里）
    offenders: list[str] = []
    ets_root = ROOT / "entry" / "src" / "main" / "ets"
    for path in sorted(ets_root.rglob("*.ets")):
        if path.name == "ApiDefaults.ets":
            continue
        in_block_comment = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if in_block_comment:
                if "*/" in stripped:
                    in_block_comment = False
                continue
            if stripped.startswith("/*") and "*/" not in stripped:
                in_block_comment = True
                continue
            if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
                continue
            if "placeholder" in stripped:
                continue
            if "10.0.2.2" in stripped or "127.0.0.1" in stripped or "192.168." in stripped:
                offenders.append("%s:%d" % (path.relative_to(ROOT), number))
    check(group, "页面中无硬编码后端 IP（应统一引用 ApiDefaults）", offenders, [])

    api_models = ROOT / "entry" / "src" / "main" / "ets" / "api" / "ApiModels.ets"
    models_text = api_models.read_text(encoding="utf-8") if api_models.exists() else ""
    check(group, "ApiModels 契约版本 = v0.3", "api-contract-v0.3" in models_text, True)

    # ---- 演示身份单一真源：前端 ApiDefaults 与后端 auth/service 必须一致 ----
    auth_service = SERVER_DIR / "app" / "auth" / "service.py"
    auth_text = auth_service.read_text(encoding="utf-8") if auth_service.exists() else ""
    check(group, "后端存在鉴权领域模块", auth_service.exists(), True)
    check(group, "后端 DEMO_USER_ID = demo-user",
          'DEMO_USER_ID = "demo-user"' in auth_text, True)
    check(group, "前端 DEMO_USER_ID = demo-user",
          "DEMO_USER_ID: string = 'demo-user'" in defaults_text, True)

    # 除 ApiDefaults 外，页面与传输层不得再硬编码游客 userId
    demo_literal_offenders: list[str] = []
    for path in sorted(ets_root.rglob("*.ets")):
        if path.name in ("ApiDefaults.ets", "MockData.ets"):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            if "'demo-user'" in stripped:
                demo_literal_offenders.append("%s:%d" % (path.relative_to(ROOT), number))
    check(group, "游客 userId 无散落硬编码（应统一引用 ApiDefaults）",
          demo_literal_offenders, [])

    # ---- 登录功能的页面与模块必须真实存在 ----
    required = [
        "entry/src/main/ets/pages/Login.ets",
        "entry/src/main/ets/pages/Account.ets",
        "entry/src/main/ets/api/AuthModels.ets",
        "entry/src/main/ets/api/AuthStore.ets",
        "entry/src/main/ets/api/AuthClient.ets",
        "entry/src/main/ets/api/AuthResult.ets",
        "server/zhixue-agent-server/app/api/auth.py",
        "server/zhixue-agent-server/tests/test_auth.py",
    ]
    missing = [item for item in required if not (ROOT / item).exists()]
    check(group, "登录功能文件齐备（页面/模型/存储/客户端/接口/测试）", missing, [])

    pages = (ROOT / "entry" / "src" / "main" / "resources" / "base" / "profile" / "main_pages.json")
    pages_text = pages.read_text(encoding="utf-8") if pages.exists() else ""
    check(group, "Login / Account 已注册到 main_pages.json",
          "pages/Login" in pages_text and "pages/Account" in pages_text, True)

    # 契约里必须声明鉴权接口与 Bearer 方案
    for path_name in ("/api/v1/auth/register", "/api/v1/auth/login",
                      "/api/v1/auth/me", "/api/v1/auth/logout", "/api/v1/auth/account"):
        check(group, "契约声明 %s" % path_name, path_name in contract_text, True)
    check(group, "契约声明 BearerAuth 安全方案", '"BearerAuth"' in contract_text, True)


# --------------------------------------------------------------------------- ① pytest
def run_pytest() -> bool:
    group = "pytest"
    print("\n" + "=" * 100)
    print("① 后端单元测试套件  @ %s" % SERVER_DIR)
    print("=" * 100)
    basetemp = ROOT / ".verify-tmp"
    command = [sys.executable, "-m", "pytest", "-q", "tests/",
               "--basetemp=%s" % basetemp, "-p", "no:cacheprovider", "--tb=short"]
    completed = subprocess.run(command, cwd=str(SERVER_DIR), capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
    lines = [line for line in (completed.stdout or "").splitlines() if line.strip()]
    for line in lines[-3:]:
        print("   " + line)
    summary = " ".join(lines[-3:])
    passed = "failed" not in summary and "error" not in summary and completed.returncode == 0
    check(group, "pytest 全绿（退出码 0，无 failed/error）", passed, True)
    return passed


# --------------------------------------------------------------------------- ② 契约主链
def run_contract_chain(base: str) -> None:
    group = "contract-main-chain"
    print("\n" + "=" * 100)
    print("② 契约主链（演示故事线数值必须逐项命中）  @ %s" % base)
    print("=" * 100)

    status, _ = call(base, "GET", "/health", contract=False)
    check(group, "GET /health -> 200", status, 200)

    status, health = call(base, "GET", "/api/agent/health", contract=False)
    check(group, "GET /api/agent/health -> 200（前端连通性探针）", status, 200)
    note(group, "llm_ready / model", ((health or {}).get("llm_ready"), (health or {}).get("model")))

    status, _ = call(base, "POST", "/api/v1/demo/reset", {})
    check(group, "POST /api/v1/demo/reset -> 200", status, 200)

    status, profile = call(base, "GET", "/api/v1/profile/demo-user")
    check(group, "profileVersion 初始 = 1", (profile or {}).get("profileVersion"), 1)
    check(group, "mastery 初始 = 42",
          ((profile or {}).get("mastery") or [{}])[0].get("masteryScore"), 42)

    status, plan = call(base, "GET", "/api/v1/plans/current")
    check(group, "plan version 初始 = 1", (plan or {}).get("version"), 1)
    check(group, "V1 时长 = [30, 30]",
          [t.get("durationMinutes") for t in (plan or {}).get("tasks", [])], [30, 30])

    status, exercises = call(
        base, "GET",
        "/api/v1/exercises/set-demo-binary-tree-001?knowledgePointId=binary-tree-postorder&count=3")
    items = (exercises or {}).get("exercises", [])
    check(group, "题集返回 3 道题", len(items), 3)
    check(group, "题目 ID 正确",
          [e.get("exerciseId") for e in items],
          ["exercise-preorder-001", "exercise-inorder-001", "exercise-postorder-001"])
    check(group, "题集不泄漏 answerKey", any("answerKey" in e for e in items), False)

    stamp = int(time.time())
    status, submit = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                          {"idempotencyKey": "verify-%d" % stamp, "answers": DEMO_ANSWERS})
    check(group, "POST submit -> 200", status, 200)
    assessment = (submit or {}).get("assessment", {})
    check(group, "score = 66.67（√√×：2 对 1 错）", assessment.get("score"), 66.67)
    check(group, "oldMastery = 42", assessment.get("oldMastery"), 42)
    check(group, "suggestedNewMastery = 58", assessment.get("suggestedNewMastery"), 58)
    check(group, "needReplan = true", (submit or {}).get("needReplan"), True)

    status, profile2 = call(base, "GET", "/api/v1/profile/demo-user")
    check(group, "profileVersion 提交后 = 2", (profile2 or {}).get("profileVersion"), 2)
    check(group, "mastery 写回 = 58",
          ((profile2 or {}).get("mastery") or [{}])[0].get("masteryScore"), 58)

    status, diff = call(base, "GET", "/api/v1/plans/plan-demo-001/diff")
    check(group, "plan V1 -> V2",
          ((diff or {}).get("oldVersion"), (diff or {}).get("newVersion")), (1, 2))
    check(group, "changedTasks 时长 = [45, 15]",
          [t.get("durationMinutes") for t in (diff or {}).get("changedTasks", [])], [45, 15])

    status, plan2 = call(base, "GET", "/api/v1/plans/current")
    check(group, "plan version 提交后 = 2", (plan2 or {}).get("version"), 2)
    check(group, "V2 时长 = [45, 15]",
          [t.get("durationMinutes") for t in (plan2 or {}).get("tasks", [])], [45, 15])


# --------------------------------------------------------------------------- ③ 回归护栏
def run_regression_guards(base: str) -> None:
    group = "regression-guards"
    print("\n" + "=" * 100)
    print("③ 回归护栏：旧缺陷不得复现  @ %s" % base)
    print("=" * 100)

    # --- 护栏 1：判分必须随答案变化（旧 B1 恒 67）---
    call(base, "POST", "/api/v1/demo/reset", {})
    _, correct = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                      {"idempotencyKey": "guard-correct", "answers": ALL_CORRECT})
    score_correct = (correct or {}).get("assessment", {}).get("score")

    call(base, "POST", "/api/v1/demo/reset", {})
    _, wrong = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                    {"idempotencyKey": "guard-wrong", "answers": ALL_WRONG})
    score_wrong = (wrong or {}).get("assessment", {}).get("score")

    check(group, "全对 score = 100.0（不再恒定 67）", score_correct, 100.0)
    check(group, "全错 score = 0.0（不再恒定 67）", score_wrong, 0.0)
    check(group, "分数确实随答案变化", score_correct != score_wrong, True)

    # --- 护栏 2：全错不涨掌握度 ---
    call(base, "POST", "/api/v1/demo/reset", {})
    call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
         {"idempotencyKey": "guard-mastery-1", "answers": ALL_WRONG})
    _, profile = call(base, "GET", "/api/v1/profile/demo-user")
    mastery_after_wrong = ((profile or {}).get("mastery") or [{}])[0].get("masteryScore")
    check(group, "全错后掌握度不上升（含下调）", mastery_after_wrong <= 42, True)
    note(group, "全错提交后 mastery（初始 42）", mastery_after_wrong)

    # --- 护栏 3：重复提交 3 次，任务时长不得漂移 ---
    call(base, "POST", "/api/v1/demo/reset", {})
    durations: list[list[int]] = []
    for index in range(3):
        call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
             {"idempotencyKey": "guard-idem-%d" % index, "answers": DEMO_ANSWERS})
        _, current = call(base, "GET", "/api/v1/plans/current")
        durations.append([t.get("durationMinutes") for t in (current or {}).get("tasks", [])])
    note(group, "连续 3 次提交后的时长序列", durations)
    check(group, "任务时长不漂移到 0（每次均 >= 15 分钟）",
          all(all(d >= 15 for d in row) for row in durations), True)
    check(group, "第 2、3 次结果稳定一致（幂等锚定基线）", durations[1] == durations[2], True)

    # --- 护栏 4：同一 idempotencyKey 重复提交响应一致 ---
    call(base, "POST", "/api/v1/demo/reset", {})
    first = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                 {"idempotencyKey": "guard-replay", "answers": DEMO_ANSWERS})[1]
    second = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                  {"idempotencyKey": "guard-replay", "answers": DEMO_ANSWERS})[1]
    check(group, "同 key 重放响应逐字节一致", first == second, True)


# --------------------------------------------------------------------------- ④ Agent / 聊天
def run_agent_and_chat(base: str) -> None:
    group = "agent-loop-and-chat"
    print("\n" + "=" * 100)
    print("④ 真 Agent 循环 + trace + 聊天层 + proactive  @ %s" % base)
    print("=" * 100)

    status, workflow = call(base, "POST", "/api/v1/workflows",
                            {"goal": "数据结构考试80+", "userId": "demo-user", "maxSteps": 6})
    check(group, "POST /api/v1/workflows -> 2xx", status in (200, 201), True)
    session_id = (workflow or {}).get("sessionId")
    trace_id = (workflow or {}).get("traceId")

    status, _ = call(base, "POST", "/api/v1/workflows/%s/run" % session_id, {})
    check(group, "第一次 /run -> 200", status, 200)
    status, run2 = call(base, "POST", "/api/v1/workflows/%s/run" % session_id,
                        {"answers": DEMO_ANSWERS})
    check(group, "第二次 /run 后 status = completed", (run2 or {}).get("status"), "completed")

    status, trace = call(base, "GET", "/api/v1/traces/%s" % trace_id)
    events = (trace or {}).get("events", [])
    agents = sorted({e.get("agent") for e in events})
    tools = sorted({t for e in events for t in e.get("toolCalls", [])})
    note(group, "trace 事件数 / agent / tool", (len(events), agents, tools))
    check(group, "单次 workflow 覆盖 >= 2 个 agent", len(agents) >= 2, True)
    check(group, "单次 workflow 覆盖 >= 3 个 tool", len(tools) >= 3, True)
    check(group, "trace 不含模型思维链字段",
          any(k in json.dumps(events, ensure_ascii=False)
              for k in ('"chainOfThought"', '"reasoning"', '"thoughts"')), False)

    # 确定性：无 LLM 时两次运行 agent 序列必须一致
    sequences = []
    for _ in range(2):
        _, flow = call(base, "POST", "/api/v1/workflows",
                       {"goal": "数据结构考试80+", "userId": "demo-user", "maxSteps": 6})
        call(base, "POST", "/api/v1/workflows/%s/run" % flow["sessionId"], {})
        call(base, "POST", "/api/v1/workflows/%s/run" % flow["sessionId"],
             {"answers": DEMO_ANSWERS})
        _, one = call(base, "GET", "/api/v1/traces/%s" % flow["traceId"])
        sequences.append([e.get("agent") for e in one.get("events", [])])
    check(group, "无 LLM 下两次运行 agent 序列一致", sequences[0] == sequences[1], True)

    # 聊天层：意图 + 卡片结构
    status, chat = call(base, "POST", "/api/agent/chat",
                        {"message": "我想查查错题", "user_data": {}})
    check(group, "POST /api/agent/chat -> 200", status, 200)
    check(group, "聊天响应字段 = {reply, intent, card}",
          sorted((chat or {}).keys()), ["card", "intent", "reply"])
    check(group, "意图识别 analyze_wrong", (chat or {}).get("intent"), "analyze_wrong")
    card = (chat or {}).get("card") or {}
    check(group, "卡片含前端可跳转的 targetPage",
          isinstance(card.get("targetPage"), str)
          and card.get("targetPage", "").startswith("pages/"), True)

    status, chat2 = call(base, "POST", "/api/agent/chat", {"message": "今天我应该先学什么？"})
    check(group, "第二类意图 get_suggestion", (chat2 or {}).get("intent"), "get_suggestion")
    check(group, "回复非空", len(str((chat2 or {}).get("reply", ""))) > 10, True)

    # 中文字节必须在两种 Content-Type 下都不丢失（charset=utf-8 是 PowerShell 客户端的行为）
    status, chat3 = call(base, "POST", "/api/agent/chat", {"message": "帮我分析错题"},
                         charset=True)
    check(group, "带 charset=utf-8 时中文意图不丢失", (chat3 or {}).get("intent"), "analyze_wrong")

    # proactive 主动服务决策
    status, proactive = call(base, "POST", "/api/v1/agent/proactive", {
        "userId": "demo-user",
        "context": {"now": "2026-09-16T21:10:00+08:00", "location": "library",
                    "foreground": False, "lastStudyAt": "2026-09-14T20:30:00+08:00",
                    "focusSessionActive": False, "masteryScore": 58, "errorIntensity": 67,
                    "daysLeft": 5, "importance": 90}})
    check(group, "POST /api/v1/agent/proactive -> 200", status, 200)
    check(group, "shouldNotify = true", (proactive or {}).get("shouldNotify"), True)
    check(group, "含可解释的 factors 明细", len((proactive or {}).get("factors", [])), 5)
    check(group, "含 reason 文案", isinstance((proactive or {}).get("reason"), str), True)

    # 契约错误结构
    status, error = call(base, "GET", "/api/v1/workflows/does-not-exist")
    check(group, "未知工作流 -> 404", status, 404)
    check(group, "错误体使用 v0.3 errorCode 结构",
          isinstance((error or {}).get("errorCode"), str), True)

    # 实验数据导出
    status, snapshot = call(base, "GET", "/api/v1/experiments/snapshot")
    check(group, "GET /api/v1/experiments/snapshot -> 200", status, 200)
    note(group, "snapshot keys", sorted((snapshot or {}).keys()))


# --------------------------------------------------------------------------- ⑤ 登录与鉴权
def run_auth_chain(base: str) -> None:
    """登录功能验收 + **演示基线护栏**（本次新增功能最大的风险点）。"""
    group = "auth-and-baseline-guard"
    print("\n" + "=" * 100)
    print("⑤ 登录 / 鉴权 + 演示基线护栏（新增登录功能不得改变任何演示数值）  @ %s" % base)
    print("=" * 100)

    # --- 1. 注册 → 下发 userId 与 token，且响应不含内部字段 ---
    stamp = int(time.time())
    status, registered = call(base, "POST", "/api/v1/auth/register",
                              {"nickname": f"验收账号{stamp % 10000}", "grade": "大二"})
    check(group, "POST /api/v1/auth/register -> 201", status, 201)
    user = (registered or {}).get("user", {})
    token = (registered or {}).get("token", "")
    user_id = user.get("userId", "")
    check(group, "下发 userId（u- 前缀）", isinstance(user_id, str) and user_id.startswith("u-"), True)
    check(group, "下发 token", isinstance(token, str) and len(token) > 20, True)
    check(group, "用户视图不含 token", "token" not in user, True)
    check(group, "用户视图不含 authSubject", "authSubject" not in user, True)

    auth_header = {"Authorization": f"Bearer {token}"}

    # --- 2. 新账号可用：画像与计划立即可读 ---
    status, new_profile = call(base, "GET", f"/api/v1/profile/{user_id}")
    check(group, "新账号画像可读（预置空画像）", status, 200)
    check(group, "新账号初始掌握度 = 0",
          ((new_profile or {}).get("mastery") or [{}])[0].get("masteryScore"), 0)

    # --- 3. 新账号走完真实闭环：练习 → 判分 → 掌握度提升 ---
    status, new_submit = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                              {"idempotencyKey": f"auth-verify-{stamp}", "userId": user_id,
                               "answers": DEMO_ANSWERS}, headers=auth_header)
    check(group, "新账号提交 -> 200", status, 200)
    new_assessment = (new_submit or {}).get("assessment", {})
    check(group, "新账号判分同样为 66.67", new_assessment.get("score"), 66.67)
    check(group, "新账号掌握度 0 -> 16（判分规则对真实账号同样生效）",
          new_assessment.get("suggestedNewMastery"), 16)

    # --- 4. 鉴权边界 ---
    status, _ = call(base, "GET", "/api/v1/auth/me")
    check(group, "GET /api/v1/auth/me 无 token -> 401", status, 401)
    status, me = call(base, "GET", "/api/v1/auth/me", headers=auth_header)
    check(group, "GET /api/v1/auth/me 带 token -> 200", status, 200)
    check(group, "me 返回同一 userId", ((me or {}).get("user") or {}).get("userId"), user_id)

    status, _ = call(base, "POST", "/api/v1/auth/login",
                     {"userId": user_id, "token": "wrong-token"})
    check(group, "token 不匹配 -> 401", status, 401)

    # --- 5. ★ 演示基线护栏：登录功能绝不能改变演示数值 ---
    status, reset = call(base, "POST", "/api/v1/demo/reset", {})
    check(group, "游客态 demo/reset -> 200", status, 200)
    check(group, "demo/reset 的 userId 仍是 demo-user", (reset or {}).get("userId"), "demo-user")
    check(group, "演示基线掌握度仍为 42",
          ((reset or {}).get("profile") or {}).get("mastery", [{}])[0].get("masteryScore"), 42)
    check(group, "演示基线 Plan V1 时长仍为 [30, 30]",
          [t.get("durationMinutes") for t in ((reset or {}).get("plan") or {}).get("tasks", [])],
          [30, 30])

    status, demo_submit = call(base, "POST", "/api/v1/exercises/set-demo-binary-tree-001/submit",
                               {"idempotencyKey": f"auth-guard-{stamp}", "answers": DEMO_ANSWERS})
    check(group, "游客演示提交仍为 66.67",
          (demo_submit or {}).get("assessment", {}).get("score"), 66.67)
    check(group, "游客演示掌握度仍为 42 -> 58",
          (demo_submit or {}).get("assessment", {}).get("suggestedNewMastery"), 58)

    status, demo_plan = call(base, "GET", "/api/v1/plans/current")
    check(group, "游客演示 Plan V2 仍为 [45, 15]",
          [t.get("durationMinutes") for t in (demo_plan or {}).get("tasks", [])], [45, 15])

    # 带 token 访问 demo-user 的接口，结果必须与游客一致
    status, with_token = call(base, "GET", "/api/v1/profile/demo-user", headers=auth_header)
    status2, without = call(base, "GET", "/api/v1/profile/demo-user")
    check(group, "带上登录 token 后 demo-user 画像不变", with_token == without, True)

    # --- 6. 无效 token 降级为游客，而不是把 App 打挂 ---
    status, degraded = call(base, "GET", "/api/v1/profile/demo-user",
                            headers={"Authorization": "Bearer expired-or-garbage"})
    check(group, "无效 token 降级为游客（不 401）", status, 200)

    # --- 7. 退出登录：吊销后不能再登录 ---
    status, _ = call(base, "POST", "/api/v1/auth/logout", headers=auth_header)
    check(group, "POST /api/v1/auth/logout -> 200", status, 200)
    status, _ = call(base, "GET", "/api/v1/auth/me", headers=auth_header)
    check(group, "退出后 me -> 401", status, 401)
    status, _ = call(base, "POST", "/api/v1/auth/login", {"userId": user_id, "token": token})
    check(group, "退出后不能用旧 token 重新登录 -> 401", status, 401)

    # --- 8. 注销账号（合规）：停用 + 失效 ---
    status, second = call(base, "POST", "/api/v1/auth/register", {"nickname": "待注销账号"})
    second_token = (second or {}).get("token", "")
    status, deleted = call(base, "DELETE", "/api/v1/auth/account",
                           headers={"Authorization": f"Bearer {second_token}"})
    check(group, "DELETE /api/v1/auth/account -> 200", status, 200)
    check(group, "注销返回 deactivated", (deleted or {}).get("status"), "deactivated")
    status, _ = call(base, "GET", "/api/v1/auth/me",
                     headers={"Authorization": f"Bearer {second_token}"})
    check(group, "注销后 me -> 401", status, 401)

    # --- 9. 注册校验 ---
    status, _ = call(base, "POST", "/api/v1/auth/register", {"nickname": "   "})
    check(group, "空昵称 -> 400", status, 400)
    status, _ = call(base, "POST", "/api/v1/auth/register",
                     {"nickname": "合法昵称", "grade": "不存在的年级"})
    check(group, "非法年级 -> 400", status, 400)


def wait_for_server(base: str, timeout: float = 20.0) -> bool:
    """轮询后端健康检查，就绪返回 True。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/health", timeout=2) as response:
                if response.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            time.sleep(0.4)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:5000")
    parser.add_argument("--skip-pytest", action="store_true")
    parser.add_argument("--out", default=str(ROOT / "evidence" / "verify_result.json"))
    parser.add_argument("--start-server", action="store_true",
                        help="自行启动后端（用 sys.executable）并在结束后关闭")
    args = parser.parse_args()

    process = None
    if args.start_server:
        process = subprocess.Popen([sys.executable, "run.py"], cwd=str(SERVER_DIR))
        if not wait_for_server(args.base):
            print("后端未能在 20 秒内就绪（%s）" % args.base)
            process.terminate()
            return 1
        print("后端已就绪：%s" % args.base)

    try:
        ok = True
        run_static_consistency()
        if not args.skip_pytest:
            ok = run_pytest() and ok
        run_contract_chain(args.base)
        run_regression_guards(args.base)
        run_agent_and_chat(args.base)
        run_auth_chain(args.base)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()

    total = len(RESULTS)
    passed = sum(1 for r in RESULTS if r["ok"])
    print("\n" + "=" * 100)
    print("SUMMARY: %d/%d checks passed" % (passed, total))
    for row in RESULTS:
        if not row["ok"]:
            print("  FAILED [%s] %s -> actual=%s expected=%s"
                  % (row["group"], row["check"], row["actual"], row["expected"]))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2), encoding="utf-8")
    print("raw -> %s" % out_path)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
