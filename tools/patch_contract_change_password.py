# -*- coding: utf-8 -*-
"""把「修改 / 首次设置密码」接口补进 openapi.json 并同步镜像。

新增：
1. `POST /api/v1/auth/change-password` —— 需 Bearer token
2. `AuthChangePasswordRequest` / `AuthChangePasswordResponse`

声明口径与同文件的 `/auth/logout` 保持一致（`BearerAuth` + `ContractVersionHeader`
+ `#/components/responses/Unauthorized`）。
"""

import json
import shutil
import sys
from pathlib import Path

REF_ERR = "#/components/schemas/ErrorResponse"


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"

    doc = json.loads(canonical.read_text(encoding="utf-8"))
    paths = doc.setdefault("paths", {})
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    components = doc["components"]
    added = []

    # 1) 请求体
    if "AuthChangePasswordRequest" not in schemas:
        schemas["AuthChangePasswordRequest"] = {
            "type": "object",
            "required": ["newPassword"],
            "properties": {
                "oldPassword": {
                    "type": "string",
                    "nullable": True,
                    "description": ("原密码。账号**已设过密码时必须提供且正确**，"
                                    "否则 401；账号从未设过密码（验证码建号）时"
                                    "可省略，此时属于「首次设置密码」。"),
                },
                "newPassword": {
                    "type": "string",
                    "minLength": 6,
                    "maxLength": 72,
                    "description": "新密码，6–72 位。服务端只保存加盐哈希，明文不落库、不回传。",
                },
            },
        }
        added.append("AuthChangePasswordRequest")

    # 2) 响应体
    if "AuthChangePasswordResponse" not in schemas:
        schemas["AuthChangePasswordResponse"] = {
            "type": "object",
            "required": ["status", "hasPassword", "wasFirstTime"],
            "properties": {
                "status": {"type": "string", "enum": ["ok"]},
                "hasPassword": {"type": "boolean",
                                "description": "改完之后该账号是否已设置密码（本接口后恒为 true）"},
                "wasFirstTime": {"type": "boolean",
                                 "description": "本次是否为「首次设置密码」而非「修改已有密码」"},
            },
        }
        added.append("AuthChangePasswordResponse")

    # 3) 路径
    key = "/api/v1/auth/change-password"
    if key not in paths:
        paths[key] = {
            "post": {
                "summary": "修改 / 首次设置密码",
                "description": ("需 Bearer token。账号已设密码时必须提供正确的 oldPassword；"
                                "从未设过密码（验证码建号）时为首次设置，无需旧密码。"
                                "本接口不吊销其它会话。"),
                "operationId": "authChangePassword",
                "security": [{"BearerAuth": []}],
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/AuthChangePasswordRequest"}}},
                },
                "responses": {
                    "200": {"description": "已修改 / 已设置", "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/AuthChangePasswordResponse"}}}},
                    "400": {"description": "参数错误（新密码长度等）", "content": {"application/json": {
                        "schema": {"$ref": REF_ERR}}}},
                    "401": {"$ref": "#/components/responses/Unauthorized"},
                    "405": {"description": "请求方法不被该路径支持（后端统一返回 JSON 错误体，而非 HTML）",
                            "content": {"application/json": {
                                "schema": {"$ref": REF_ERR}}}},
                },
                "parameters": [{"$ref": "#/components/parameters/ContractVersionHeader"}],
            }
        }
        added.append(key)

    # 4) 响应里绝不能出现密码字段 —— 显式钉一条
    for schema_name in ("AuthChangePasswordRequest", "AuthChangePasswordResponse"):
        for prop in schemas[schema_name]["properties"]:
            if prop in ("password", "passwordHash"):
                print(f"[FAIL] {schema_name} 里出现了明文密码字段")
                return 1

    if not added:
        print("[OK] 契约已包含全部内容，无需修改")
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
        if not same:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
