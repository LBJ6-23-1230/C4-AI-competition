# -*- coding: utf-8 -*-
"""把手机号注册与华为账号登录补进 openapi.json 并同步镜像。

新增：
1. `AuthRegisterRequest.phone` / `AuthLoginOrRegisterRequest.phone`（必填）
2. `AuthLoginRequest.phone`（按手机号登录）
3. `AuthUser.phoneMasked` / `hasPhone`（脱敏，不回传完整号码）
4. `AuthHuaweiLoginRequest` + `POST /api/v1/auth/login-with-huawei`
"""

import json
import shutil
import sys
from pathlib import Path

REF_ERR = "#/components/schemas/ErrorResponse"


def _json_response(ref: str, description: str) -> dict:
    return {"description": description,
            "content": {"application/json": {"schema": {"$ref": ref}}}}


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"

    doc = json.loads(canonical.read_text(encoding="utf-8"))
    paths = doc.setdefault("paths", {})
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    added: list[str] = []

    phone_prop = {
        "type": "string",
        "description": ("手机号。**注册必填**（唯一身份标识，后端做格式校验与唯一约束）；"
                        "登录时可选，填了会优先按手机号匹配。"
                        "当前版本不做短信验证码校验，见 docs/11 §5.2。"),
    }
    masked_prop = {
        "type": "string",
        "description": "脱敏手机号（138****0000）。服务端**不回传完整号码**。",
    }
    has_phone_prop = {"type": "boolean", "description": "是否已绑定手机号"}

    def ensure_prop(schema_name: str, prop: str, value: dict) -> None:
        schema = schemas.get(schema_name)
        if not isinstance(schema, dict):
            return
        props = schema.setdefault("properties", {})
        if prop not in props:
            props[prop] = value
            added.append(f"{schema_name}.{prop}")

    # --- 1. 各请求体加 phone ---
    ensure_prop("AuthRegisterRequest", "phone", phone_prop)
    ensure_prop("AuthLoginOrRegisterRequest", "phone", phone_prop)
    ensure_prop("AuthLoginRequest", "phone", dict(phone_prop, description=(
        "按手机号登录。与 userId/token、nickname 三选一；"
        "分派优先级：凭据 > 手机号 > 昵称。")))

    # 注册：phone 变为必填
    register_req = schemas.get("AuthRegisterRequest")
    if isinstance(register_req, dict):
        required = register_req.setdefault("required", ["nickname"])
        if "phone" not in required:
            required.append("phone")
            added.append("AuthRegisterRequest.required+=phone")

    # --- 2. AuthUser 加脱敏字段 ---
    ensure_prop("AuthUser", "phoneMasked", masked_prop)
    ensure_prop("AuthUser", "hasPhone", has_phone_prop)

    # --- 3. 华为账号登录 ---
    if "AuthHuaweiLoginRequest" not in schemas:
        schemas["AuthHuaweiLoginRequest"] = {
            "type": "object",
            "required": ["openId"],
            "properties": {
                "openId": {"type": "string",
                           "description": "华为账号 OpenID（应用内唯一）。由客户端 "
                                          "@kit.AccountKit 的 LoginWithHuaweiIDRequest 取得。"},
                "unionId": {"type": "string", "nullable": True,
                            "description": "华为账号 UnionID（开发者账号内唯一），保留用于多应用打通"},
                "nickname": {"type": "string", "nullable": True},
                "grade": {"type": "string", "nullable": True},
            },
        }
        added.append("AuthHuaweiLoginRequest")

    hw_path = "/api/v1/auth/login-with-huawei"
    if hw_path not in paths:
        paths[hw_path] = {
            "post": {
                "summary": "华为账号一键登录（登录优先，注册兜底）",
                "description": ("客户端用 @kit.AccountKit 取得 OpenID 后调用本接口。"
                                "首次登录自动建号，用户无需填昵称/手机号/验证码。"
                                "⚠️ 本接口**不校验 OpenID 真伪**（需服务端调华为接口验签），"
                                "当前定位为演示可用、生产需补验签，见 docs/13。"),
                "operationId": "loginWithHuawei", "tags": ["auth"],
                "requestBody": {"required": True, "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/AuthHuaweiLoginRequest"}}}},
                "responses": {
                    "200": _json_response("#/components/schemas/AuthLoginOrRegisterResponse",
                                          "登录了已有账号"),
                    "201": _json_response("#/components/schemas/AuthLoginOrRegisterResponse",
                                          "首次登录，已自动建号"),
                    "400": _json_response(REF_ERR, "缺少 openId"),
                },
            }
        }
        added.append(hw_path)

    if not added:
        print("[OK] 契约已包含内容，无需修改")
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
