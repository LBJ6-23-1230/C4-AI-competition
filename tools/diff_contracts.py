# -*- coding: utf-8 -*-
"""对比 liantiao2 中两份 openapi.json 的差异（用于契约漂移审计）。"""
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
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    left = root / "contracts" / "openapi.json"
    right = root / "app" / "contracts" / "openapi.json"

    a = json.loads(left.read_text(encoding="utf-8"))
    b = json.loads(right.read_text(encoding="utf-8"))

    print(f"A = {left}")
    print(f"B = {right}")
    print(f"info.version  A={a.get('info', {}).get('version')}  B={b.get('info', {}).get('version')}")
    print(f"paths  A={len(a.get('paths', {}))}  B={len(b.get('paths', {}))}")
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


if __name__ == "__main__":
    main()
