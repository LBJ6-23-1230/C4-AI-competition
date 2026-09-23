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
#:
#: ⚠️ 运行期状态文件必须排除，它们在文档里承诺过"绝不进交付包"：
#:   · `.sqlite` / `-wal` / `-shm` —— SQLite 后端的库文件与 WAL 日志。
#:     `-wal` 尤其危险：实测它会被撑到 **684 KB**，且内容是**运行期写入**，
#:     混进交付包会让包体积莫名其妙变大，也会让人误以为里面有真实数据。
#:     （2026-09-23 验证 SQLite 后端时真的混进过 V2，抽检大文件才发现。）
EXCLUDE_SUFFIXES = {
    ".pyc", ".pyo", ".log", ".tmp", ".bak", ".old",
    ".sqlite", ".sqlite-wal", ".sqlite-shm", ".db", ".db-wal", ".db-shm",
}


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


def force_rmtree(path: Path) -> None:
    """强删目录：清只读位 + 重试，能扛住「文件被别的进程短暂占用」。

    为什么需要（两个真实踩到的坑）：

    1. V2 会被当成 git 工作区（提交版就是这样），而 git 的对象文件是**只读**的，
       `shutil.rmtree` 遇到会抛 `PermissionError: [WinError 5] 拒绝访问`。
       → 这里先清只读位再删。

    2. 演示数据（如 `02-课程表.csv`）很可能正开在 Excel / 记事本里，
       文件被占用时删不掉，报 `IOException: being used by another process`。
       单次删除会直接失败 → 这里**重试若干次**，临时占用（编辑器切换、
       复制粘贴后自动释放）通常一两秒内就好了。
    """
    import os
    import stat
    import time

    def on_error(func, target, _exc_info):
        try:
            os.chmod(target, stat.S_IWRITE)
            func(target)
        except OSError:
            pass

    last: Exception | None = None
    for attempt in range(5):
        try:
            shutil.rmtree(path, onerror=on_error)
        except OSError as exc:
            last = exc
        if not path.exists():
            return
        if attempt < 4:
            print("      … 仍有文件被占用，1 秒后重试（第 %d 次）" % (attempt + 2))
            time.sleep(1.0)
    if last is not None:
        print("      最后一次错误: %s" % last)


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
            print("  清理已存在的 V2 …（含只读的 .git 对象）")
            force_rmtree(DST)
            # ⚠️ 必须确认真的删干净了。
            # 早先这里不检查就继续，若某个文件被占用（编辑器 / 杀毒 / 残留句柄）
            # 删除会部分失败，而脚本照常往**残留的旧目录**里复制 ——
            # 结果是"改了源码但 V2 里还是旧内容"，排查时极容易被误导
            # （2026-09-23 实际踩过一次：改了 .gitignore 却怎么都不生效）。
            if DST.exists():
                leftovers = [p.name for p in list(DST.iterdir())[:8]]
                print()
                print("  !! 清理失败：%s 仍存在（可能有文件被占用）" % DST)
                print("     残留示例: %s" % leftovers)
                print("     请关闭打开了该目录的编辑器 / 资源管理器后重试。")
                print("     为避免产出**半新半旧**的提交版，本次构建已中止。")
                return 3

    if check_only:
        return 0

    DST.mkdir(parents=True)

    # ---------------- 1. 源代码 ----------------
    #
    # 放**两份**，各有明确用途：
    #
    #   a) `03-演示文件与源代码/` —— 开发工作区的原样副本。
    #      规程要求"演示文件需压缩为包"，而 V2 工作区里源码在编号目录下，
    #      保持一致可让本地工作区与仓库内容一一对应。
    #
    #   b) **V2 根目录下的 `app/ server/ contracts/ ...`** —— 摊平一份。
    #      因为仓库根就是提交版，评审点进 GitHub 看到的是根目录；
    #      摊平后 `app/` 就是标准 HarmonyOS 工程、`server/` 可直接 `run.py`，
    #      无需先钻进编号目录。DevEco 也要求"打开含 build-profile.json5 的目录"，
    #      摊平后即符合。
    #
    # 两者内容相同，体积代价约 5 MB（源码本身很小），换来两边都好用。
    print("[1/6] 复制源代码")
    srcdir = DST / "03-演示文件与源代码"
    for name in ("app", "server", "contracts", "integration", "tools"):
        src = SRC / name
        if not src.exists():
            print("      !! 缺少 %s" % name)
            continue
        n = copy_tree(src, srcdir / name, EXCLUDE_DIRS)
        m = copy_tree(src, DST / name, EXCLUDE_DIRS)
        print("      %-14s %4d 文件（编号目录 + 根目录各一份）" % (name, n))
        if n != m:
            print("      !! 两份数量不一致: %d vs %d" % (n, m))

    # 根级说明文件（两份都放）
    for name in ("README.md", "LICENSE", ".gitignore", ".gitattributes"):
        src = SRC / name
        if src.exists():
            shutil.copy2(src, srcdir / name)
            shutil.copy2(src, DST / name)
    print("      README.md / LICENSE / .gitignore / .gitattributes")

    # ---------------- 2. 签名 HAP ----------------
    print("[2/6] 复制签名 HAP")
    hap_src = SRC / "deliverables" / "知学Mate-signed.hap"
    hap_dst = srcdir / "hap" / "知学Mate-signed.hap"
    hap_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(hap_src, hap_dst)
    # 根目录也放一份，便于在仓库里直接下载
    root_hap = DST / "hap" / "知学Mate-signed.hap"
    root_hap.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(hap_src, root_hap)
    print("      %.1f MB（编号目录 + 根目录各一份）" % (hap_dst.stat().st_size / 1048576))

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
            ("仓库结构说明.md", DST / "仓库结构说明.md"),
            # 启动与部署指南同时放根目录（便于发现）与源码区（贴近代码）
            ("后端启动与部署指南.md", DST / "后端启动与部署指南.md"),
            ("后端启动与部署指南.md", srcdir / "后端启动与部署指南.md"),
            ("01-作品说明文档-README-改稿须知.md",
             docdir / "README-改稿须知.md"),
            ("02-演示视频-README-待录制.md",
             vdir / "README-待录制.md"),
            # 签名材料交接（发给定要用这套签名构建的同学）
            ("签名材料交接说明.md", DST / "签名材料交接说明.md"),
            # 出题机制答疑（发给问「题目为什么固定 / DDL 有没有影响」的同学）
            ("出题机制与DDL上传说明.md", DST / "出题机制与DDL上传说明.md"),
            # 前端实测问题逐条核查（发给报问题的前端/测试同学）
            ("前端测试问题核查.md", DST / "前端测试问题核查.md"),
            # 数据库与账户体系（含 SQLite 可选后端说明）
            ("数据库与账户体系说明.md", DST / "数据库与账户体系说明.md"),
            # 学习搭子匹配（前后端接入说明）
            ("学习搭子匹配说明.md", DST / "学习搭子匹配说明.md"),
            # 制作辅助（Word）：直接发给「录制视频的同学」和「做 PPT 的同学」
            #   视频指导 → 放 02-演示视频/（与视频材料同处）
            #   PPT 参考 → 放 04-制作辅助文档/，并附一份命名为
            #             「知学Mate-项目参考文本.docx」便于直接转交
            ("辅助文档/演示视频录制指导（含旁白脚本）.docx",
             vdir / "演示视频录制指导（含旁白脚本）.docx"),
            ("辅助文档/PPT制作参考与设计架构.docx",
             DST / "04-制作辅助文档" / "PPT制作参考与设计架构.docx"),
            ("辅助文档/PPT制作参考与设计架构.docx",
             DST / "04-制作辅助文档" / "知学Mate-项目参考文本.docx"),
        ]
        for src_name, dst_path in mapping:
            src_file = sub / src_name
            if not src_file.exists():
                print("      !! 缺少 %s" % src_name)
                continue
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_file, dst_path)
            print("      %s" % dst_path.relative_to(DST).as_posix())

    # 演示测试数据：整个目录复制。
    # 放两处 —— 源码区（录视频时好找）+ 根目录（交材料时一眼看到）。
    # 内容为课程表/作业 DDL 的 JSON 与 CSV 样例，供「上传文件」与
    # 「复制粘贴」两种导入演示使用；字段格式按 FileParserService.ets 实测核对。
    demo_src = sub / "演示测试数据"
    if demo_src.exists():
        for dst_dir in (srcdir / "演示测试数据", DST / "演示测试数据"):
            n = 0
            for f in sorted(demo_src.iterdir()):
                if f.is_file():
                    dst_dir.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(f, dst_dir / f.name)
                    n += 1
            print("      %s  (%d 个文件)" % (dst_dir.relative_to(DST).as_posix(), n))
    else:
        print("      !! 缺少 submission/演示测试数据/")

    # ---------------- 6. 生成提交 zip ----------------
    print("[6/6] 生成提交压缩包")
    zip_path = DST / f"{PRODUCT}+{TEAM}.zip"
    entries = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        # 去重保护。
        # ⚠️ 为什么必须有：有些文件在 V2 里**故意放两份**（源码区 + 根目录），
        # 例如「后端启动与部署指南」「演示测试数据」。若两边各写一次，
        # zip 里就会出现**重复条目** ——`zipfile` 只给 UserWarning，
        # 产物看起来正常，但评审解压行为不确定（2026-09-23 实际踩到两次：
        # 先是 hap/，再是根级说明与演示数据）。
        # 这里统一记录已写入的路径，重复则**直接抛错**，不再静默产出。
        written: set[str] = set()

        def add(src: Path, arcname: str) -> bool:
            if arcname in written:
                return False
            z.write(src, arcname)
            written.add(arcname)
            return True

        # HAP 放包内 hap/ 下 —— 规程要求"演示文件需压缩为包"
        add(hap_dst, f"{PRODUCT}/hap/知学Mate-signed.hap")
        for path in srcdir.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(srcdir)
            if rel.parts and rel.parts[0] == "hap":
                continue          # 已单独写入
            if path.name == zip_path.name:
                continue
            add(path, f"{PRODUCT}/{rel.as_posix()}")
        # 作品说明文档也一并入包，避免评审漏拿
        for p in docdir.glob("*.pdf"):
            add(p, f"{PRODUCT}/作品说明文档/{p.name}")
        # 根级说明文档也入包。
        # ⚠️ 必须显式列举：这些文件在 V2 **根目录**，而上面的 srcdir 只覆盖
        # 「03-演示文件与源代码/」下的内容 —— 漏掉这一步就会出现
        # "V2 里能看到、解压提交包却找不到"的情况（2026-09-23 实际踩到：
        # 出题机制说明没进包，抽检才发现）。
        # 与源码区重名的（后端启动与部署指南）由 add() 自动跳过，不产生重复。
        root_docs = [
            "README-提交说明.md", "仓库结构说明.md", "提交清单与待办.md",
            "后端启动与部署指南.md", "签名材料交接说明.md",
            "出题机制与DDL上传说明.md", "前端测试问题核查.md",
            "数据库与账户体系说明.md", "学习搭子匹配说明.md",
        ]
        for name in root_docs:
            p = DST / name
            if not p.exists():
                print("      !! 根级说明缺失，未入包: %s" % name)
                continue
            add(p, f"{PRODUCT}/{name}")
        # 演示测试数据（根目录那份）。源码区已有一份同名文件，
        # add() 会跳过，因此包内只会出现一份。
        demo_root = DST / "演示测试数据"
        if demo_root.exists():
            for p in sorted(demo_root.iterdir()):
                if p.is_file():
                    add(p, f"{PRODUCT}/演示测试数据/{p.name}")
        entries = len(written)
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
