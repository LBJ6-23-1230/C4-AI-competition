"""把工程内所有过期的「104 项自检」引用统一更新为「105 项」，含分组明细。

背景：为了让自检脚本在「后端独立交付包」中不再误报失败，
`tools/verify_liantiao1.py` 的静态一致性组被重构——
新增 2 项后端鉴权检查（源码齐备 / 测试套件齐备），
聚合掉的 1 项前端文件检查被拆开。
于是总数由 104 变为 105，静态一致性组由 18 变为 19。

用法：python tools/sync_verify_counts.py [--check]
    --check  只报告差异，不写文件
"""

import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent

# 只处理文本类工程文件；不碰 evidence/（那是脚本产物，重跑即更新）
TARGETS = [
    *ROOT.glob("*.md"),
    *ROOT.glob("docs/*.md"),
    *(ROOT / "tools").glob("*.py"),
    *(ROOT / "tools").glob("*.ps1"),
]
_handoff = ROOT / "handoff"
if _handoff.exists():
    TARGETS.extend(_handoff.glob("*.txt"))

# 顺序要紧：先长后短，避免「104/104」被「104 项」规则二次命中
REPLACEMENTS = [
    ("104/104", "105/105"),
    ("104 / 104", "105 / 105"),
    ("104 项", "105 项"),
    ("104项", "105项"),
    ("**104**", "**105**"),
    ("（18/18）", "（19/19）"),
    ("| ⓪ 静态一致性 | 18 |", "| ⓪ 静态一致性 | 19 |"),
    ("| ⓪ 静态一致性 | 契约双份文件逐字节一致、契约版本 v0.3、"
     "无硬编码 IP、`ApiDefaults` 单一真源、**游客 userId 无散落硬编码**、"
     "登录功能文件齐备、契约声明 auth 与 BearerAuth | 18 |",
     "| ⓪ 静态一致性 | 契约双份文件逐字节一致、契约版本 v0.3、"
     "无硬编码 IP、`ApiDefaults` 单一真源、**游客 userId 无散落硬编码**、"
     "登录功能文件齐备、契约声明 auth 与 BearerAuth、"
     "**后端鉴权源码与测试齐备**（后端独立包模式下前端项自动跳过） | 19 |"),
]

# 这些文件里的「104」与自检计数无关，跳过
SKIP_FILES = {"sync_verify_counts.py"}


def main() -> int:
    check_only = "--check" in sys.argv
    changed: list[tuple[Path, int]] = []

    for path in TARGETS:
        if path.name in SKIP_FILES or not path.is_file():
            continue
        try:
            original = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        text = original
        hits = 0
        for old, new in REPLACEMENTS:
            n = text.count(old)
            if n:
                text = text.replace(old, new)
                hits += n
        if text != original:
            changed.append((path.relative_to(ROOT), hits))
            if not check_only:
                path.write_text(text, encoding="utf-8")

    print(f"{'[CHECK]' if check_only else '[UPDATED]'} 受影响文件 {len(changed)} 个")
    for rel, n in sorted(changed, key=lambda x: str(x[0])):
        print(f"   {n:3d} 处  {rel.as_posix()}")

    if check_only:
        return 1 if changed else 0

    # 复查：确认没有遗漏的纯 104 计数引用
    print()
    print("=== 复查：仍含「104」的工程文件 ===")
    leftovers = []
    for path in TARGETS:
        if path.name in SKIP_FILES or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for num, line in enumerate(text.splitlines(), start=1):
            if "104" in line:
                leftovers.append(f"{path.relative_to(ROOT).as_posix()}:{num}  {line.strip()[:90]}")
    if leftovers:
        for item in leftovers:
            print("   ", item)
    else:
        print("    无（全部已更新）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
