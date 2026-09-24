# -*- coding: utf-8 -*-
"""闸门：身份隔离（游客 vs 账号）。

背景
----
前端同学实测报「**游客能进、账号登录就出问题，很多功能用不了**」。
最初的根因是 `ApiResponseValidator` 对路径做精确比较、带 `?userId=` 后分支失配
（已修，由 `check_validator_query_string.py` 守着）。

复查时又发现三处**同类型、但校验器管不到**的游客/账号不一致：

1. `ClientCache` 是身份盲区，且登录时不清空 —— 游客逛一圈再登录账号，
   账号读到的是游客缓存的画像 / 计划 / 工作流 / trace，而 `isCached`
   只写不渲染，**界面上没有任何提示**。
2. `AgentBridge` 打 `/api/agent/chat` 不带 `Authorization`、body 里也没有
   `userId`，后端按「已登录身份 > 显式 userId > 演示身份」解析，于是
   账号的对话被当成 demo-user 处理并落盘。
3. 离线 Fixture 没有知识库路由，`KnowledgeBase` 页也没有 `useFixture` 守卫。

本闸门把这三条不变量固化下来：只要以后有人把身份绑定拆掉，它必须变红。
**它检查的是"接线是否存在"，不替代端到端实测**（后者见
`check_logged_in_flows.py` 与 `integration/run_liantiao5.py`）。

用法::

    python tools/check_identity_isolation.py            # 有缺口则退出码 1
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "app" / "entry" / "src" / "main" / "ets"

CLIENT_CACHE = ETS / "cache" / "ClientCache.ets"
WORKFLOW_STORE = ETS / "cache" / "WorkflowSessionStore.ets"
APP_STATE = ETS / "data" / "AppState.ets"
AGENT_BRIDGE = ETS / "services" / "AgentBridge.ets"
FIXTURE = ETS / "api" / "FixtureApiTransport.ets"
KB_PAGE = ETS / "pages" / "KnowledgeBase.ets"
AUTH_CLIENT = ETS / "api" / "AuthClient.ets"
ACCOUNT_PAGE = ETS / "pages" / "Account.ets"
INDEX_PAGE = ETS / "pages" / "Index.ets"

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(("  PASS " if ok else "  FAIL ") + label + (("   " + detail) if detail else ""))
    if not ok:
        failures.append(label)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def strip_comments(source: str) -> str:
    """去掉块注释与行注释。

    ⚠️ 必须做。**受控实验发现的坑**：不加这一步时，把
    `ClientCache.bindIdentity(user.userId);` 整行注释掉，它仍然包含
    `ClientCache.bindIdentity(` 这个子串 —— 闸门照样报 PASS，等于没牙。
    注释掉的代码不是代码。
    """
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)


def method_body(source: str, name: str) -> str | None:
    """取 `name(` 起、花括号配平的那段函数体。

    不用正则抠"到某个缩进的 `}` 为止" —— 本工程里 `AppState.ets` 用空格缩进，
    而 `server/**` 用 TAB，写死缩进会让闸门自己误报。
    """
    # 返回类型不写死 `void`：`AuthClient` 的方法返回 `Promise<AuthResult>`，
    # 参数还可能跨行，用 `[^)]*` / `[^{]*`（两者都匹配换行）。
    match = re.search(r"\b" + re.escape(name) + r"\s*\([^)]*\)\s*:\s*[^{]*\{", source)
    if match is None:
        return None
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return None


def main() -> int:
    print("=" * 84)
    print("  闸门：身份隔离（游客 vs 账号）")
    print("=" * 84)
    print("  工程根: %s" % ROOT)
    print()

    missing = [str(p.relative_to(ROOT)) for p in
               (CLIENT_CACHE, WORKFLOW_STORE, APP_STATE, AGENT_BRIDGE, FIXTURE, KB_PAGE,
                AUTH_CLIENT, ACCOUNT_PAGE, INDEX_PAGE)
               if not p.exists()]
    if missing:
        print("  !! 找不到必需文件: %s" % ", ".join(missing))
        return 2

    # 一律先剥注释：被注释掉的调用不算"接线存在"（见 strip_comments 的说明）。
    cache = strip_comments(read(CLIENT_CACHE))
    store = strip_comments(read(WORKFLOW_STORE))
    state = strip_comments(read(APP_STATE))
    bridge = strip_comments(read(AGENT_BRIDGE))
    fixture = strip_comments(read(FIXTURE))
    kb_page = strip_comments(read(KB_PAGE))
    auth = strip_comments(read(AUTH_CLIENT))
    account_src = strip_comments(read(ACCOUNT_PAGE))
    index_src = strip_comments(read(INDEX_PAGE))

    # ---------------------------------------------------------------- ① 缓存
    print("① ClientCache 必须按身份归属，且登录/登出都要重新绑定")
    check("ClientCache 暴露 bindIdentity()",
          re.search(r"static\s+bindIdentity\s*\(", cache) is not None)
    check("ClientCache 记录 ownerUserId",
          "ownerUserId" in cache)
    check("身份变化时整体失效（调用 clearDemoData）",
          re.search(r"bindIdentity[\s\S]{0,400}clearDemoData\s*\(", cache) is not None)

    # AppState 是唯一的身份入口：两处都绑定才算接上
    login_body = method_body(state, "applyLogin")
    logout_body = method_body(state, "applyLogout")
    check("applyLogin 调用了 ClientCache.bindIdentity()",
          login_body is not None and "ClientCache.bindIdentity(" in login_body,
          "" if login_body else "没找到 applyLogin 函数体")
    check("applyLogout 调用了 ClientCache.bindIdentity()",
          logout_body is not None and "ClientCache.bindIdentity(" in logout_body,
          "" if logout_body else "没找到 applyLogout 函数体")
    check("applyLogin 在身份变化时清账号维度状态（resetAccountScopedState）",
          login_body is not None and "resetAccountScopedState(" in login_body,
          "原实现只有 applyLogout 调，applyLogin 没调 → 游客聊天记录串进账号")

    print()
    print("② 启动恢复的工作流必须认身份（不能把上一个游客的会话认成账号的）")
    check("WorkflowSessionStore 持久化归属身份（KEY_USER_ID）",
          "KEY_USER_ID" in store)
    check("save() 签名带 userId",
          re.search(r"static\s+save\s*\([^)]*userId\s*:\s*string\s*\)", store) is not None)
    check("restore() 走 stageRestoredWorkflow（不直接写缓存）",
          "stageRestoredWorkflow(" in store)
    check("回传的 userId 为空的历史数据不恢复",
          re.search(r"userId\.length\s*===\s*0", store) is not None)

    print()
    print("③ 聊天层必须带账号凭据（否则账号对话被当成 demo-user 落盘）")
    check("AgentBridge 引入了 AuthStore",
          "AuthStore" in bridge)
    check("AgentBridge 设置了 Authorization 头",
          re.search(r"header\['Authorization'\]\s*=", bridge) is not None)
    check("buildRequestBody 带上 userId",
          re.search(r"'\"userId\":'\s*\+", bridge) is not None)

    print()
    print("④ 离线 Fixture 必须能进知识库（否则离线演示该页对谁都打不开）")
    for route in ("'/api/v1/knowledge-bases'", "/api/v1/knowledge-bases/",
                  "/api/v1/documents/", "/search", "/documents"):
        check("fixture 覆盖 %s" % route, route in fixture)
    check("fixture 路径匹配先剥离查询串（basePath）",
          "basePath(" in fixture)

    print()
    print("⑤ 页面不得写死演示身份字面量")
    hardcoded = [ln for ln in kb_page.splitlines()
                 if "'demo-user'" in ln and "ApiDefaults" not in ln]
    check("KnowledgeBase 页无硬编码 'demo-user'",
          not hardcoded, ("发现: " + hardcoded[0].strip()) if hardcoded else "走 ApiDefaults.DEMO_USER_ID")

    print()
    print("⑥ 离线模式下登录页必须优雅降级（不能漏内部错误给用户）")
    # 缺陷背景：`FixtureApiTransport` 没有任何 auth 路由，而登录页每个入口都会
    # 直连传输层 → 界面上原样显示「未找到 fixture 路由：POST /api/v1/auth/login-or-register」。
    check("AuthClient 定义了 offlineUnavailable() 拦截器",
          re.search(r"\bofflineUnavailable\s*\(", auth) is not None)
    # 这 7 个在离线时"做不了就是做不了"，统一走 offlineUnavailable()：
    # 如实说明 + 给出路（切回联机 / 跳过登录）。
    for name in ("register", "loginOrRegister", "loginByPhone", "sendVerificationCode",
                 "verifyCode", "loginWithHuaweiAccount", "loginByNickname"):
        body = method_body(auth, name)
        guarded = body is not None and "offlineUnavailable(" in body
        check("%s 走统一的离线拦截" % name, guarded,
              "" if body else "没找到方法体（方法被改名？）")
    # deleteAccount 的离线语义**故意不同**：它要清掉本机登录态（与"本地无论成功
    # 与否都清空"的纪律一致），但必须如实说明服务器账号**没被**停用。
    # 所以它不调 offlineUnavailable()，而是自己写一个 useFixture 分支 —— 这里单独查。
    delete_body = method_body(auth, "deleteAccount")
    check("deleteAccount 有独立的离线分支（清本地 + 如实说明）",
          delete_body is not None
          and "useFixture" in delete_body
          and "AuthStore.clear()" in delete_body
          and "fixture" in delete_body,
          "" if delete_body else "没找到方法体（方法被改名？）")
    # restore() 走显式分支，不靠"fixture 失败恰好不是 401"这个巧合
    restore_body = method_body(auth, "restore")
    check("restore() 有显式 fixture 分支",
          restore_body is not None and "useFixture" in restore_body)

    print()
    print("⑦ 两条「返回登录页」路径行为必须一致（都要关掉 Fixture）")
    for label, src in (("Index.goToLogin", index_src), ("Account.goToLogin", account_src)):
        body = method_body(src, "goToLogin")
        check("%s 重置 useFixture" % label,
              body is not None and "setUseFixture(false)" in body,
              "" if body else "没找到 goToLogin（方法被改名？）")

    print()
    print("=" * 84)
    if failures:
        print("结论：FAIL（%d 项不满足）" % len(failures))
        for item in failures:
            print("  - %s" % item)
        return 1
    print("结论：PASS —— 身份绑定接线完整（端到端实测另见 check_logged_in_flows.py）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
