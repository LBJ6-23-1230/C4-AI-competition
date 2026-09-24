# -*- coding: utf-8 -*-
"""把 `data/repository.json` 恢复成**干净的演示基线**。

问题
----
交付包里的 `repository.json` 经过反复 pytest + 联调，已经同时具备两种污染：

1. **账号膨胀** —— 158 个 `u-xxxxxxxxxxxx` 测试用户 + 254 个会话，
   文件 324 KB（真实运行只需几十 KB）。
2. **演示数据被改写** —— `demo-user` 的画像被联调脚本跑到
   `profileVersion=5`、`masteryScore=99`、并带上一条真实 `history`；
   落盘的 `plan-demo-001` 版本变成 4。这类"跑过一次就回不去"的状态
   会让答辩演示的数字取决于之前谁跑过什么。

为什么不能靠接口修
------------------
* `ensure_demo_data()` 只在 `profiles["demo-user"]` **缺失**时播种，
  已存在就跳过 —— 不清理、也不重置。
* `POST /api/v1/demo/reset` 刻意**不碰** `users` / `sessions` /
  `profiles` / `plans`（`sessions` 是鉴权表，清掉＝所有用户掉线；
  `profiles`/`plans` 是真实用户资产）。

做法
----
复用后端**自己的** `app.api.demo._demo_state()` 生成基线，保证与
`ensure_demo_data()` / `demo/reset` 完全一致，不手写第二份真相。
同时清掉所有非演示账号与鉴权会话。

用法::

    python tools/clean_repository.py --dry-run    # 只报告
    python tools/clean_repository.py              # 清理并恢复演示基线
    python tools/clean_repository.py --keep-sessions 3
"""

import argparse
import collections
import json
import pathlib
import shutil
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
SERVER = HERE.parent / "server" / "zhixue-agent-server"
DEFAULT_REPO = SERVER / "data" / "repository.json"

#: 保留的演示身份。`demo-user` 与 `app/api/identity.py`、前端 `AuthStore` 一致。
KEEP_USER_IDS = {"demo-user"}

#: 演示计划 ID，与 `app.api.demo._demo_state()` 保持一致。
DEMO_PLAN_ID = "plan-demo-001"

#: 按 `userId` 字段判定归属的集合。
OWNED_COLLECTIONS = ("profiles", "plans", "users")


def is_test_user(uid) -> bool:
    return uid not in KEEP_USER_IDS


def load_demo_state():
    """从后端导入演示基线，避免在这里复制一份真相。"""
    sys.path.insert(0, str(SERVER))
    from app.api.demo import _demo_state  # noqa: PLC0415

    return _demo_state()


def main() -> int:
    parser = argparse.ArgumentParser(description="清理 repository.json 并恢复演示基线")
    parser.add_argument("--repo", default=str(DEFAULT_REPO), help="repository.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="只报告不写入")
    parser.add_argument("--keep-sessions", type=int, default=0,
                        help="保留最近 N 个会话（默认 0，全部清除）")
    parser.add_argument("--no-restore-demo", action="store_true",
                        help="只清账号，不把 demo-user 画像/计划重置为基线")
    args = parser.parse_args()

    path = pathlib.Path(args.repo)
    if not path.exists():
        print(f"找不到 {path}")
        return 1

    before_bytes = path.stat().st_size
    data = json.loads(path.read_text(encoding="utf-8"))

    print("=" * 74)
    print("repository.json 清理 + 演示基线恢复")
    print("=" * 74)
    print(f"  文件    : {path}")
    print(f"  清理前  : {before_bytes:,} B")

    removed = collections.Counter()

    # ---- 1) 测试账号 -----------------------------------------------------
    # `plans` 不能按 key 判：key 形如 `plan-u-xxxx`，但演示计划
    # `plan-demo-001` 落盘时**没有** `userId` 字段（`ensure_demo_data()`
    # 只在内存里补），按 key 判会把它当孤儿误删。
    for coll in OWNED_COLLECTIONS:
        table = data.get(coll) or {}
        if not isinstance(table, dict):
            continue
        for key in list(table):
            record = table[key]
            uid = record.get("userId", key) if isinstance(record, dict) else key
            if is_test_user(uid):
                del table[key]
                removed[coll] += 1

    # ---- 2) 孤儿计划：归属用户已不存在 -----------------------------------
    plans = data.get("plans") or {}
    live = set((data.get("profiles") or {}).keys())
    for key in list(plans):
        if key == DEMO_PLAN_ID:
            continue
        owner = plans[key].get("userId", key) if isinstance(plans[key], dict) else key
        if owner not in live:
            del plans[key]
            removed["plans(orphan)"] += 1

    # ---- 3) 鉴权会话 -----------------------------------------------------
    sessions = data.get("sessions") or {}
    if args.keep_sessions <= 0:
        removed["sessions"] = len(sessions)
        data["sessions"] = {}
    elif len(sessions) > args.keep_sessions:
        def issued(item):
            value = item[1].get("issuedAt", "") if isinstance(item[1], dict) else ""
            return value or ""

        keep = dict(sorted(sessions.items(), key=issued)[-args.keep_sessions:])
        removed["sessions"] = len(sessions) - len(keep)
        data["sessions"] = keep

    # ---- 4) 过期验证码 ---------------------------------------------------
    codes = data.get("verification_codes") or {}
    if codes:
        removed["verification_codes"] = len(codes)
        data["verification_codes"] = {}

    # ---- 5) 演示基线恢复 -------------------------------------------------
    if not args.no_restore_demo:
        profile, plan, trace = load_demo_state()
        old_profile = data.get("profiles", {}).get("demo-user") or {}
        if old_profile and old_profile.get("profileVersion") != profile.profile_version:
            removed["demo-user 画像重置(版本 %s->%s)"
                    % (old_profile.get("profileVersion"), profile.profile_version)] += 1
        data.setdefault("profiles", {})["demo-user"] = profile.to_dict()
        plan_data = plan.to_dict()
        plan_data["userId"] = profile.user_id
        data.setdefault("plans", {})[plan.plan_id] = plan_data
        data.setdefault("traces", {})[trace["traceId"]] = trace

    print("\n  清除明细:")
    if removed:
        for coll, n in removed.most_common():
            print(f"    {coll:34s} -{n}")
    else:
        print("    （无需清理）")

    print("\n  清理后集合规模:")
    for coll in sorted(data):
        table = data[coll]
        n = len(table) if hasattr(table, "__len__") else "-"
        print(f"    {coll:24s} {n}")

    if args.dry_run:
        print("\n  --dry-run：未写入。")
        return 0

    backup = path.with_suffix(f".json.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, backup)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    after_bytes = path.stat().st_size
    print(f"\n  备份    : {backup.name}")
    print(f"  清理后  : {after_bytes:,} B  (缩减 {before_bytes - after_bytes:,} B, "
          f"{(1 - after_bytes / before_bytes) * 100:.1f}%)")
    print("\n  演示基线：demo-user / plan-demo-001 / trace-demo-reset-001 已恢复为初始值。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
