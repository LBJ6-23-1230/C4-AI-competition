# -*- coding: utf-8 -*-
"""把**密码登录**能力补进 openapi.json 并同步镜像。

背景：`/api/v1/auth/register`、`/login`、`/login-or-register` 都已接受并校验
`password`（服务端只存 Werkzeug 生成的加盐哈希，明文不落库、不回传），
但契约里 `password` 出现 **0 次** —— 而契约是本项目宣称的"唯一依据"，
声明层不跟上就又是一次漂移（此前审计刚把 C1~C10 一批声明补齐）。

新增/修正：
1. `AuthRegisterRequest.password` —— 可选，6–72 位
2. `AuthLoginRequest.password` —— 可选，配合 phone / nickname
3. 修正 `AuthLoginRequest.nickname` 的描述：原文写「按昵称**免密**登录」，
   与现在的行为**相反**（设过密码的账号必须校验密码）
"""

import json
import shutil
import sys
from pathlib import Path


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    canonical = root / "contracts" / "openapi.json"
    mirror = root / "app" / "contracts" / "openapi.json"

    doc = json.loads(canonical.read_text(encoding="utf-8"))
    schemas = doc["components"]["schemas"]
    added = []

    # 1) 注册请求：可选密码
    register_props = schemas["AuthRegisterRequest"]["properties"]
    if "password" not in register_props:
        register_props["password"] = {
            "type": "string",
            "nullable": True,
            "minLength": 6,
            "maxLength": 72,
            "description": (
                "可选。设置后该账号可用密码登录；服务端只保存 Werkzeug 生成的"
                "加盐哈希，明文不落库也不回传。未设置（例如走验证码建号）时，"
                "该账号的密码登录会被如实拒绝并提示改用验证码登录 —— "
                "不会接受任意密码。"),
        }
        added.append("AuthRegisterRequest.password")

    # 2) 登录请求：可选密码
    login_props = schemas["AuthLoginRequest"]["properties"]
    if "password" not in login_props:
        login_props["password"] = {
            "type": "string",
            "nullable": True,
            "description": (
                "配合 phone / nickname 使用。账号设过密码时**必须**正确，"
                "否则返回 401 UNAUTHORIZED；从未设过密码的账号会被拒绝并提示"
                "改用「验证码登录」。"),
        }
        added.append("AuthLoginRequest.password")

    # 3) 修正昵称描述：不再"免密"
    nickname = login_props.get("nickname")
    if isinstance(nickname, dict) and "免密" in str(nickname.get("description", "")):
        nickname["description"] = (
            "按昵称登录。与 userId/token 二选一；两者都提供时优先按凭据恢复。"
            "账号设过密码时需同时提供 password。昵称本身不是秘密，"
            "此形式仅适用于演示/单机场景。")
        added.append("AuthLoginRequest.nickname 描述修正（不再声称免密）")

    # 4) 响应里的 AuthUser 不该出现 password —— 显式钉一条，防止将来误加
    auth_user = schemas.get("AuthUser", {}).get("properties", {})
    if "password" in auth_user or "passwordHash" in auth_user:
        print("[FAIL] AuthUser 里出现了密码字段 —— 响应绝不能回传密码")
        return 1

    if not added:
        print("[OK] 契约已包含全部内容，无需修改")
    else:
        print(f"[PATCH] 新增/修正 {len(added)} 项：")
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
