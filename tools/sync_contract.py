# -*- coding: utf-8 -*-
"""契约同步 / 校验工具。

背景（真实发生过的联调阻塞）
----------------------------
`openapi.json` 有两份副本，都是"真源"：

* `contracts/openapi.json`      —— 后端实现所依据的契约真源
* `app/contracts/openapi.json`  —— 前端 `entry/src/main/ets/api/` 读取的镜像

项目纪律要求两份**逐字节一致**（`integration/run_liantiao5.py` 的
`check_contract_sync()` 会把它当作联调硬闸门，不一致直接报红）。

但打包时会**分别**生成前端包与后端包：
后端同学在自己的包里改了 `contracts/openapi.json`（新增验证码接口），
前端包里的 `app/contracts/openapi.json` 就不会自动跟上。实测 liantiao5
合并后：真源 78,258 字节 / 镜像 72,336 字节，镜像缺
`/api/v1/auth/send-code` 与 `/api/v1/auth/verify-code` 两个端点 ——
前端同学按镜像开发就会完全不知道有验证码登录可用。

用法::

    python tools/sync_contract.py --check   # 只校验（CI / 联调闸门用）
    python tools/sync_contract.py           # 真源 -> 镜像 单向同步
    python tools/sync_contract.py --to-source   # 镜像 -> 真源（应急，谨慎）
"""

import argparse
import json
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
CANONICAL = ROOT / "contracts" / "openapi.json"
MIRROR = ROOT / "app" / "contracts" / "openapi.json"

#: 契约里必须存在的端点，防止"改着改着把接口删了"。
REQUIRED_PATHS = (
    "/api/v1/auth/send-code",
    "/api/v1/auth/verify-code",
    "/api/v1/auth/login-with-huawei",
    "/api/v1/knowledge-bases",
    "/api/v1/knowledge-bases/{kbId}/search",
    "/api/v1/plans/current",
    "/api/v1/workflows",
)


def describe(path: pathlib.Path):
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return None, f"解析失败: {exc}"
    return doc, (f"{path.stat().st_size:,} B  "
                 f"paths={len(doc.get('paths', {}))}  "
                 f"schemas={len(doc.get('components', {}).get('schemas', {}))}  "
                 f"version={doc.get('info', {}).get('version')}")


def main() -> int:
    parser = argparse.ArgumentParser(description="契约真源 / 前端镜像 同步与校验")
    parser.add_argument("--check", action="store_true", help="只校验，不修改")
    parser.add_argument("--to-source", action="store_true", help="反向同步（镜像 -> 真源）")
    args = parser.parse_args()

    print("=" * 74)
    print("契约同步校验")
    print("=" * 74)

    for label, path in (("真源 contracts/", CANONICAL), ("镜像 app/contracts/", MIRROR)):
        if not path.exists():
            print(f"  {label:22s} 缺失：{path}")
            if args.check:
                return 1
            continue
        _, text = describe(path)
        print(f"  {label:22s} {text}")

    if not CANONICAL.exists() or not MIRROR.exists():
        print("\n  只有一份副本（单独打包的场景），跳过比对。")
        return 0

    same = CANONICAL.read_bytes() == MIRROR.read_bytes()

    # ---- 必需端点检查（对真源做）-----------------------------------------
    doc, _ = describe(CANONICAL)
    missing = [p for p in REQUIRED_PATHS if p not in doc.get("paths", {})] if doc else []
    if missing:
        print("\n  [X] 真源缺少必需端点:")
        for p in missing:
            print(f"        {p}")

    if same:
        mirror_doc, _ = describe(MIRROR)
        only_canonical = sorted(set(doc.get("paths", {})) - set(mirror_doc.get("paths", {})))
        print(f"\n  [OK] 两份契约逐字节一致（{CANONICAL.stat().st_size:,} B）")
        if only_canonical:
            print(f"       但真源比镜像多 {len(only_canonical)} 个端点：{only_canonical}")
            return 1
        return 0

    print("\n  [X] 两份契约不一致 —— 前端若按镜像开发会漏掉新接口。")
    if doc:
        mirror_doc, _ = describe(MIRROR)
        if mirror_doc:
            diff = sorted(set(doc.get("paths", {})) - set(mirror_doc.get("paths", {})))
            extra = sorted(set(mirror_doc.get("paths", {})) - set(doc.get("paths", {})))
            if diff:
                print(f"       镜像缺少 {len(diff)} 个端点:")
                for p in diff:
                    print(f"         - {p}")
            if extra:
                print(f"       镜像多出 {len(extra)} 个端点（真源已删？）:")
                for p in extra:
                    print(f"         + {p}")

    if args.check:
        print("\n  --check：未修改任何文件。修复请运行：python tools/sync_contract.py")
        return 1

    src, dst = (MIRROR, CANONICAL) if args.to_source else (CANONICAL, MIRROR)
    backup = dst.with_suffix(dst.suffix + ".bak")
    shutil.copy2(dst, backup)
    shutil.copy2(src, dst)
    print(f"\n  [OK] 已同步 {src.relative_to(ROOT)} -> {dst.relative_to(ROOT)}")
    print(f"       原文件备份为 {backup.name}")
    print(f"       同步后 {dst.stat().st_size:,} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
