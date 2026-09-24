# -*- coding: utf-8 -*-
"""补声明 `KnowledgeBaseDetailResponse.documents`（契约一致性审计 C5）。

## 问题

契约里 `KnowledgeBaseDetailResponse` 只有：

    {"allOf": [{"$ref": "#/components/schemas/KnowledgeBase"}]}

即**只有知识库自身的字段**，没有任何 `documents`。但：

* 后端 `app/api/knowledge.py:166-168` 返回 `{"documents": [...]}`（实测确认）
* 前端 `pages/KnowledgeBase.ets:113` 用 `result.data.documents ?? []` 在读它

运行时不炸（后端确实给了），但**契约无法为前端的读取背书** ——
任何按契约做 codegen / mock / 契约测试的一方都会缺这个字段，
前端知识库文档列表会变空。这类"后端有、契约无、前端在读"的三角错配，
正是审计指出的"前端消费层最薄弱"的典型。

## 做法

在 `allOf` 之后再补一个内联 schema，声明 `documents` 为文档对象数组。
不动 `KnowledgeBase` 本身（列表接口沿用它，不该带 documents）。

字节保真同 `patch_contract_declarations.py`：UTF-8 无 BOM + CRLF。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "openapi.json"
MIRROR = ROOT / "app" / "contracts" / "openapi.json"

#: 文档对象的最小可辨识形状。后端返回的字段比这多
#: （charCount / knowledgePoints / errorPointCandidates / parsedAt 等），
#: 这里只声明前端确实会读的那几个，并留 `additionalProperties: true`
#: 以免契约比实现更严（那会造成反向偏差）。
DOCUMENT_SCHEMA = {
    "type": "object",
    "required": ["documentId", "kbId", "userId", "fileName", "status"],
    "properties": {
        "documentId": {"type": "string"},
        "kbId": {"type": "string"},
        "userId": {"type": "string"},
        "fileName": {"type": "string"},
        "mimeType": {"type": "string"},
        "sizeBytes": {"type": "integer"},
        "status": {"type": "string"},
        "statusMessage": {"type": "string"},
        "charCount": {"type": "integer"},
        "chunkCount": {"type": "integer"},
        "knowledgePoints": {"type": "array", "items": {"type": "string"}},
        "errorPointCandidates": {"type": "array", "items": {"type": "string"}},
        "uploadedAt": {"type": "string"},
        "parsedAt": {"type": "string"},
    },
    "additionalProperties": True,
}


def main() -> int:
    check_only = "--check" in sys.argv
    obj = json.loads(CONTRACT.read_bytes().decode("utf-8-sig"))
    schema = obj["components"]["schemas"].get("KnowledgeBaseDetailResponse")
    if not isinstance(schema, dict):
        print("找不到 KnowledgeBaseDetailResponse，放弃。")
        return 2

    already = False
    for part in schema.get("allOf", []):
        if isinstance(part, dict) and "documents" in (part.get("properties") or {}):
            already = True
    if already:
        print("已声明 documents，无需修改。")
        return 0

    if check_only:
        print("将要补声明：KnowledgeBaseDetailResponse.documents（数组，元素为文档对象）")
        return 0

    schema.setdefault("allOf", []).append({
        "type": "object",
        "required": ["documents"],
        "properties": {
            "documents": {
                "type": "array",
                "items": DOCUMENT_SCHEMA,
                "description": ("该知识库下的文档列表。后端 `get_knowledge_base()` 会一并返回；"
                                "前端 `KnowledgeBase.ets` 据此渲染文档列表。"),
            },
        },
    })
    note = ("KnowledgeBaseDetailResponse.documents 已于 2026-09-22 补声明"
            "（后端返回、前端在读，此前契约未声明）。")
    info = obj.setdefault("info", {})
    if note not in str(info.get("description", "")):
        info["description"] = str(info.get("description", "")).rstrip() + " " + note

    text = json.dumps(obj, ensure_ascii=False, indent=2)
    data = text.replace("\n", "\r\n").encode("utf-8")
    CONTRACT.write_bytes(data)
    MIRROR.write_bytes(data)

    print("已补声明 KnowledgeBaseDetailResponse.documents")
    print("真源与镜像: %d B" % len(data))
    print("paths=%d schemas=%d" % (len(obj["paths"]), len(obj["components"]["schemas"])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
