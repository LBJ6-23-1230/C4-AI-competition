# -*- coding: utf-8 -*-
"""把知识库**语义检索**相关字段补进 openapi.json，并同步前端镜像。

改动内容
--------
`KnowledgeSearchResponse`：

1. `retrievalMode` 枚举补入 `hybrid:semantic+keyword+tag`
   （原枚举只有 `keyword+tag` 与 `vector`，而实现实际会返回混合模式）
2. 新增 `semanticAvailable`（boolean）—— 是否具备语义检索条件（配了 Key）
3. 新增 `semanticWeight`（number）—— 本次语义分权重；降级时为 0

为什么必须补
------------
契约是项目唯一接口真相。前端 `KnowledgeBase.ets` **已经会显示**
`检索方式：${retrievalMode}`，如果契约枚举里没有 hybrid，前端契约校验器
在严格模式下会把它判成非法值；而 `semanticAvailable`/`semanticWeight`
是"是否真的在跑语义检索"的诚实依据，答辩时要能一眼看到。

只新增、不改既有字段名与既有枚举值，因此**向后兼容**。
"""

import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "contracts" / "openapi.json"
MIRROR = ROOT / "app" / "contracts" / "openapi.json"

HYBRID_MODE = "hybrid:semantic+keyword+tag"


def patch(doc: dict) -> list[str]:
    changes: list[str] = []
    schemas = doc.get("components", {}).get("schemas", {})
    target = schemas.get("KnowledgeSearchResponse")
    if target is None:
        raise SystemExit("契约里找不到 KnowledgeSearchResponse")

    props = target.setdefault("properties", {})
    required = target.setdefault("required", [])

    mode = props.setdefault("retrievalMode", {"type": "string"})
    enum = mode.setdefault("enum", [])
    if HYBRID_MODE not in enum:
        enum.append(HYBRID_MODE)
        changes.append(f"retrievalMode.enum += {HYBRID_MODE!r}")
    mode["description"] = (
        "**实际**使用的检索方式，诚实标注以便答辩解释：\n"
        "* `keyword+tag` —— 纯关键词 + 标签 + 标题层级（未配置 DASHSCOPE_API_KEY，或向量调用失败时的降级路径）\n"
        f"* `{HYBRID_MODE}` —— embedding 语义相似度与关键词分加权融合\n"
        "* `vector` —— 预留：将来若改为纯向量检索"
    )

    if "semanticAvailable" not in props:
        props["semanticAvailable"] = {
            "type": "boolean",
            "description": "是否具备语义检索条件（即是否配置了 DASHSCOPE_API_KEY）。注意它是**能力**标志，不是本次是否真的用上了。",
        }
        changes.append("+ semanticAvailable")

    if "semanticWeight" not in props:
        props["semanticWeight"] = {
            "type": "number",
            "description": "本次语义分在融合得分里的权重（0–1）。降级为纯关键词时为 0，可据此判断语义是否真的参与打分。",
        }
        changes.append("+ semanticWeight")

    for field in ("semanticAvailable", "semanticWeight"):
        if field not in required:
            required.append(field)
            changes.append(f"required += {field}")

    return changes


def main() -> int:
    if not CANONICAL.exists():
        print(f"契约真源缺失：{CANONICAL}")
        return 1
    doc = json.loads(CANONICAL.read_text(encoding="utf-8"))
    changes = patch(doc)

    if not changes:
        print("契约已包含全部改动，无需修改。")
    else:
        shutil.copy2(CANONICAL, CANONICAL.with_suffix(".json.bak"))
        CANONICAL.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"契约真源已更新（{CANONICAL.stat().st_size:,} B）:")
        for item in changes:
            print(f"  · {item}")

    # 同步镜像，保证两份逐字节一致（联调硬闸门）
    shutil.copy2(CANONICAL, MIRROR)
    same = CANONICAL.read_bytes() == MIRROR.read_bytes()
    print(f"\n镜像已同步：{MIRROR.stat().st_size:,} B，逐字节一致 = {same}")
    if not same:
        return 1
    CANONICAL.with_suffix(".json.bak").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
