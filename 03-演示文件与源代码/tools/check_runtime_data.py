# -*- coding: utf-8 -*-
"""检查"运行态数据"有没有混进交付物。

## 背景

本工程有两类很容易被误提交的文件：

1. **仓库/历史类**：`server/zhixue-agent-server/data/repository.json`、
   `chat/history.json` —— 运行期间由服务写入。
2. **种子数据类**：`chat/mock_wrong_questions.json` —— 它**是**被 git 跟踪的
   种子文件，但服务在"分析错题"时也会往里追加条目。

第 2 类尤其危险：它看起来像正常源码文件，实际每次跑联调/演示都会增长。
2026-09-22 的一次提交就不小心把它带上了（多出 39 行、`createdAt` 是当天时间），
事后才发现并还原。

## 本脚本判什么

* 第 1 类：**存在即失败**（它们本就被 .gitignore 覆盖，出现在交付目录里说明漏了）
* 第 2 类：比对**条目数上限**与**时间戳新鲜度**——
  如果最新条目的时间戳晚于"种子基线时间"，说明运行期又写进去了

用法：

    python tools/check_runtime_data.py [<工程根>]
    python tools/check_runtime_data.py --strict     # 有问题则退出码 1
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

#: 种子数据的时间戳基线。任何晚于它的条目都是**运行期新增**的。
#: 取值为仓库里已知最后一条手工种子数据的日期。
SEED_BASELINE = "2026-09-21"

#: 允许出现在种子文件里的最大条目数（超出说明被运行期追加过）。
SEED_MAX_ENTRIES = 15

MUST_NOT_EXIST = [
    "server/zhixue-agent-server/data/repository.json",
    "server/zhixue-agent-server/chat/history.json",
]

SEED_FILES = [
    "server/zhixue-agent-server/chat/mock_wrong_questions.json",
]


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = Path(args[0]).resolve() if args else Path(__file__).resolve().parents[1]

    print("=" * 78)
    print("运行态数据检查   根目录: %s" % root)
    print("=" * 78)

    problems: list[str] = []

    # ---- 1. 不该存在的文件 ----
    print()
    print("① 不该出现在交付物里的运行态文件")
    for rel in MUST_NOT_EXIST:
        p = root / rel
        exists = p.exists()
        print("  [%s] %s" % ("!! 存在" if exists else "OK  ", rel))
        if exists:
            problems.append("%s 存在（运行态数据，不应交付）" % rel)

    # ---- 2. 种子数据是否被运行期追加 ----
    print()
    print("② 种子数据是否被运行期写入污染")
    for rel in SEED_FILES:
        p = root / rel
        if not p.exists():
            print("  [SKIP] %s 不存在" % rel)
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            problems.append("%s 无法解析: %s" % (rel, error))
            print("  [FAIL] %s 无法解析: %s" % (rel, error))
            continue

        if not isinstance(data, list):
            print("  [SKIP] %s 不是数组，跳过" % rel)
            continue

        count = len(data)
        stamps = [str(item.get("createdAt", "")) for item in data
                  if isinstance(item, dict)]
        fresh = sorted(s for s in stamps if s[:10] > SEED_BASELINE)

        ok_count = count <= SEED_MAX_ENTRIES
        ok_fresh = not fresh

        print("  %s" % rel)
        print("    条目数 %d（上限 %d）%s" % (count, SEED_MAX_ENTRIES,
                                          "" if ok_count else "   <== 超出，被追加过"))
        if fresh:
            print("    晚于基线 %s 的条目 %d 条（最新 %s）  <== 运行期写入"
                  % (SEED_BASELINE, len(fresh), fresh[-1]))
        else:
            print("    无晚于基线 %s 的条目" % SEED_BASELINE)

        if not ok_count:
            problems.append("%s 条目数 %d 超过上限 %d（运行期追加）"
                            % (rel, count, SEED_MAX_ENTRIES))
        if not ok_fresh:
            problems.append("%s 含运行期新增条目（最新 %s）" % (rel, fresh[-1]))

    # ---- 3. 临时目录残留 ----
    print()
    print("③ 测试临时目录残留")
    leftovers = []
    for pattern in ("**/.pytest-tmp", "**/pytest-cache-files-*", "**/__pycache__"):
        for hit in root.glob(pattern):
            if hit.is_dir():
                leftovers.append(str(hit.relative_to(root)))
    if leftovers:
        for item in leftovers[:10]:
            print("  !! %s" % item)
        problems.append("临时目录残留 %d 处" % len(leftovers))
    else:
        print("  OK   无残留")

    print()
    print("=" * 78)
    if problems:
        print("结论：FAIL（%d 项）" % len(problems))
        for item in problems:
            print("  - %s" % item)
        return 1 if strict else 0
    print("结论：PASS（交付物干净，无运行态数据）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
