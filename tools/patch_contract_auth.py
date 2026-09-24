# -*- coding: utf-8 -*-
"""把本轮新增的登录能力补进 openapi.json 并同步镜像。

新增：
1. `POST /api/v1/auth/login-or-register` —— 登录优先、注册兜底
2. `AuthLoginRequest.nickname` —— 支持按昵称免密登录
3. `AuthLoginOrRegisterResponse` —— 带 `created` 标志区分"登录"/"建号"
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
    added = []

    # 1) 新增 login-or-register 路径
    key = "/api/v1/auth/login-or-register"
    if key not in paths:
        paths[key] = {
            "post": {
                "summary": "登录优先，注册兜底",
                "description": ("昵称已存在则登录该账号（不新建），不存在才建号。"
                                "登录页主按钮应调此接口，避免同一昵称重复建号。"),
                "operationId": "loginOrRegister",
                "tags": ["auth"],
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/AuthRegisterRequest"}}},
                },
                "responses": {
                    "200": {"description": "登录了已有账号", "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/AuthLoginOrRegisterResponse"}}}},
                    "201": {"description": "新建了账号", "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/AuthLoginOrRegisterResponse"}}}},
                    "400": {"description": "参数错误", "content": {"application/json": {
                        "schema": {"$ref": REF_ERR}}}},
                },
            }
        }
        added.append(key)

    # 2) AuthLoginRequest 支持按昵称登录
    login_req = schemas.get("AuthLoginRequest")
    if isinstance(login_req, dict):
        props = login_req.setdefault("properties", {})
        if "nickname" not in props:
            props["nickname"] = {
                "type": "string",
                "nullable": True,
                "description": ("按昵称免密登录。与 userId/token 二选一；两者都提供时"
                                "优先按凭据恢复。昵称不是秘密，此形式仅适用于演示/单机场景。"),
            }
            login_req["required"] = []
            added.append("AuthLoginRequest.nickname")

    # 3) 新增响应 schema
    if "AuthLoginOrRegisterResponse" not in schemas:
        schemas["AuthLoginOrRegisterResponse"] = {
            "type": "object",
            "required": ["user", "token", "expiresAt", "created"],
            "properties": {
                "user": {"$ref": "#/components/schemas/AuthUser"},
                "token": {"type": "string"},
                "expiresAt": {"type": "string", "format": "date-time"},
                "created": {"type": "boolean",
                            "description": "true=本次新建账号；false=登录了已有账号"},
            },
        }
        added.append("AuthLoginOrRegisterResponse")

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
