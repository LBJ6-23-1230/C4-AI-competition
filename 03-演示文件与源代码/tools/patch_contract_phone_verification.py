# -*- coding: utf-8 -*-
"""把手机号验证码接口补进 openapi.json 并同步镜像。"""

import json
import shutil
import sys
from pathlib import Path


REF_ERROR = "#/components/schemas/ErrorResponse"
REF_VERIFY_RESPONSE = "#/components/schemas/AuthLoginOrRegisterResponse"


def main() -> int:
    root = (Path(sys.argv[1]).resolve() if len(sys.argv) > 1
            else Path(__file__).resolve().parents[1])
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"

    doc = json.loads(canonical.read_text(encoding="utf-8"))
    paths = doc.setdefault("paths", {})
    schemas = doc.setdefault("components", {}).setdefault("schemas", {})
    added = []

    send_path = "/api/v1/auth/send-code"
    if send_path not in paths:
        paths[send_path] = {
            "post": {
                "summary": "发送手机号验证码（开发模式回显）",
                "description": (
                    "同号 60 秒内限发一次，滚动 24 小时最多 10 次。"
                    "未配置短信服务商时仅在非生产环境回显 devCode，"
                    "smsDelivered=false，绝不伪装已发送。"),
                "operationId": "authSendCode",
                "tags": ["auth"],
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/PhoneCodeSendRequest"}}},
                },
                "responses": {
                    "200": {
                        "description": "验证码已签发",
                        "content": {"application/json": {
                            "schema": {"$ref": "#/components/schemas/PhoneCodeSendResponse"}}},
                    },
                    "400": {
                        "description": "手机号格式错误",
                        "content": {"application/json": {"schema": {"$ref": REF_ERROR}}},
                    },
                    "429": {
                        "description": "触发重发或每日限流，或手机号处于锁定状态",
                        "content": {"application/json": {"schema": {"$ref": REF_ERROR}}},
                    },
                    "503": {
                        "description": "短信服务未接入或生产环境未配置",
                        "content": {"application/json": {"schema": {"$ref": REF_ERROR}}},
                    },
                },
            }
        }
        added.append(send_path)

    verify_path = "/api/v1/auth/verify-code"
    if verify_path not in paths:
        paths[verify_path] = {
            "post": {
                "summary": "校验验证码并登录或自动注册",
                "description": (
                    "验证码成功后立即失效；手机号已存在则登录，"
                    "不存在则创建账号并预置起始画像。"),
                "operationId": "authVerifyCode",
                "tags": ["auth"],
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {
                        "schema": {"$ref": "#/components/schemas/PhoneCodeVerifyRequest"}}},
                },
                "responses": {
                    "200": {
                        "description": "登录已有账号",
                        "content": {"application/json": {
                            "schema": {"$ref": REF_VERIFY_RESPONSE}}},
                    },
                    "201": {
                        "description": "验证码通过并新建账号",
                        "content": {"application/json": {
                            "schema": {"$ref": REF_VERIFY_RESPONSE}}},
                    },
                    "400": {
                        "description": "验证码错误、过期、已使用或参数非法",
                        "content": {"application/json": {"schema": {"$ref": REF_ERROR}}},
                    },
                    "429": {
                        "description": "手机号因连续错误被锁定",
                        "content": {"application/json": {"schema": {"$ref": REF_ERROR}}},
                    },
                },
            }
        }
        added.append(verify_path)

    if "PhoneCodeSendRequest" not in schemas:
        schemas["PhoneCodeSendRequest"] = {
            "type": "object",
            "required": ["phone"],
            "properties": {
                "phone": {
                    "type": "string",
                    "description": "11 位中国大陆手机号，支持 +86 与分隔符写法",
                }
            },
        }
        added.append("PhoneCodeSendRequest")

    if "PhoneCodeSendResponse" not in schemas:
        schemas["PhoneCodeSendResponse"] = {
            "type": "object",
            "required": [
                "phoneMasked",
                "expiresInSeconds",
                "resendAfterSeconds",
                "smsDelivered",
            ],
            "properties": {
                "phoneMasked": {"type": "string", "example": "138****0000"},
                "expiresInSeconds": {"type": "integer", "example": 300},
                "resendAfterSeconds": {"type": "integer", "example": 60},
                "smsDelivered": {
                    "type": "boolean",
                    "description": "true 才表示短信服务商已实际发送",
                },
                "devCode": {
                    "type": "string",
                    "nullable": True,
                    "description": "仅开发模式回显；生产模式绝不返回",
                },
            },
        }
        added.append("PhoneCodeSendResponse")

    if "PhoneCodeVerifyRequest" not in schemas:
        schemas["PhoneCodeVerifyRequest"] = {
            "type": "object",
            "required": ["phone", "code"],
            "properties": {
                "phone": {"type": "string"},
                "code": {
                    "type": "string",
                    "pattern": "^\\d{6}$",
                    "description": "6 位数字验证码，一次性使用",
                },
                "nickname": {
                    "type": "string",
                    "nullable": True,
                    "description": "仅首次自动注册时使用；缺省为“用户+手机号后四位”",
                },
                "grade": {
                    "type": "string",
                    "nullable": True,
                    "description": "仅首次自动注册时使用",
                },
            },
        }
        added.append("PhoneCodeVerifyRequest")

    error_schema = schemas.get("ErrorResponse", {})
    error_enum = (error_schema.get("properties", {})
                  .get("errorCode", {}).get("enum"))
    if isinstance(error_enum, list):
        for code in (
            "RATE_LIMITED",
            "DAILY_LIMIT_REACHED",
            "PHONE_LOCKED",
            "INVALID_CODE",
            "CODE_EXPIRED",
            "CODE_NOT_FOUND",
            "SMS_NOT_CONFIGURED",
            "SMS_PROVIDER_UNAVAILABLE",
        ):
            if code not in error_enum:
                error_enum.append(code)
                added.append(f"ErrorResponse.errorCode.{code}")

    register_request = schemas.get("AuthRegisterRequest", {})
    phone_property = (register_request.get("properties", {}).get("phone")
                      if isinstance(register_request, dict) else None)
    if isinstance(phone_property, dict):
        description = (
            "手机号。注册必填；生产登录应先调用 send-code + verify-code。"
            "当前 /auth/login 的免验证码手机号登录保留给演示与单机环境。")
        if phone_property.get("description") != description:
            phone_property["description"] = description
            added.append("AuthRegisterRequest.phone description")

    if not added:
        print("[OK] 契约已包含手机号验证码接口，无需修改")
    else:
        print(f"[PATCH] 新增或更新 {len(added)} 项：")
        for item in added:
            print(f"        + {item}")
        canonical.write_text(
            json.dumps(doc, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    if mirror.exists():
        shutil.copy2(canonical, mirror)
        same = canonical.read_bytes() == mirror.read_bytes()
        print(f"[{'OK' if same else 'FAIL'}] 镜像同步（逐字一致={same}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
