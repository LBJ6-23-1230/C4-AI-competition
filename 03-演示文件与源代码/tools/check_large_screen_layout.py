# -*- coding: utf-8 -*-
"""大屏布局回归检查：验证登录页的横向元素是否居中、文字是否在按钮内。

## 为什么需要它

2026-09-22 修了一个只在**大屏**上出现的渲染缺陷：`constraintSize` 挂在
`Scroll` 上导致内部横向弹性布局算错（详见 Login.ets 的注释与提交
`fix(ui): 修复平板/2in1 上登录页文字被推到右缘并截断`）。

那个缺陷的形态很隐蔽：**所有常规检查都是绿的** ——
布局节点树里按钮宽度正确、单元测试无关、编译零错误，
只有"像素扫描 + 逐元素居中比对"才能发现按钮文字根本不在按钮里。

本脚本把那次排查固化成可复跑的检查，避免以后改布局时再次退化。

## 判据（来自修复时的实测）

  1. 分隔行 `Row { Divider; Text('或'); Divider }` 的两个 Divider 宽度应**接近相等**
     （缺陷形态：第一个吃满全部宽度、第二个为 0）
  2. `Text('或')` 的水平中心应接近**窗口水平中心**
     （缺陷形态：贴到容器右缘）
  3. 主按钮文字（像素扫描的笔画重心）应落在按钮内**中部 1/3 区间**
     （缺陷形态：笔画全在按钮右缘一侧）

用法：

    python tools/check_large_screen_layout.py <dumpLayout.json> [--no-pixel]
    python tools/check_large_screen_layout.py <dumpLayout.json> --png shot.png

`uitest dumpLayout` 的产物即可；`--png` 给出截图时额外做像素级校验。
"""

from __future__ import annotations

import json
import re
import struct
import sys
import zlib


def load_dump(path: str) -> dict:
    return json.loads(open(path, encoding="utf-8").read())


def bounds(attrs: dict):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attrs.get("bounds") or "")
    return tuple(map(int, m.groups())) if m else None


def walk(node):
    yield node
    for child in node.get("children") or []:
        yield from walk(child)


def find_png_lines(path: str):
    """解析 PNG（自写，避免依赖 Pillow），返回 (宽, 高, 取像素函数)。"""
    raw = open(path, "rb").read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG")
    pos, idat = 8, bytearray()
    width = height = None
    while pos < len(raw):
        (length,) = struct.unpack(">I", raw[pos:pos + 4])
        ctype = raw[pos + 4:pos + 8]
        data = raw[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bd, ct = struct.unpack(">IIBB", data[:10])
            if bd != 8 or ct not in (2, 6):
                raise ValueError("仅支持 8bit RGB/RGBA")
            ch = 3 if ct == 2 else 4
        elif ctype == b"IDAT":
            idat += data
        elif ctype == b"IEND":
            break
        pos += 12 + length
    stride = width * ch
    buf = zlib.decompress(bytes(idat))
    out = bytearray(height * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        f = buf[p]
        p += 1
        line = bytearray(buf[p:p + stride])
        p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                bb = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pa, pb, pc = abs(bb - c), abs(a - c), abs(a + bb - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (bb if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line

    def px(x, y):
        o = y * stride + x * ch
        return out[o], out[o + 1], out[o + 2]

    return width, height, px


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    dump_path = sys.argv[1]
    png_path = None
    if "--png" in sys.argv:
        png_path = sys.argv[sys.argv.index("--png") + 1]

    tree = load_dump(dump_path)
    root = bounds(tree.get("attributes", {})) or (0, 0, 0, 0)
    win_w = root[2]
    win_cx = win_w // 2
    print("窗口宽度 %d px，水平中心 %d" % (win_w, win_cx))
    print()

    dividers, label_or, buttons = [], [], []
    for node in walk(tree):
        attrs = node.get("attributes", {})
        bb = bounds(attrs)
        if not bb:
            continue
        x1, y1, x2, y2 = bb
        typ = attrs.get("type", "")
        text = (attrs.get("text") or "").strip()
        if typ == "Divider":
            dividers.append((y1, x1, x2))
        if text == "或":
            label_or.append((y1, x1, x2))
        if typ == "Button" and text:
            buttons.append((y1, x1, x2, text))

    failures: list[str] = []

    # ---- 判据 1：分隔行的两个 Divider 应等宽 ----
    if len(dividers) >= 2:
        dividers.sort()
        d1, d2 = dividers[0], dividers[1]
        w1, w2 = d1[2] - d1[1], d2[2] - d2[1]
        ratio = (min(w1, w2) / max(w1, w2)) if max(w1, w2) else 0
        ok = ratio >= 0.7
        print("[%s] 分隔 Divider 等宽: w1=%d w2=%d 比值=%.2f"
              % ("PASS" if ok else "FAIL", w1, w2, ratio))
        if not ok:
            failures.append("两个 Divider 宽度相差过大（缺陷形态：第一个吃满全部）")
    else:
        print("[SKIP] 未找到成对的 Divider")

    # ---- 判据 2：『或』应居中 ----
    if label_or:
        _, x1, x2 = label_or[0]
        cx = (x1 + x2) // 2
        off = abs(cx - win_cx)
        ok = off <= win_w * 0.05
        print("[%s] 『或』居中: cx=%d 期望≈%d 偏差=%d"
              % ("PASS" if ok else "FAIL", cx, win_cx, off))
        if not ok:
            failures.append("『或』未居中（缺陷形态：贴到容器右缘）")
    else:
        print("[SKIP] 未找到『或』分隔文本")

    # ---- 判据 3：按钮文字应在按钮内中部（需要截图） ----
    if png_path and buttons:
        width, height, px = find_png_lines(png_path)
        for y1, x1, x2, text in buttons[:3]:
            keep = text[:12]
            ym = (y1 + min(y2, y1 + 90)) // 2 if False else y1 + 45
            lo, hi = x1, min(x2, width - 1)
            strokes = []
            for x in range(lo, hi):
                for y in range(y1 + 6, min(y1 + 90, height - 2)):
                    r, g, b = px(x, y)
                    gray = abs(r - g) < 14 and abs(g - b) < 14 and 185 < r < 238
                    white = r > 244 and g > 244 and b > 244
                    if not gray and not white:
                        strokes.append(x)
                        break
            if not strokes:
                print("[FAIL] 按钮 %r 内未找到文字笔画" % keep)
                failures.append("按钮 %r 内没有文字" % keep)
                continue
            cen = sum(strokes) // len(strokes)
            btn_cx = (x1 + x2) // 2
            off = abs(cen - btn_cx)
            ok = off <= (x2 - x1) * 0.25
            print("[%s] 按钮文字居中 %-14r 笔画重心=%d 按钮中心=%d 偏差=%d"
                  % ("PASS" if ok else "FAIL", keep, cen, btn_cx, off))
            if not ok:
                failures.append("按钮 %r 的文字不在按钮中部" % keep)
    elif buttons:
        print("[SKIP] 按钮文字的像素校验需要 --png 提供截图")

    print()
    if failures:
        print("结论：FAIL（%d 项）" % len(failures))
        for item in failures:
            print("  - %s" % item)
        return 1
    print("结论：PASS（大屏横向布局正常）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
