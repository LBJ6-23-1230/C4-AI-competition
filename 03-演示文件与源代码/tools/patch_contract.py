# -*- coding: utf-8 -*-
"""把前后端已经实际收发的字段补进 openapi.json（契约收敛）。

背景：前端已经实现并消费这些字段，但契约未声明，违反"契约是唯一真相来源"。
本脚本只做**新增**，不改任何既有字段名或枚举值，因此对既有客户端是安全的。

补入内容：
1. `LegacyChatResponse.llmUsed`（boolean, 非 required）—— 前端 ChatMain 已据它显示
   「大模型生成 / 本地规则兜底」；后端 chat_llm.py 已返回。
2. `ProactiveRequest.context` 的 masteryScore / errorIntensity / daysLeft /
   importance / pendingTasks —— 前端 ProactiveViewModel 已发送，
   后端 proactive.py 已读取（pendingTasks 还驱动通知正文里的任务名）。
3. 新增 schema `PendingTaskSignal`。

用法::

    python tools/patch_contract.py <workspace-root>
    python tools/patch_contract.py <workspace-root> --check   # 只检查不写
"""

import argparse
import json
import shutil
from collections import OrderedDict
from pathlib import Path

PENDING_TASK_SCHEMA = OrderedDict([
    ("type", "object"),
    ("description", "待办 DDL 信号。后端据 daysLeft 与 started 判断是否临近截止，"
                    "并用 title 生成通知正文。"),
    ("properties", OrderedDict([
        ("taskId", OrderedDict([("type", "string"), ("nullable", True)])),
        ("title", OrderedDict([("type", "string"), ("nullable", True)])),
        ("status", OrderedDict([
            ("type", "string"), ("nullable", True),
            ("description", "in_progress / completed 视为已开始"),
        ])),
        ("started", OrderedDict([
            ("type", "boolean"), ("nullable", True),
            ("description", "显式「已开始」标志，与 status 取或"),
        ])),
        ("daysLeft", OrderedDict([
            ("type", "integer"), ("nullable", True),
            ("description", "距 DDL 天数；<=2 且未开始时触发 pending_ddl_within_2d"),
        ])),
        ("knowledgePointId", OrderedDict([("type", "string"), ("nullable", True)])),
    ])),
])

PROACTIVE_CONTEXT_EXTRA = OrderedDict([
    ("masteryScore", OrderedDict([
        ("type", "number"), ("nullable", True),
        ("description", "当前薄弱知识点掌握度；<80 且 daysLeft<=7 时参与考试类提醒判断"),
    ])),
    ("errorIntensity", OrderedDict([
        ("type", "number"), ("nullable", True),
        ("description", "错误强度，参与优先级五因子计算"),
    ])),
    ("daysLeft", OrderedDict([
        ("type", "integer"), ("nullable", True),
        ("description", "最近考试倒计时天数"),
    ])),
    ("importance", OrderedDict([
        ("type", "number"), ("nullable", True),
        ("description", "知识点重要度，参与优先级五因子计算"),
    ])),
    ("pendingTasks", OrderedDict([
        ("type", "array"),
        ("nullable", True),
        ("items", OrderedDict([("$ref", "#/components/schemas/PendingTaskSignal")])),
        ("description", "待办 DDL 列表。缺失时 pending_ddl_within_2d 触发路径不可达。"),
    ])),
])


def patch(root: Path, check_only: bool) -> int:
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"
    if not canonical.exists():
        print(f"[FAIL] 找不到契约真源：{canonical}")
        return 2

    doc = json.loads(canonical.read_text(encoding="utf-8"),
                     object_pairs_hook=OrderedDict)
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    changes = []

    # --- 1. LegacyChatResponse.llmUsed ---
    chat = schemas.get("LegacyChatResponse")
    if chat is None:
        print("[WARN] 契约里没有 LegacyChatResponse，跳过 llmUsed")
    else:
        props = chat.setdefault("properties", OrderedDict())
        if "llmUsed" not in props:
            props["llmUsed"] = OrderedDict([
                ("type", "boolean"),
                ("description", "true=大模型生成；false=本地确定性规则兜底"
                                "（未配置 Key 或调用失败）。前端 ChatMain 据此显示来源标签。"),
            ])
            changes.append("LegacyChatResponse.llmUsed")
        # 保持既有 required 不变（llmUsed 是可选字段，老客户端仍兼容）
        if "card" in props and "description" not in props["card"]:
            props["card"]["description"] = ("意图对应的结构化卡片；"
                                            "targetPage 必须是 App 已注册路由。")

    # --- 2. PendingTaskSignal schema ---
    if "PendingTaskSignal" not in schemas:
        schemas["PendingTaskSignal"] = PENDING_TASK_SCHEMA
        changes.append("components.schemas.PendingTaskSignal")

    # --- 3. ProactiveRequest.context 补字段 ---
    proactive = schemas.get("ProactiveRequest")
    if proactive is None:
        print("[WARN] 契约里没有 ProactiveRequest，跳过 context 扩展")
    else:
        context = proactive.setdefault("properties", OrderedDict()).get("context")
        if not isinstance(context, dict):
            print("[WARN] ProactiveRequest.context 结构异常，跳过")
        else:
            cprops = context.setdefault("properties", OrderedDict())
            for key, value in PROACTIVE_CONTEXT_EXTRA.items():
                if key not in cprops:
                    cprops[key] = value
                    changes.append(f"ProactiveRequest.context.{key}")

    if not changes:
        print("[OK] 契约已包含全部字段，无需修改")
    else:
        print(f"[PATCH] 新增 {len(changes)} 项：")
        for item in changes:
            print(f"        + {item}")

    if check_only:
        print("（--check 模式，未写入）")
        return 0 if not changes else 1

    if changes:
        backup = canonical.with_suffix(".json.bak")
        shutil.copy2(canonical, backup)
        canonical.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
        print(f"[OK] 已写入 {canonical.name}（备份 {backup.name}）")

    # --- 4. 同步镜像 ---
    if mirror.exists():
        shutil.copy2(canonical, mirror)
        same = canonical.read_bytes() == mirror.read_bytes()
        print(f"[{'OK' if same else 'FAIL'}] 镜像已同步 app/contracts/openapi.json"
              f"（逐字一致={same}）")
    else:
        print(f"[WARN] 镜像不存在，跳过：{mirror}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=None)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]
    raise SystemExit(patch(root, args.check))


if __name__ == "__main__":
    main()
