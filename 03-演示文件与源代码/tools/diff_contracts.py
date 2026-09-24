# -*- coding: utf-8 -*-
"""对比契约真源与镜像两份 openapi.json（用于契约漂移审计）。

用法：

    python tools/diff_contracts.py            # 自动定位工程根
    python tools/diff_contracts.py <工程根>    # 指定工程根

⚠️ 原先的默认值是 `Path(__file__).parent`（即 `tools/` 目录），
而两份契约都在**工程根**下 —— 于是不带参数运行必然
`FileNotFoundError: tools/contracts/openapi.json`，工具等于坏的。
现改为默认取 `tools/` 的上一级。
"""
import hashlib
import json
import sys
from pathlib import Path


def flatten(node, prefix="", out=None):
    if out is None:
        out = {}
    if isinstance(node, dict):
        for key, value in node.items():
            flatten(value, f"{prefix}.{key}" if prefix else str(key), out)
    elif isinstance(node, list):
        out[prefix] = json.dumps(node, ensure_ascii=False, sort_keys=True)
    else:
        out[prefix] = node
    return out


def main():
    # 默认工程根 = tools/ 的上一级（原先错写成 tools/ 自身）
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    left = root / "contracts" / "openapi.json"
    right = root / "app" / "contracts" / "openapi.json"

    for candidate in (left, right):
        if not candidate.exists():
            print(f"找不到契约文件: {candidate}")
            return 2

    raw_a = left.read_bytes()
    raw_b = right.read_bytes()
    a = json.loads(raw_a.decode("utf-8-sig"))
    b = json.loads(raw_b.decode("utf-8-sig"))

    print(f"A = {left}")
    print(f"B = {right}")
    print(f"info.version  A={a.get('info', {}).get('version')}  B={b.get('info', {}).get('version')}")
    print(f"paths  A={len(a.get('paths', {}))}  B={len(b.get('paths', {}))}")
    print("-" * 74)

    # 字节级保真检查：契约要求真源与镜像**逐字节相同**
    # （.gitattributes 对本文件设了 -text，换行符不做转换，故可直接比字节）。
    sha_a = hashlib.sha256(raw_a).hexdigest()
    sha_b = hashlib.sha256(raw_b).hexdigest()
    # ⚠️ 裸 LF 必须**在 f-string 之外**算好：
    # Python 3.12 起 f-string 表达式内部不允许出现反斜杠，
    # 直接写成 `raw_a.count(b'\n')` 会 `SyntaxError`；
    # 而写成 `b'\\n'` 又会变成"反斜杠+n"两个字符，得到恒为 0 的假结果
    # （本工具第一版就踩了这个坑，报出"裸 LF: 3"的误报）。
    crlf_a = raw_a.count(b"\r\n")
    lf_a = raw_a.count(b"\n") - crlf_a
    crlf_b = raw_b.count(b"\r\n")
    lf_b = raw_b.count(b"\n") - crlf_b
    bom_a = raw_a[:3] == b"\xef\xbb\xbf"
    bom_b = raw_b[:3] == b"\xef\xbb\xbf"
    print("字节级校验：")
    print(f"   A {len(raw_a):>7} B  sha256 {sha_a[:32]}")
    print(f"   B {len(raw_b):>7} B  sha256 {sha_b[:32]}")
    print(f"   逐字节一致: {raw_a == raw_b}")
    print(f"   BOM: A={bom_a}  B={bom_b}")
    print(f"   CRLF: A={crlf_a}  B={crlf_b}    裸LF: A={lf_a}  B={lf_b}")
    if lf_a or lf_b:
        print("   ⚠️ 存在裸 LF —— 该文件在 .gitattributes 里设了 -text，"
              "混合换行会导致 clone 后字节数变化，必须统一为 CRLF")
    print("-" * 74)

    fa, fb = flatten(a), flatten(b)
    only_a = sorted(set(fa) - set(fb))
    only_b = sorted(set(fb) - set(fa))
    changed = sorted(k for k in set(fa) & set(fb) if fa[k] != fb[k])

    print(f"仅在 A 中存在的字段 ({len(only_a)}):")
    for key in only_a[:60]:
        print(f"   + {key} = {str(fa[key])[:90]}")
    print(f"\n仅在 B 中存在的字段 ({len(only_b)}):")
    for key in only_b[:60]:
        print(f"   - {key} = {str(fb[key])[:90]}")
    print(f"\n取值不同的字段 ({len(changed)}):")
    for key in changed[:60]:
        print(f"   ~ {key}")
        print(f"       A: {str(fa[key])[:150]}")
        print(f"       B: {str(fb[key])[:150]}")

    paths_a = set(a.get("paths", {}))
    paths_b = set(b.get("paths", {}))
    print(f"\n接口路径差异：")
    print(f"   仅 A 暴露: {sorted(paths_a - paths_b)}")
    print(f"   仅 B 暴露: {sorted(paths_b - paths_a)}")

    # 结论行，便于脚本化判断
    identical = raw_a == raw_b
    print()
    print("结论：" + ("PASS（真源与镜像逐字节一致）" if identical else "FAIL（两份契约不一致）"))
    return 0 if identical else 1


if __name__ == "__main__":
    raise SystemExit(main())
