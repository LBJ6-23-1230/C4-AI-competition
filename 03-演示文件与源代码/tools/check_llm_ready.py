# -*- coding: utf-8 -*-
"""演示前 LLM 自检：按演示真实用到的模型各打一次调用。

退出码 0 = 全部可用；非 0 = 有模型不可用（详见输出）。

与 `_stage6/measure_tokens.py` 的分工：那个是**一次性测量**，用于估算额度；
这个是**可重复的自检**，用于每次录制 / 答辩前确认环境没变。
"""
import base64
import os
import struct
import sys
import time
import zlib

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ENV = os.path.join(ROOT, "server", "zhixue-agent-server", ".env")

from dotenv import load_dotenv

load_dotenv(ENV)

KEY = (os.getenv("DASHSCOPE_API_KEY") or "").strip()
BASE = os.getenv("LLM_BASE_URL") or "https://dashscope.aliyuncs.com/compatible-mode/v1"

if not KEY:
    print("  [X] DASHSCOPE_API_KEY 未配置 —— 聊天层会降级为确定性规则（演示可跑，但识图不可用）")
    sys.exit(1)

try:
    from openai import OpenAI
except Exception as exc:
    print("  [X] 未安装 openai 库: %r" % (exc,))
    sys.exit(1)

client = OpenAI(api_key=KEY, base_url=BASE)

print("  模型配置：")
for name in ("LLM_MODEL", "LLM_VL_MODEL", "LLM_DECISION_MODEL", "EMBED_MODEL"):
    print("    %-20s %s" % (name, os.getenv(name) or "（未配置，用代码默认值）"))
print()

failures = []


def make_png(w=320, h=140):
    """极简 PNG，用于测试识图链路（纯标准库，不依赖 Pillow）。"""
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            px = (255, 255, 255)
            for ly in (40, 80):
                if ly - 3 <= y <= ly + 3 and 30 < x < w - 30 and (x // 9) % 3 != 2:
                    px = (30, 30, 30)
            row += bytes(px)
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def classify(msg):
    for marker in ("AllocationQuota", "Arrearage", "InvalidApiKey",
                   "Model.NotExist", "Throttling", "DataInspectionFailed"):
        if marker in msg:
            return marker
    return ""


# --- 1) 文本 / 决策模型 ---
for role, model in (("自然语言层", os.getenv("LLM_MODEL")),
                    ("识图模型", os.getenv("LLM_VL_MODEL")),
                    ("工作流决策层", os.getenv("LLM_DECISION_MODEL"))):
    if not model:
        print("  [!] %-12s 未配置，跳过" % role)
        continue
    try:
        t0 = time.time()
        client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": "回复：ok"}],
            max_tokens=8, timeout=30,
        )
        print("  [OK] %-12s %-22s %.2fs" % (role, model, time.time() - t0))
    except Exception as exc:
        tag = classify(str(exc))
        print("  [X]  %-12s %-22s %s" % (role, model, tag or type(exc).__name__))
        failures.append((role, model, tag, str(exc)[:180]))

# --- 2) 识图链路（带图，真正压测 VL） ---
vl = os.getenv("LLM_VL_MODEL") or os.getenv("LLM_MODEL")
if vl:
    try:
        b64 = base64.b64encode(make_png()).decode("ascii")
        r = client.chat.completions.create(
            model=vl,
            messages=[{"role": "user", "content": [
                {"type": "image_url",
                 "image_url": {"url": "data:image/png;base64,%s" % b64}},
                {"type": "text", "text": "图里有几行文字？只回数字。"},
            ]}],
            max_tokens=16, timeout=60,
        )
        u = r.usage
        print("  [OK] %-12s %-22s tokens=%s" % ("识图链路", vl, u.total_tokens))
    except Exception as exc:
        tag = classify(str(exc))
        print("  [X]  %-12s %-22s %s" % ("识图链路", vl, tag or type(exc).__name__))
        failures.append(("识图链路", vl, tag, str(exc)[:180]))

# --- 3) embedding（知识库语义检索依赖） ---
emb = os.getenv("EMBED_MODEL") or "text-embedding-v3"
try:
    r = client.embeddings.create(model=emb, input="二叉树遍历", timeout=30)
    print("  [OK] %-12s %-22s 维度=%d" % ("语义检索", emb, len(r.data[0].embedding)))
except Exception as exc:
    tag = classify(str(exc))
    print("  [!] %-12s %-22s %s（语义检索会降级为关键词）"
          % ("语义检索", emb, tag or type(exc).__name__))

print()
if failures:
    print("  失败明细：")
    for role, model, tag, msg in failures:
        print("    %s / %s" % (role, model))
        print("      %s" % msg)
    sys.exit(1)
sys.exit(0)
