# -*- coding: utf-8 -*-
"""把知识库第一期的接口补进 openapi.json 并同步镜像。

对应实现：`app/api/knowledge.py` + `app/agent/knowledge.py`
对应设计：`docs/12-知识库设计方案.md`
"""

import json
import shutil
import sys
from pathlib import Path

REF_ERR = "#/components/schemas/ErrorResponse"


def _json_response(schema_ref: str, description: str) -> dict:
    return {"description": description,
            "content": {"application/json": {"schema": {"$ref": schema_ref}}}}


def _kb_id_param() -> dict:
    return {"name": "kbId", "in": "path", "required": True, "schema": {"type": "string"}}


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"

    doc = json.loads(canonical.read_text(encoding="utf-8"))
    paths = doc.setdefault("paths", {})
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    added: list[str] = []

    # ---------------------------------------------------------------- schemas
    new_schemas = {
        "KnowledgeBase": {
            "type": "object",
            "required": ["kbId", "userId", "courseName", "name"],
            "properties": {
                "kbId": {"type": "string"},
                "userId": {"type": "string"},
                "courseName": {"type": "string"},
                "name": {"type": "string"},
                "description": {"type": "string"},
                "documentCount": {"type": "integer"},
                "chunkCount": {"type": "integer"},
                "knowledgePoints": {"type": "array", "items": {"type": "string"}},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
            },
        },
        "KnowledgeDocument": {
            "type": "object",
            "required": ["documentId", "kbId", "userId", "fileName", "status"],
            "properties": {
                "documentId": {"type": "string"},
                "kbId": {"type": "string"},
                "userId": {"type": "string"},
                "fileName": {"type": "string"},
                "mimeType": {"type": "string"},
                "sizeBytes": {"type": "integer"},
                "status": {"type": "string", "enum": ["ready", "failed"]},
                "statusMessage": {"type": "string",
                                  "description": "失败时的可读原因；成功时为空字符串"},
                "charCount": {"type": "integer"},
                "chunkCount": {"type": "integer"},
                "knowledgePoints": {"type": "array", "items": {"type": "string"}},
                "errorPointCandidates": {"type": "array", "items": {"type": "string"}},
                "uploadedAt": {"type": "string"},
                "parsedAt": {"type": "string"},
            },
        },
        "KnowledgeChunkHit": {
            "type": "object",
            "required": ["chunkId", "documentId", "text", "score"],
            "properties": {
                "chunkId": {"type": "string"},
                "documentId": {"type": "string"},
                "fileName": {"type": "string"},
                "headingPath": {"type": "string",
                                "description": "标题层级路径，如「第3章 > 3.2.3 后序遍历」；"
                                               "引用标注依赖它"},
                "text": {"type": "string"},
                "knowledgePoints": {"type": "array", "items": {"type": "string"}},
                "score": {"type": "number"},
            },
        },
        "KnowledgeBaseListResponse": {
            "type": "object", "required": ["knowledgeBases", "total"],
            "properties": {"knowledgeBases": {"type": "array",
                                              "items": {"$ref": "#/components/schemas/KnowledgeBase"}},
                           "total": {"type": "integer"}},
        },
        "KnowledgeDocumentListResponse": {
            "type": "object", "required": ["kbId", "documents", "total"],
            "properties": {"kbId": {"type": "string"},
                           "documents": {"type": "array",
                                         "items": {"$ref": "#/components/schemas/KnowledgeDocument"}},
                           "total": {"type": "integer"}},
        },
        "KnowledgeBaseDetailResponse": {
            "allOf": [{"$ref": "#/components/schemas/KnowledgeBase"}],
        },
        "KnowledgeSearchRequest": {
            "type": "object", "required": ["query"],
            "properties": {
                "query": {"type": "string", "maxLength": 200},
                "topK": {"type": "integer", "minimum": 1, "maximum": 20},
                "knowledgePointId": {"type": "string", "nullable": True},
                "userId": {"type": "string", "nullable": True},
            },
        },
        "KnowledgeSearchResponse": {
            "type": "object", "required": ["kbId", "query", "hits", "totalScanned", "retrievalMode"],
            "properties": {
                "kbId": {"type": "string"},
                "query": {"type": "string"},
                "hits": {"type": "array",
                         "items": {"$ref": "#/components/schemas/KnowledgeChunkHit"}},
                "totalScanned": {"type": "integer"},
                "retrievalMode": {"type": "string", "enum": ["keyword+tag", "vector"],
                                  "description": "当前检索方式。第一期是 keyword+tag，"
                                                 "第三期引入向量检索后为 vector。诚实标注便于答辩解释。"},
            },
        },
        "KnowledgeDocumentUploadRequest": {
            "type": "object", "required": ["fileName", "contentBase64"],
            "properties": {
                "fileName": {"type": "string", "maxLength": 200,
                             "description": "只取最后一段，服务端会剥离路径部分"},
                "contentBase64": {"type": "string", "description": "文件内容 base64，上限 8MB"},
                "mimeType": {"type": "string", "nullable": True},
                "sizeBytes": {"type": "integer", "nullable": True},
                "userId": {"type": "string", "nullable": True},
            },
        },
        "KnowledgeBaseCreateRequest": {
            "type": "object", "required": ["courseName", "name"],
            "properties": {
                "courseName": {"type": "string", "maxLength": 60},
                "name": {"type": "string", "maxLength": 60},
                "description": {"type": "string", "nullable": True},
                "userId": {"type": "string", "nullable": True},
            },
        },
    }
    for name, schema in new_schemas.items():
        if name not in schemas:
            schemas[name] = schema
            added.append(f"schema {name}")

    # ---------------------------------------------------------------- paths
    kb_list = "/api/v1/knowledge-bases"
    if kb_list not in paths:
        paths[kb_list] = {
            "get": {
                "summary": "列出当前用户的知识库", "operationId": "listKnowledgeBases",
                "tags": ["knowledge"],
                "parameters": [{"name": "userId", "in": "query", "required": False,
                                "schema": {"type": "string"}}],
                "responses": {"200": _json_response(
                    "#/components/schemas/KnowledgeBaseListResponse", "知识库列表")},
            },
            "post": {
                "summary": "创建知识库（按课程）", "operationId": "createKnowledgeBase",
                "tags": ["knowledge"],
                "requestBody": {"required": True, "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/KnowledgeBaseCreateRequest"}}}},
                "responses": {
                    "201": _json_response("#/components/schemas/KnowledgeBase", "已创建"),
                    "400": _json_response(REF_ERR, "参数错误"),
                    "409": _json_response(REF_ERR, "同名知识库已存在"),
                },
            },
        }
        added.append(kb_list)

    kb_detail = "/api/v1/knowledge-bases/{kbId}"
    if kb_detail not in paths:
        paths[kb_detail] = {
            "get": {
                "summary": "知识库详情（含文档列表）", "operationId": "getKnowledgeBase",
                "tags": ["knowledge"], "parameters": [_kb_id_param()],
                "responses": {
                    "200": _json_response("#/components/schemas/KnowledgeBaseDetailResponse", "详情"),
                    "404": _json_response(REF_ERR, "知识库不存在"),
                },
            },
            "delete": {
                "summary": "删除知识库（连同文档与切片）", "operationId": "deleteKnowledgeBase",
                "tags": ["knowledge"], "parameters": [_kb_id_param()],
                "responses": {"200": _json_response(REF_ERR, "已删除"),
                              "404": _json_response(REF_ERR, "知识库不存在")},
            },
        }
        added.append(kb_detail)

    kb_docs = "/api/v1/knowledge-bases/{kbId}/documents"
    if kb_docs not in paths:
        paths[kb_docs] = {
            "get": {
                "summary": "列出知识库下的文档", "operationId": "listKnowledgeDocuments",
                "tags": ["knowledge"], "parameters": [_kb_id_param()],
                "responses": {"200": _json_response(
                    "#/components/schemas/KnowledgeDocumentListResponse", "文档列表"),
                    "404": _json_response(REF_ERR, "知识库不存在")},
            },
            "post": {
                "summary": "上传文档并解析（第一期支持 TXT/MD/CSV/JSON）",
                "operationId": "uploadKnowledgeDocument", "tags": ["knowledge"],
                "parameters": [_kb_id_param()],
                "requestBody": {"required": True, "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/KnowledgeDocumentUploadRequest"}}}},
                "responses": {
                    "201": _json_response("#/components/schemas/KnowledgeDocument",
                                          "已受理；解析结果在 status 字段（ready / failed）"),
                    "400": _json_response(REF_ERR, "参数错误或超出上限"),
                    "404": _json_response(REF_ERR, "知识库不存在"),
                },
            },
        }
        added.append(kb_docs)

    doc_detail = "/api/v1/documents/{documentId}"
    if doc_detail not in paths:
        paths[doc_detail] = {
            "get": {
                "summary": "文档详情", "operationId": "getKnowledgeDocument",
                "tags": ["knowledge"],
                "parameters": [{"name": "documentId", "in": "path", "required": True,
                                "schema": {"type": "string"}}],
                "responses": {"200": _json_response("#/components/schemas/KnowledgeDocument", "详情"),
                              "404": _json_response(REF_ERR, "文档不存在")},
            },
            "delete": {
                "summary": "删除文档（连同其切片）", "operationId": "deleteKnowledgeDocument",
                "tags": ["knowledge"],
                "parameters": [{"name": "documentId", "in": "path", "required": True,
                                "schema": {"type": "string"}}],
                "responses": {"200": _json_response(REF_ERR, "已删除"),
                              "404": _json_response(REF_ERR, "文档不存在")},
            },
        }
        added.append(doc_detail)

    kb_search = "/api/v1/knowledge-bases/{kbId}/search"
    if kb_search not in paths:
        paths[kb_search] = {
            "post": {
                "summary": "在知识库内检索（第一期：关键词 + 标签）",
                "operationId": "searchKnowledgeBase", "tags": ["knowledge"],
                "parameters": [_kb_id_param()],
                "requestBody": {"required": True, "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/KnowledgeSearchRequest"}}}},
                "responses": {
                    "200": _json_response("#/components/schemas/KnowledgeSearchResponse", "命中片段"),
                    "400": _json_response(REF_ERR, "参数错误"),
                    "404": _json_response(REF_ERR, "知识库不存在"),
                },
            }
        }
        added.append(kb_search)

    if not added:
        print("[OK] 契约已包含知识库接口，无需修改")
    else:
        print(f"[PATCH] 新增 {len(added)} 项：")
        for item in added:
            print(f"        + {item}")
        canonical.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")

    if mirror.exists():
        shutil.copy2(canonical, mirror)
        same = canonical.read_bytes() == mirror.read_bytes()
        print(f"[{'OK' if same else 'FAIL'}] 镜像同步（逐字一致={same}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
