# -*- coding: utf-8 -*-
"""补声明 `LegacyChatResponse.card.summary`（契约一致性审计 P1-2）。

## 问题

前端 `AgentBridge.parseCard()` 一直读 `card['summary']` 并渲染在卡片描述行上
（`ChatMain.ets` / `ChatBubble.ets`），但：

* 后端 `build_card()` 只输出 `type/title/actionLabel/targetPage`（已修）
* 契约 `LegacyChatResponse.card.properties` 也只声明那 4 个 + `sessionId`

于是联机模式下卡片描述恒为空，而离线 Fixture 的数据带 summary ——
呈现"离线好看、联机消失"的假象。后端侧已于本次修复补上 `summary`，
这里把**契约**补齐，否则按契约做 codegen / mock 的一方仍会缺这个字段。

## 字节保真

同 `patch_contract_declarations.py`：UTF-8 无 BOM + CRLF。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "openapi.json"
MIRROR = ROOT / "app" / "contracts" / "openapi.json"


def main() -> int:
    check_only = "--check" in sys.argv
    obj = json.loads(CONTRACT.read_bytes().decode("utf-8-sig"))

    card = (obj["components"]["schemas"]
            .get("LegacyChatResponse", {})
            .get("properties", {})
            .get("card"))
    if not isinstance(card, dict):
        print("找不到 LegacyChatResponse.card，放弃。")
        return 2

    props = card.setdefault("properties", {})
    if "summary" in props:
        print("已声明 card.summary，无需修改。")
        return 0

    if check_only:
        print("将要补声明：LegacyChatResponse.card.summary（string）")
        return 0

    props["summary"] = {
        "type": "string",
        "description": ("卡片的一行描述，由前端渲染在卡片标题下方。"
                        "后端 `build_card()` 按意图给出；缺失会导致描述行空白。"),
    }
    note = ("LegacyChatResponse.card.summary 已于 2026-09-22 补声明"
            "（前端在读、后端已补返回，此前两边都缺）。")
    info = obj.setdefault("info", {})
    if note not in str(info.get("description", "")):
        info["description"] = str(info.get("description", "")).rstrip() + " " + note

    text = json.dumps(obj, ensure_ascii=False, indent=2)
    data = text.replace("\n", "\r\n").encode("utf-8")
    CONTRACT.write_bytes(data)
    MIRROR.write_bytes(data)

    print("已补声明 LegacyChatResponse.card.summary")
    print("真源与镜像: %d B" % len(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
