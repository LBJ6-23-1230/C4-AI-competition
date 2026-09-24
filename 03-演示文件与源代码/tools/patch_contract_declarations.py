# -*- coding: utf-8 -*-
"""契约声明层补全：让 `contracts/openapi.json` 不再"实现比声明更宽"。

## 背景

2026-09-22 的契约一致性只读审计（见 docs/28）给出的结论是：

    骨架层健康（28 path / 32 operation 与后端路由逐条对得上、
    16 个 errorCode 有 15 个可达、真源与镜像同哈希），
    但**响应码声明层不健康** —— 存在系统性的"实现比声明更宽"。

本脚本把实测到的真实行为**补进契约**，消除那类偏差。

## 只改声明，不改实现

每一条补充都先经实跑探测确认（见脚本末尾的 PROBES 说明），
确保"声明 == 实际返回"。**没有任何一条是顺手加的猜测**。

## 字节保真

契约必须与 `app/contracts/openapi.json` 逐字节一致，且 `.gitattributes`
对本文件设了 `-text`（不做换行符转换）。因此这里全程手工控制编码：

* UTF-8 **无 BOM**
* 换行 **CRLF**
* `json.dumps(..., ensure_ascii=False, indent=2)`（经往返验证可字节级还原）
* 需要"改注释"的地方一律改 `description` 字段，不引入 JSON 注释

用法：

    python tools/patch_contract_declarations.py            # 应用
    python tools/patch_contract_declarations.py --check    # 只报告差异
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "openapi.json"
MIRROR = ROOT / "app" / "contracts" / "openapi.json"

#: 版本头参数名。后端 `app/__init__.py` 的 `require_contract_version()`
#: 只在这个头**存在且不等于**当前版本时返回 409；不带头则放行。
VERSION_HEADER = "X-API-Contract-Version"

PROBES = """
本次补声明逐条的实测依据（全部由 Flask test_client 实跑得到）：

  GET  /                          -> 200  keys=[auth, contractVersion, layers, llm, service]
  GET  /health                    -> 200  keys=[status]
  GET  /api/agent/health          -> 200  keys=[baseUrl, contractVersion, llm_ready, model, provider, status]
  GET  /api/agent/history         -> 200  keys=[history, userId]
  DELETE /api/agent/history       -> 200  keys=[status, userId]
  GET  /api/agent/user-data       -> 200  keys=[candidates, courses, users, wrong_questions]

  GET  /api/v1/exercises/{setId}?count=abc  -> 400 BAD_REQUEST
  GET  /api/v1/exercises/{setId}?count=1    -> 200  exercises 截断为 1 条（原为静默忽略）

  POST /api/v1/auth/register（重复手机号）  -> 409 CONFLICT

  POST /api/v1/workflows（新建）finalAction -> None
  GET  /api/v1/profiles/{id}    examDate    -> None

  带 X-API-Contract-Version: api-contract-v0.3 -> 200
  带 X-API-Contract-Version: api-contract-v0.2 -> 409 CONTRACT_VERSION_MISMATCH
  不带头                                      -> 200（放行，故声明为 optional）

  LLM_FALLBACK：全后端 .py 静态扫描 **0 处**引用 -> 死枚举值
"""


def load(path: Path) -> dict:
    return json.loads(path.read_bytes().decode("utf-8-sig"))


def dump(path: Path, obj: dict) -> bytes:
    """按契约既有格式写出（UTF-8 无 BOM + CRLF）。"""
    text = json.dumps(obj, ensure_ascii=False, indent=2)
    data = text.replace("\n", "\r\n").encode("utf-8")
    path.write_bytes(data)
    return data


def _ref(name: str) -> dict:
    return {"$ref": f"#/components/schemas/{name}"}


def _json_response(schema: dict, description: str = "") -> dict:
    entry: dict = {"description": description or "成功"}
    entry["content"] = {"application/json": {"schema": schema}}
    return entry


def _ensure_error_response(operation: dict, code: str, description: str) -> bool:
    """给某个 operation 补一个错误响应声明；已存在则返回 False。"""
    responses = operation.setdefault("responses", {})
    if code in responses:
        return False
    responses[code] = _json_response(_ref("ErrorResponse"), description)
    return True


def main() -> int:
    check_only = "--check" in sys.argv
    obj = load(CONTRACT)
    paths = obj["paths"]
    schemas = obj["components"]["schemas"]
    changes: list[str] = []

    # ---------------------------------------------------------------- 版本头参数
    parameters = obj["components"].setdefault("parameters", {})
    if "ContractVersionHeader" not in parameters:
        parameters["ContractVersionHeader"] = {
            "name": VERSION_HEADER,
            "in": "header",
            "required": False,
            "schema": {"type": "string"},
            "description": (
                "接口契约版本闸门。**可选**：不带头时后端放行；"
                "带上但值不等于当前版本时返回 409 CONTRACT_VERSION_MISMATCH。"
                "当前版本见 info.version。"
            ),
        }
        changes.append("components.parameters 新增 ContractVersionHeader（声明原本不存在的版本闸门）")

    # 把版本头挂到 /api/v1/** 的所有 operation 上（与后端闸门的作用范围一致）。
    for path, item in paths.items():
        if not path.startswith("/api/v1/"):
            continue
        for method, operation in item.items():
            if method not in ("get", "post", "put", "patch", "delete"):
                continue
            if not isinstance(operation, dict):
                continue
            params = operation.setdefault("parameters", [])
            if any(isinstance(p, dict) and p.get("$ref", "").endswith("ContractVersionHeader")
                   for p in params):
                continue
            params.append({"$ref": "#/components/parameters/ContractVersionHeader"})
    changes.append("/api/v1/** 的每个 operation 挂上 ContractVersionHeader（可选）")

    # ---------------------------------------------------------------- 全局 405
    # 后端 `app/__init__.py` 专门把 405 从 HTML 改成统一 JSON 错误体，
    # 联调脚本也断言了该行为，但契约里 "405" 出现 0 次。
    for path, item in paths.items():
        for method, operation in item.items():
            if method not in ("get", "post", "put", "patch", "delete"):
                continue
            if isinstance(operation, dict):
                _ensure_error_response(
                    operation, "405",
                    "请求方法不被该路径支持（后端统一返回 JSON 错误体，而非 HTML）")
    changes.append("所有 operation 补声明 405（后端已专门实现统一 JSON 错误体）")

    # ---------------------------------------------------------------- register 409
    register = paths.get("/api/v1/auth/register", {}).get("post")
    if isinstance(register, dict):
        if _ensure_error_response(register, "409", "该手机号已注册（errorCode=CONFLICT）"):
            changes.append("POST /api/v1/auth/register 补声明 409 CONFLICT（实测重复手机号返回 409）")

    # ---------------------------------------------------------------- exercises 查询参数与 400
    ex_set = paths.get("/api/v1/exercises/{setId}", {}).get("get")
    if isinstance(ex_set, dict):
        params = ex_set.setdefault("parameters", [])
        declared = {p.get("name") for p in params if isinstance(p, dict)}
        wanted = [
            ("knowledgePointId", "按知识点过滤。与 difficulty/excludeExerciseId 任一存在时走筛选路径。"),
            ("difficulty", "按难度过滤（如 easy / medium / hard）。"),
            ("count", "返回题目数量上限，必须为正整数；非整数返回 400。缺省取 3。"),
            ("excludeExerciseId", "要排除的题目 ID。可重复传递以排除多题。"),
        ]
        for name, desc in wanted:
            if name in declared:
                continue
            entry: dict = {"name": name, "in": "query", "required": False,
                           "schema": {"type": "string"} if name != "count" else {"type": "integer"},
                           "description": desc}
            if name == "excludeExerciseId":
                entry["schema"] = {"type": "array", "items": {"type": "string"}}
                entry["style"] = "form"
                entry["explode"] = True
            params.append(entry)
        if _ensure_error_response(ex_set, "400", "count 非正整数等参数错误（errorCode=BAD_REQUEST）"):
            changes.append("GET /api/v1/exercises/{setId} 补声明 400")
        changes.append("GET /api/v1/exercises/{setId} 补声明 4 个实际在用的 query 参数"
                       "（knowledgePointId / difficulty / count / excludeExerciseId）")

    # ---------------------------------------------------------------- knowledge-bases 400
    kb_list = paths.get("/api/v1/knowledge-bases", {}).get("get")
    if isinstance(kb_list, dict):
        if _ensure_error_response(kb_list, "400", "userId 等查询参数超出长度上限（errorCode=BAD_REQUEST）"):
            changes.append("GET /api/v1/knowledge-bases 补声明 400（超长 userId 实测返回 400）")

    # ---------------------------------------------------------------- 可空字段
    wf_status = schemas.get("WorkflowStatusResponse")
    if isinstance(wf_status, dict):
        final_action = (wf_status.get("properties") or {}).get("finalAction")
        if isinstance(final_action, dict) and not final_action.get("nullable"):
            final_action["nullable"] = True
            changes.append("WorkflowStatusResponse.finalAction 标记 nullable（实测新会话返回 null）")

    profile = schemas.get("LearnerProfile")
    if isinstance(profile, dict):
        exam_date = (profile.get("properties") or {}).get("examDate")
        if isinstance(exam_date, dict) and not exam_date.get("nullable"):
            exam_date["nullable"] = True
            changes.append("LearnerProfile.examDate 标记 nullable（实测新用户返回 null）")

    # ---------------------------------------------------------------- 死枚举值
    error_schema = schemas.get("ErrorResponse")
    if isinstance(error_schema, dict):
        enum = ((error_schema.get("properties") or {}).get("errorCode") or {}).get("enum")
        if isinstance(enum, list) and "LLM_FALLBACK" in enum:
            enum.remove("LLM_FALLBACK")
            changes.append("ErrorResponse.errorCode 移除死枚举值 LLM_FALLBACK"
                           "（全后端 .py 静态扫描 0 处引用，从不返回）")

    # ---------------------------------------------------------------- 5 个未声明端点
    if "/health" not in paths:
        paths["/health"] = {"get": {
            "summary": "存活探针",
            "description": "最轻量的存活检查，仅返回 status。供负载均衡/脚本轮询使用。",
            "responses": {"200": _json_response(
                {"type": "object", "required": ["status"],
                 "properties": {"status": {"type": "string", "example": "ok"}}}, "服务存活")},
        }}
        changes.append("补声明 GET /health（已实现未声明）")

    if "/" not in paths:
        paths["/"] = {"get": {
            "summary": "服务自述",
            "description": "返回服务名、契约版本、分层说明与 LLM 配置概览。供人工核对部署是否正确。",
            "responses": {"200": _json_response(
                {"type": "object",
                 "properties": {
                     "service": {"type": "string"}, "contractVersion": {"type": "string"},
                     "layers": {"type": "array", "items": {"type": "string"}},
                     "llm": {"type": "object"}, "auth": {"type": "object"}}}, "服务自述")},
        }}
        changes.append("补声明 GET /（已实现未声明）")

    if "/api/agent/health" not in paths:
        paths["/api/agent/health"] = {"get": {
            "summary": "对话层健康检查",
            "description": (
                "前端「接口环境」页的连通性探针。**刻意不做契约版本校验** —— "
                "否则前端在版本不匹配时会把 409 误判成「后端不可用」。"
            ),
            "responses": {"200": _json_response(
                {"type": "object", "required": ["status", "llm_ready"],
                 "properties": {
                     "status": {"type": "string"}, "llm_ready": {"type": "boolean"},
                     "provider": {"type": "string"}, "model": {"type": "string"},
                     "baseUrl": {"type": "string"}, "contractVersion": {"type": "string"}}},
                "对话层状态")},
        }}
        changes.append("补声明 GET /api/agent/health（已实现未声明）")

    if "/api/agent/history" not in paths:
        paths["/api/agent/history"] = {
            "get": {
                "summary": "读取当前身份的对话历史",
                "description": "按身份隔离（已登录用登录身份）。联调脚本用它验证跨用户隔离。",
                "responses": {"200": _json_response(
                    {"type": "object", "required": ["userId", "history"],
                     "properties": {"userId": {"type": "string"},
                                    "history": {"type": "array", "items": {"type": "object"}}}},
                    "对话历史")},
            },
            "delete": {
                "summary": "清空当前身份的对话历史",
                "responses": {"200": _json_response(
                    {"type": "object", "required": ["userId", "status"],
                     "properties": {"userId": {"type": "string"}, "status": {"type": "string"}}},
                    "已清空")},
            },
        }
        changes.append("补声明 GET|DELETE /api/agent/history（已实现未声明，且被联调脚本当隔离性证据使用）")

    if "/api/agent/user-data" not in paths:
        paths["/api/agent/user-data"] = {"get": {
            "summary": "读取当前身份的全部业务数据",
            "description": "供前端启动时一次性拉取用户/课程/候选人/错题。",
            "responses": {"200": _json_response(
                {"type": "object",
                 "properties": {"users": {"type": "object"}, "courses": {"type": "object"},
                                "candidates": {"type": "array", "items": {"type": "object"}},
                                "wrong_questions": {"type": "array", "items": {"type": "object"}}}},
                "业务数据")},
        }}
        changes.append("补声明 GET /api/agent/user-data（已实现未声明）")

    # ---------------------------------------------------------------- 契约说明
    info = obj.setdefault("info", {})
    note = ("声明层已于 2026-09-22 按实跑结果补全：补齐 5 个已实现端点、"
            "所有 operation 的 405、register 的 409、exercises 的 4 个查询参数与 400、"
            "knowledge-bases 的 400、可空字段的 nullable、版本头参数，"
            "并移除死枚举值 LLM_FALLBACK。实现未改动。")
    if note not in str(info.get("description", "")):
        info["description"] = str(info.get("description", "")).rstrip() + " " + note
        changes.append("info.description 记录本次声明层补全")

    if check_only:
        print("变更项（--check 模式，未写入）：")
        for item in changes:
            print("  - %s" % item)
        return 0

    if not changes:
        print("契约已是最新，无需修改。")
        return 0

    # 先备份，便于人工比对
    backup = CONTRACT.with_suffix(".json.bak")
    shutil.copyfile(CONTRACT, backup)

    before = CONTRACT.stat().st_size
    data = dump(CONTRACT, obj)
    dump(MIRROR, obj)

    print("已应用 %d 项声明补全：" % len(changes))
    for item in changes:
        print("  - %s" % item)
    print()
    print("字节数: %d -> %d" % (before, len(data)))
    print("备份: %s" % backup.name)
    print()
    print(PROBES)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
