# -*- coding: utf-8 -*-
"""把既有测试里的注册调用补上手机号。

背景：`_PHONE_REQUIRED = True` 之后，注册必须带手机号。
既有测试都是在"昵称即身份"的时代写的，需要同步更新。

做法：给每个测试文件注入一个 `_phone()` 辅助函数（用计数器保证唯一，
因为手机号现在有唯一约束），然后把 `{"nickname": ...}` 形态的注册体
补上 `"phone": _phone()`。

这是**预期的测试更新**，不是掩盖问题：手机号从可选变必填是产品决策。
"""

import re
import sys
from pathlib import Path

HELPER = '''

# --------------------------------------------------------------------------- 测试辅助
_PHONE_SEQ = {"n": 0}


def _phone() -> str:
    """生成唯一且合法的测试手机号（手机号现在有唯一约束）。"""
    _PHONE_SEQ["n"] += 1
    return f"1380000{_PHONE_SEQ['n']:04d}"
'''

# 匹配 register / login-or-register 的 json body，补 phone
PATTERNS = [
    # json={"nickname": X, "grade": Y}
    (re.compile(r'json=\{"nickname":\s*([^,}]+),\s*"grade":\s*([^}]+)\}'),
     r'json={"nickname": \1, "grade": \2, "phone": _phone()}'),
    # json={"nickname": X}
    (re.compile(r'json=\{"nickname":\s*([^,}]+)\}'),
     r'json={"nickname": \1, "phone": _phone()}'),
]


def patch(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    original = text
    changed = 0

    for pattern, replacement in PATTERNS:
        text, count = pattern.subn(replacement, text)
        changed += count

    if changed and "_PHONE_SEQ" not in text:
        # 插到第一个 def 之前
        match = re.search(r"\ndef ", text)
        if match:
            text = text[:match.start()] + HELPER + text[match.start():]
        else:
            text += HELPER

    if text != original:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    tests = Path(sys.argv[1]) / "tests"
    total = 0
    for name in ("test_auth.py", "test_auth_login.py", "test_input_guards.py"):
        path = tests / name
        if not path.exists():
            print(f"  [SKIP] {name} 不存在")
            continue
        count = patch(path)
        total += count
        print(f"  [PATCH] {name}: 补了 {count} 处 phone")
    print(f"合计 {total} 处")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
