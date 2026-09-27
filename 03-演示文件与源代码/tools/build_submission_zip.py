# -*- coding: utf-8 -*-
"""重建提交压缩包 `知学Mate+暗影骑士王们.zip`（在**本仓库根目录**上跑）。

## 为什么需要它

仓库里原有的 `tools/build_v2.py` 把源/目标写死成
`SRC = E:\\C4-liantiao\\liantiao5` / `DST = E:\\C4-liantiao\\V2`，**不能作用于本仓库**。
而本仓库里的 zip 是当时从 V2 拷过来的，源码一改它就过期了 ——
交付物与源码不一致是提交里最危险的一类问题（评审拿到的是旧代码）。

本脚本按**本仓库的现有布局**重建 zip，排除规则与 `build_v2.py` 完全一致：
`.git` / `.hvigor` / `.idea` / `build` / `oh_modules` / `node_modules` / `__pycache__` /
`.pytest-tmp` / `.pytest_cache` / `*.pyc` / `.env` / `data/repository.json` /
`chat/history.json` / 本地签名备份。

用法::

    python tools/build_submission_zip.py [--check]
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "知学Mate"
ZIP_NAME = "知学Mate+暗影骑士王们.zip"

#: 打进 zip 的仓库根目录（顺序即写入顺序）
ROOT_DIRS = ["app", "contracts", "server", "tools", "integration", "演示测试数据"]
#: 只存在于源码区、但也该进包的目录（源 → arcname 前缀）
EXTRA_DIRS = [("03-演示文件与源代码/联调与验证", "联调与验证")]

EXCLUDE_DIRS = {".git", ".hvigor", ".idea", "build", "oh_modules", "node_modules",
                "__pycache__", ".pytest-tmp", ".pytest_cache", ".cxx"}
EXCLUDE_SUFFIXES = (".pyc", ".pyo", ".bak-round0", ".har", ".zip")
EXCLUDE_NAMES = {".env", "repository.json", "history.json", "Thumbs.db", ".DS_Store"}


def should_skip(path: Path) -> bool:
    if path.name in EXCLUDE_NAMES or path.name.startswith(".env"):
        return True
    if path.name.endswith(EXCLUDE_SUFFIXES):
        return True
    return any(part in EXCLUDE_DIRS for part in path.parts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只统计，不写文件")
    args = parser.parse_args()

    hap = ROOT / "hap" / "知学Mate-signed.hap"
    if not hap.exists():
        print("[FAIL] 找不到 %s —— 先构建签名 HAP 再打包" % hap.relative_to(ROOT))
        return 1

    zip_path = ROOT / ZIP_NAME
    written: set[str] = set()
    dup: list[str] = []

    def add(archive: zipfile.ZipFile, src: Path, arcname: str) -> bool:
        if arcname in written:
            dup.append(arcname)
            return False
        archive.write(src, arcname)
        written.add(arcname)
        return True

    if args.check:
        count = 0
        for name in ROOT_DIRS:
            base = ROOT / name
            if base.exists():
                count += sum(1 for p in base.rglob("*") if p.is_file() and not should_skip(p))
        print("[CHECK] 预计条目数（不含文档/HAP）：%d" % count)
        return 0

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        # HAP 放包内 hap/ 下 —— 规程要求"演示文件需压缩为包"
        add(z, hap, f"{PRODUCT}/hap/知学Mate-signed.hap")

        # 源码目录
        for name in ROOT_DIRS:
            base = ROOT / name
            if not base.is_dir():
                print("  !! 缺少目录 %s" % name)
                continue
            for path in sorted(base.rglob("*")):
                if not path.is_file() or should_skip(path):
                    continue
                add(z, path, f"{PRODUCT}/{path.relative_to(ROOT).as_posix()}")

        # 源码区里独有的目录
        for src_rel, arc_prefix in EXTRA_DIRS:
            base = ROOT / src_rel
            if not base.is_dir():
                continue
            for path in sorted(base.rglob("*")):
                if not path.is_file() or should_skip(path):
                    continue
                add(z, path, f"{PRODUCT}/{arc_prefix}/{path.relative_to(base).as_posix()}")

        # 根级文件：说明文档 + 仓库元文件
        for path in sorted(ROOT.iterdir()):
            if not path.is_file() or should_skip(path):
                continue
            if path.name == ZIP_NAME:
                continue
            if path.suffix.lower() in (".md", ".gitattributes", "") or path.name == "LICENSE":
                add(z, path, f"{PRODUCT}/{path.name}")

        # 作品说明文档（只放 PDF —— 评委要的就是 PDF；DOCX 留作可编辑源）
        docdir = ROOT / "01-作品说明文档"
        for p in sorted(docdir.glob("*.pdf")) if docdir.is_dir() else []:
            add(z, p, f"{PRODUCT}/作品说明文档/{p.name}")

    size = zip_path.stat().st_size
    print("[OK] 已生成 %s" % zip_path.name)
    print("     条目数 : %d" % len(written))
    print("     大小   : %d B (%.2f MB)" % (size, size / 1024 / 1024))
    if dup:
        print("     !! 重复路径被跳过 %d 个（前几个：%s）" % (len(dup), dup[:3]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
