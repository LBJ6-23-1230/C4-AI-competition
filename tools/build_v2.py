# -*- coding: utf-8 -*-
"""构建 V2 —— 最终提交版本。

## 为什么要有这个脚本

V1 在开发过程中被 DevEco 的构建产物污染过两次（`entry/build` 270 文件 19.8 MB、
`.hvigor`、`oh_modules`、`.idea`），每次都是手工清理、容易漏。
提交版本**必须可复现**，所以这里把"什么该进、什么不该进"固化成脚本。

## 目标结构

    V2/
    ├── README-提交说明.md          ← 给评审/队友看的入口
    ├── 提交清单与待办.md            ← 逐项标注 已完成/待你补
    ├── 01-作品说明文档/
    ├── 02-演示视频/                 ← 待录，留占位说明
    ├── 03-演示文件与源代码/
    │   ├── 知学Mate+暗影骑士王们.zip ← **真正要上传的包**
    │   ├── hap/知学Mate-signed.hap
    │   ├── app/ server/ contracts/ integration/ tools/
    │   └── 联调与验证/
    ├── 项目文档/                    ← docs/ 全量
    └── 实证材料/                    ← evidence/ 全量

## 严格排除（这些进过 V1，不该进提交版）

`.hvigor` / `.idea` / `build` / `oh_modules` / `node_modules` / `__pycache__` /
`.pytest-tmp` / `.pytest_cache` / `*.pyc` / `.env` / `data/repository.json` /
`chat/history.json` / `.git`

用法：

    python tools/build_v2.py [--check]
"""

from __future__ import annotations

import json
import shutil
import sys
import zipfile
from pathlib import Path

WORKSPACE = Path(r"E:\C4-liantiao")
SRC = WORKSPACE / "liantiao5"          # 源工程（唯一真源）
DST = WORKSPACE / "V2"

TEAM = "暗影骑士王们"
PRODUCT = "知学Mate"

#: 目录名黑名单（出现在路径的任意一级就排除）
EXCLUDE_DIRS = {
    ".git", ".hvigor", ".idea", ".vscode", ".cxx", "build", "oh_modules",
    "node_modules", "__pycache__", ".pytest_cache", ".pytest-tmp", ".uv-cache",
    ".packaging", "deliverables", "evidence",
}

#: 文件名黑名单
EXCLUDE_NAMES = {".env", "repository.json", "history.json", "local.properties"}

#: 后缀黑名单
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".log", ".tmp", ".bak", ".old"}


def walk_files(root: Path, exclude_dirs: set[str]):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root)
        parts = rel.parts
        if any(p in exclude_dirs for p in parts[:-1]):
            continue
        if any(p.startswith("pytest-cache-files-") for p in parts):
            continue
        if path.name in EXCLUDE_NAMES:
            continue
        if path.suffix.lower() in EXCLUDE_SUFFIXES:
            continue
        yield path, rel


def copy_tree(src: Path, dst: Path, exclude_dirs: set[str]) -> int:
    n = 0
    for path, rel in walk_files(src, exclude_dirs):
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        n += 1
    return n


def main() -> int:
    check_only = "--check" in sys.argv

    print("=" * 84)
    print("构建 V2 —— 最终提交版本")
    print("=" * 84)
    print("  源工程: %s" % SRC)
    print("  目标  : %s" % DST)
    print()

    if not SRC.exists():
        print("!! 源工程不存在，放弃")
        return 2

    if DST.exists():
        if check_only:
            print("--check 模式：V2 已存在，仅报告")
        else:
            print("  清理已存在的 V2 …")
            shutil.rmtree(DST)

    if check_only:
        return 0

    DST.mkdir(parents=True)

    # ---------------- 1. 源代码（三个子目录）----------------
    print("[1/6] 复制源代码")
    srcdir = DST / "03-演示文件与源代码"
    counts = {}
    for name in ("app", "server", "contracts", "integration", "tools"):
        src = SRC / name
        if not src.exists():
            print("      !! 缺少 %s" % name)
            continue
        n = copy_tree(src, srcdir / name, EXCLUDE_DIRS)
        counts[name] = n
        print("      %-14s %4d 文件" % (name, n))

    # 根级说明文件
    for name in ("README.md", "LICENSE", ".gitignore", ".gitattributes"):
        src = SRC / name
        if src.exists():
            shutil.copy2(src, srcdir / name)

    # ---------------- 2. 签名 HAP ----------------
    print("[2/6] 复制签名 HAP")
    hap_src = SRC / "deliverables" / "知学Mate-signed.hap"
    hap_dst = srcdir / "hap" / "知学Mate-signed.hap"
    hap_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(hap_src, hap_dst)
    print("      %.1f MB" % (hap_dst.stat().st_size / 1048576))

    # ---------------- 3. 项目文档与实证材料 ----------------
    print("[3/6] 复制文档与证据")
    n_docs = copy_tree(SRC / "docs", DST / "项目文档", EXCLUDE_DIRS)
    # README-签名HAP.md 也放进文档区，便于单独查阅
    sign_readme = SRC / "deliverables" / "README-签名HAP.md"
    if sign_readme.exists():
        shutil.copy2(sign_readme, DST / "项目文档" / "签名HAP说明.md")
    print("      项目文档  %4d 文件" % n_docs)

    n_ev = copy_tree(SRC / "evidence", DST / "实证材料", EXCLUDE_DIRS)
    # 联调脚本与验证工具也放一份到"联调与验证"，便于评审直接跑
    lv = srcdir / "联调与验证"
    lv.mkdir(parents=True, exist_ok=True)
    for f in ("integration/run_liantiao5.py", "integration/verify_integration.py",
              "server/zhixue-agent-server/run.py"):
        p = SRC / f
        if p.exists():
            shutil.copy2(p, lv / Path(f).name)
    print("      实证材料  %4d 文件" % n_ev)

    # ---------------- 4. 作品说明文档 ----------------
    print("[4/6] 收集作品说明文档")
    docdir = DST / "01-作品说明文档"
    docdir.mkdir(parents=True, exist_ok=True)
    camp = WORKSPACE / "C4-AI大赛"
    found_doc = False
    for cand in ("01-作品说明文档-暗影骑士王们.pdf",
                 "01-作品说明文档-暗影骑士王们.docx",
                 "2026中国高校计算机大赛人工智能创意赛初赛（鸿蒙赛道）作品说明文档模板.docx"):
        p = camp / cand
        if p.exists():
            shutil.copy2(p, docdir / cand)
            print("      %s" % cand)
            if cand.endswith(".pdf"):
                found_doc = True
    if not found_doc:
        print("      !! 未找到作品说明文档 PDF")

    # ---------------- 5. 演示视频占位 ----------------
    print("[5/6] 演示视频目录")
    vdir = DST / "02-演示视频"
    vdir.mkdir(parents=True, exist_ok=True)
    print("      留空 + 占位说明（待录制）")

    # ---------------- 5b. 复制说明文档（必须由脚本产出，否则重建会丢）----------------
    # ⚠️ 这一步是踩过坑才有的：早先这些 README 是手工写在 V2 里的，
    # 而本脚本每次开头会 `shutil.rmtree(DST)`，于是一次重建就把它们冲掉了。
    # 提交版必须**完全可复现**，所以说明文档的来源固定在 `liantiao5/submission/`，
    # 每次构建都从这里复制过去。**不要直接编辑 V2 里的副本。**
    print("[5b] 复制说明文档")
    sub = SRC / "submission"
    if not sub.exists():
        print("      !! 缺少 %s —— 说明文档不会生成" % sub)
    else:
        mapping = [
            ("README-提交说明.md", DST / "README-提交说明.md"),
            ("提交清单与待办.md", DST / "提交清单与待办.md"),
            ("01-作品说明文档-README-改稿须知.md",
             docdir / "README-改稿须知.md"),
            ("02-演示视频-README-待录制.md",
             vdir / "README-待录制.md"),
        ]
        for src_name, dst_path in mapping:
            src_file = sub / src_name
            if not src_file.exists():
                print("      !! 缺少 %s" % src_name)
                continue
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_file, dst_path)
            print("      %s" % dst_path.relative_to(DST).as_posix())

    # ---------------- 6. 生成提交 zip ----------------
    print("[6/6] 生成提交压缩包")
    zip_path = DST / f"{PRODUCT}+{TEAM}.zip"
    entries = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        # HAP 放包内 hap/ 下 —— 规程要求"演示文件需压缩为包"。
        # ⚠️ 写完之后遍历源码目录时必须**跳过 hap/**，否则同一路径会被写两次
        # （zipfile 只给 UserWarning，产物里是重复条目，评审解压行为不确定）。
        z.write(hap_dst, f"{PRODUCT}/hap/知学Mate-signed.hap")
        entries += 1
        for path in srcdir.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(srcdir)
            if rel.parts and rel.parts[0] == "hap":
                continue          # 已单独写入，避免重复条目
            if path.name == zip_path.name:
                continue
            z.write(path, f"{PRODUCT}/{rel.as_posix()}")
            entries += 1
        # 作品说明文档也一并入包，避免评审漏拿
        for p in docdir.glob("*.pdf"):
            z.write(p, f"{PRODUCT}/作品说明文档/{p.name}")
            entries += 1
    print("      %s  （%d 条目 / %.2f MB）"
          % (zip_path.name, entries, zip_path.stat().st_size / 1048576))

    # ---------------- 统计 ----------------
    files = [p for p in DST.rglob("*") if p.is_file()]
    total = sum(p.stat().st_size for p in files)
    print()
    print("=" * 84)
    print("V2 总计：%d 文件 / %.2f MB" % (len(files), total / 1048576))
    print("=" * 84)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
