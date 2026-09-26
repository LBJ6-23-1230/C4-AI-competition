"""账户登录全链路实测（可复跑闸门）。

用法：
    python tools/check_auth_chain.py                  # 默认 http://127.0.0.1:5000
    python tools/check_auth_chain.py --port 5500      # 指定端口（例如 SQLite 后端）
    python tools/check_auth_chain.py --base http://ip:5000

覆盖 21 项：
    注册 / 重号 409 / 缺手机号 400 / 发码 / 正确与错误验证码 /
    token 鉴权（有效、缺失、伪造）/ **跨账号数据隔离**（列表不可见、按 id 直取被拒）/
    昵称免密登录 / 注销后 token 立即失效

为什么单列一个工具
------------------
2026-09-23 前端同学报「游客能进知识库、登录自己账号就报契约不一致」。
后端账户链本身是好的，问题出在 URL 带 `?userId=` 时前端校验器走了错分支。
当时为了定位写了这个探针 —— 它能一次性排除"后端账户链"的嫌疑，
所以固化成工具，下次有人报类似问题先跑它。

退出码：0 全通过；1 有失败项。
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_parser = argparse.ArgumentParser(description="账户登录全链路实测")
_parser.add_argument("--port", type=int, default=5000)
_parser.add_argument("--base", default="")
_args = _parser.parse_args()
BASE = _args.base or ("http://127.0.0.1:%d" % _args.port)



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
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw or "{}")
        except Exception:
            return e.code, {"_raw": raw[:200]}
    except Exception as e:
        return None, {"_err": str(e)}


def phone():
    return "139" + "".join(random.choice("0123456789") for _ in range(8))


def nick(base):
    """生成不会重名的昵称。

    ⚠️ 为什么必须随机：后端把「一个昵称对应多个账号」视为 409
    （提示改用更精确的昵称）—— 这是**正确行为**。
    但探针若用固定昵称，第二次运行就会因重名而 409 失败。
    工具必须可反复运行，所以昵称跟着随机后缀走。
    """
    return base + "".join(random.choice("0123456789") for _ in range(4))


results = []


def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print("  %s %-46s %s" % ("PASS" if ok else "FAIL", label, detail))


print("=" * 90)
print("一、注册")
print("=" * 90)
p1 = phone()
# 昵称必须随机：后端把「一个昵称对应多个账号」视为 409（提示改用更精确的昵称），
# 这是**正确行为**；但探针用固定昵称时第二次运行就会 409 —— 工具必须可反复跑。
# 注册时**必须设密码**：`_verify_password()` 现在会拒绝用密码登录"从未设过密码"
# 的账号（此前遇到空 passwordHash 直接放行，等于**任意密码都能登进去**，
# 已按界面路径实测复现）。下面第六节的"昵称登录"随之要带上这个密码。
PWD = "probe-pw-123456"
st, r = call("POST", "/api/v1/auth/register",
             {"nickname": nick("小测甲"), "phone": p1, "grade": "大二", "password": PWD})
check("注册成功返回 201", st == 201, "HTTP %s" % st)
tok1 = r.get("token")
u1 = (r.get("user") or {}).get("userId")
nick1 = (r.get("user") or {}).get("nickname")
check("返回 token", bool(tok1), "token=%s..." % (tok1 or "")[:12])
check("返回 userId", bool(u1), "userId=%s" % u1)
check("hasPhone=true", (r.get("user") or {}).get("hasPhone") is True)

print()
print("二、重复手机号 / 缺字段")
st, r = call("POST", "/api/v1/auth/register", {"nickname": nick("小测乙"), "phone": p1})
check("同号重复注册返回 409", st == 409, "HTTP %s %s" % (st, r.get("errorCode")))
st, r = call("POST", "/api/v1/auth/register", {"nickname": nick("小测丙")})
check("缺手机号返回 400", st == 400, "HTTP %s %s" % (st, r.get("message")))

print()
print("三、手机验证码登录")
st, r = call("POST", "/api/v1/auth/send-code", {"phone": p1})
code = r.get("devCode")
check("发码 200 且返回 devCode", st == 200 and bool(code),
      "HTTP %s devCode=%s smsDelivered=%s" % (st, code, r.get("smsDelivered")))
st, r = call("POST", "/api/v1/auth/verify-code", {"phone": p1, "code": code})
check("正确验证码通过", st in (200, 201), "HTTP %s" % st)
tok2 = r.get("token")
check("验证码登录也返回 token", bool(tok2))
st, r = call("POST", "/api/v1/auth/verify-code", {"phone": p1, "code": "000000"})
check("错误验证码被拒", st == 400, "HTTP %s %s" % (st, r.get("errorCode")))

print()
print("四、带 token 访问")
st, r = call("GET", "/api/v1/auth/me", token=tok1)
check("GET /auth/me 用 token 成功", st == 200, "HTTP %s" % st)
me_id = (r.get("user") or r).get("userId") if isinstance(r, dict) else None
check("me 返回的就是本人", me_id == u1, "me=%s 期望=%s" % (me_id, u1))
st, r = call("GET", "/api/v1/auth/me")
check("不带 token 返回 401", st == 401, "HTTP %s" % st)
st, r = call("GET", "/api/v1/auth/me", token="bogus-token")
check("伪造 token 返回 401", st == 401, "HTTP %s" % st)

print()
print("五、跨账号数据隔离（关键）")
st, r = call("POST", "/api/v1/knowledge-bases",
             {"courseName": "甲的数据结构", "name": "甲的库"}, token=tok1)
kb_owner = r.get("kbId") if st in (200, 201) else None
check("甲建知识库成功", bool(kb_owner), "HTTP %s kbId=%s" % (st, kb_owner))

p3 = phone()
st, r = call("POST", "/api/v1/auth/register", {"nickname": nick("小测丁"), "phone": p3})
tok3 = r.get("token")
u3 = (r.get("user") or {}).get("userId")

# 乙（新账号）列出自己的知识库，不应看到甲的
st, r = call("GET", "/api/v1/knowledge-bases?userId=%s" % u3, token=tok3)
names = [k.get("name") for k in (r.get("knowledgeBases") or [])]
check("乙看不到甲的知识库", "甲的库" not in names, "乙看到: %s" % names)

# 乙直接按 id 访问甲的库
st, r = call("GET", "/api/v1/knowledge-bases/%s" % kb_owner, token=tok3)
check("乙按 id 直接访问甲的库被拒", st in (403, 404), "HTTP %s" % st)

# 甲的列表里应有自己的库
st, r = call("GET", "/api/v1/knowledge-bases?userId=%s" % u1, token=tok1)
names1 = [k.get("name") for k in (r.get("knowledgeBases") or [])]
check("甲能看到自己的知识库", "甲的库" in names1, "甲看到: %s" % names1)

print()
print("六、昵称登录")
# 标题从"昵称**免密**登录"改掉了：账号设过密码后必须校验密码（见上方注册处的说明）。
st, r = call("POST", "/api/v1/auth/login", {"nickname": nick1, "password": PWD})
check("昵称+密码登录可用（用刚注册的昵称）", st in (200, 201), "HTTP %s" % st)
st, r = call("POST", "/api/v1/auth/login", {"nickname": nick1, "password": "wrong-pw-000"})
check("昵称+错误密码被拒（401）", st == 401, "HTTP %s %s" % (st, r.get("errorCode")))
st, r = call("POST", "/api/v1/auth/login", {"nickname": nick("绝不存在的昵称")})
check("未注册昵称返回 404", st == 404, "HTTP %s %s" % (st, r.get("errorCode")))

print()
print("七、注销")
st, r = call("DELETE", "/api/v1/auth/account", token=tok3)
check("注销返回 200", st == 200, "HTTP %s %s" % (st, r.get("status")))
st, r = call("GET", "/api/v1/auth/me", token=tok3)
check("注销后 token 失效", st == 401, "HTTP %s" % st)

print()
print("=" * 90)
fail = [x for x in results if not x[1]]
print("总计 %d 项，通过 %d，失败 %d" % (len(results), len(results) - len(fail), len(fail)))
for label, _, detail in fail:
    print("  FAIL %s  %s" % (label, detail))
if not fail:
    print("全部通过 ✅")

raise SystemExit(1 if fail else 0)
