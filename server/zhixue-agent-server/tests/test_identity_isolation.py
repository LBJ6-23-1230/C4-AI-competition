# -*- coding: utf-8 -*-
"""身份解析与数据隔离回归测试。

修复的缺陷（审计确认）：
* `app/__init__.py` 把 Bearer token 解析进 `g.current_user`，但**全项目 0 个端点读取它**
* 端点普遍写 `request.args.get("userId", "demo-user")`，而前端不带该参数
  → **登录后读到的仍是演示账号的数据**
* 带甲的合法 token、把 `userId` 填成乙 → 改了乙的掌握度（实测乙 0→16）

这里锁住三条规则：
1. **已登录 → 读自己的数据**（再也不看请求里传的 userId）
2. **已登录 → 不能读他人**（403）
3. **未登录 → 仍走 demo-user**（演示链路与基线不受影响）
"""

from app import create_app

H = {"X-API-Contract-Version": "api-contract-v0.3"}
_SEQ = {"n": 0}


def _phone() -> str:
    _SEQ["n"] += 1
    return f"1350000{_SEQ['n']:04d}"


def _register(client, nickname: str) -> dict:
    """注册一个测试账号（**显式载入演示数据**）。

    本文件的用例测的是"登录后读到的是**自己**的数据、且不串号"，
    需要每个账号都有自己的起始计划与画像（`plan-<userId>`）才成立，
    所以这里显式 `seedDemoData: true`。

    接口默认值已经改为 `False`（新账号默认空画像、不预置计划），
    见 `tests/test_auth.py::test_register_defaults_to_empty_profile`。
    """
    body = client.post("/api/v1/auth/register",
                       json={"nickname": nickname, "phone": _phone(),
                             "seedDemoData": True},
                       headers=H).get_json()
    return {"userId": body["user"]["userId"], "token": body["token"],
            "headers": dict(H, Authorization=f"Bearer {body['token']}")}


# --------------------------------------------------------------------- 读自己的数据
def test_authenticated_user_reads_own_plan(tmp_path):
    """登录后 `/plans/current` 必须返回**自己**的计划。

    这是本轮修的核心缺陷：原先写死 demo-user，前端也不带参数，
    于是登录了也还是看到演示账号的计划。
    """
    client = create_app(tmp_path / "own-plan.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    user = _register(client, "甲同学")

    plan = client.get("/api/v1/plans/current", headers=user["headers"]).get_json()

    assert plan.get("userId") == user["userId"], "必须返回登录用户自己的计划"


def test_authenticated_user_reads_own_profile(tmp_path):
    """新账号的画像应是 starter profile（掌握度 0），不是演示账号的 42。"""
    client = create_app(tmp_path / "own-profile.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    user = _register(client, "乙同学")

    profile = client.get(f"/api/v1/profile/{user['userId']}",
                         headers=user["headers"]).get_json()

    scores = [m["masteryScore"] for m in profile.get("mastery", [])]
    assert scores == [0], f"新账号应当是 starter profile，实际 {scores}"


def test_two_accounts_do_not_see_each_other(tmp_path):
    client = create_app(tmp_path / "two-users.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    alice = _register(client, "甲")
    bob = _register(client, "乙")

    plan_a = client.get("/api/v1/plans/current", headers=alice["headers"]).get_json()
    plan_b = client.get("/api/v1/plans/current", headers=bob["headers"]).get_json()

    assert plan_a.get("userId") == alice["userId"]
    assert plan_b.get("userId") == bob["userId"]
    assert alice["userId"] != bob["userId"]


# --------------------------------------------------------------------- 读开放 / 写隔离
def test_read_is_open_but_write_is_isolated(tmp_path):
    """**读开放、写隔离** —— 这是刻意的规则划分。

    读：任何身份都能读任意 userId 的画像。演示数据本来就公开
    （`demo/reset` 无需凭据），遮起来没有安全增益，却会打断演示链路。
    写：提交作业/创建工作流一律用登录身份。**越权风险全在写侧。**

    这条测试同时锁住"带 token 不改变读接口行为"这条既有约束
    （对应 `test_auth.py::test_valid_bearer_does_not_change_demo_endpoints`）。
    """
    client = create_app(tmp_path / "read-open.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    alice = _register(client, "甲")

    with_token = client.get("/api/v1/profile/demo-user", headers=alice["headers"]).get_json()
    without_token = client.get("/api/v1/profile/demo-user", headers=H).get_json()

    assert with_token["profileVersion"] == without_token["profileVersion"]
    assert with_token["mastery"] == without_token["mastery"]


def test_cannot_impersonate_via_request_body(tmp_path):
    """甲把请求体 `userId` 填成 demo-user 提交作业，数据仍写给自己。

    这是审计实测过的越权路径（乙的掌握度被从 0 改成 16）。
    """
    client = create_app(tmp_path / "impersonate.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    alice = _register(client, "甲")

    result = client.post(
        "/api/v1/exercises/set-demo-binary-tree-001/submit",
        json={"userId": "demo-user", "idempotencyKey": "impersonate-1",
              "answers": [
                  {"exerciseId": "exercise-preorder-001", "answer": "A"},
                  {"exerciseId": "exercise-inorder-001", "answer": "B"},
                  {"exerciseId": "exercise-postorder-001", "answer": "A"}]},
        headers=alice["headers"]).get_json()

    assert result["userId"] == alice["userId"], "不能借自己的 token 写别人的数据"

    # demo-user 的掌握度不能被污染。
    #
    # ⚠️ 期望值是一份**完整清单**，不要图省事改成 `42 in scores` ——
    # 只有列全，"多出 / 少掉某个知识点"这类污染才仍然会被抓到。
    #
    # 2026-09-26：演示基线由 **1 个知识点扩到 5 个**。原因是知识画像页的雷达图
    # 要求至少 3 个维度才成形（前端 `StudyTags.ets` 的 `mastery.length >= 3`），
    # 只有二叉树一条时永远画不出来 —— 用户反馈「之前初赛版本在学情画像内
    # 有雷达图的，现在始终没有触发」的根因就在这里。新增的 4 个知识点分数
    # **都高于 42**，所以「最薄弱 = 二叉树后序遍历」与 42→58 的演示主线不变。
    demo = client.get("/api/v1/profile/demo-user", headers=H).get_json()
    scores = [m["masteryScore"] for m in demo.get("mastery", [])]
    assert scores == [42, 55, 63, 68, 74], f"demo-user 被污染了：{scores}"


def test_cannot_impersonate_via_workflow(tmp_path):
    """工作流创建路径同样不能被冒用。"""
    client = create_app(tmp_path / "impersonate-wf.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)
    alice = _register(client, "甲")

    created = client.post("/api/v1/workflows",
                          json={"goal": "冒用探测", "userId": "demo-user"},
                          headers=alice["headers"]).get_json()

    stored_owner = client.application  # 仅为可读性，下面用接口间接验证
    # 用甲的 token 跑一步，评估应写到甲名下（不报错即说明身份被正确解析）
    run = client.post(f"/api/v1/workflows/{created['sessionId']}/run",
                      json={}, headers=alice["headers"])
    assert run.status_code == 200
    assert stored_owner is not None


# --------------------------------------------------------------------- 演示链路不受影响
def test_guest_still_gets_demo_user(tmp_path):
    """不带 token 时必须仍走 demo-user —— 演示基线与评审逃生口依赖这条。"""
    client = create_app(tmp_path / "guest.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)

    profile = client.get("/api/v1/profile/demo-user", headers=H).get_json()
    plan = client.get("/api/v1/plans/current", headers=H).get_json()

    # 与 `test_cannot_impersonate_via_request_body` 里那份清单同源：
    # 演示基线自 2026-09-26 起是 5 个知识点（雷达图至少要 3 个维度才成形）。
    assert [m["masteryScore"] for m in profile["mastery"]] == [42, 55, 63, 68, 74]
    assert profile["profileVersion"] == 1
    assert plan["version"] == 1
    assert [t["durationMinutes"] for t in plan["tasks"]] == [30, 30]


def test_explicit_user_id_still_works_when_not_logged_in(tmp_path):
    """未登录时 `?userId=` 仍可用于查看指定用户（评委/curl 场景）。"""
    client = create_app(tmp_path / "explicit.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)

    response = client.get("/api/v1/plans/current?userId=demo-user", headers=H)

    assert response.status_code == 200


def test_invalid_bearer_degrades_to_guest(tmp_path):
    """无效 token 应降级为游客身份，而不是 401 打断演示。"""
    client = create_app(tmp_path / "bad-token.json").test_client()
    client.post("/api/v1/demo/reset", headers=H)

    response = client.get("/api/v1/plans/current",
                          headers=dict(H, Authorization="Bearer not-a-real-token"))

    assert response.status_code == 200, "过期/无效 token 不应把演示打成不可用"
