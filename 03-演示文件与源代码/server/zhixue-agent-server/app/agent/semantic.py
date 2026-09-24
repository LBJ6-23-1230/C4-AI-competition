# -*- coding: utf-8 -*-
"""知识库语义检索（embedding）+ 关键词混合打分。

为什么要有这一层
----------------
第一期的检索是**纯关键词 + 标签**（`app/agent/knowledge.py:score_chunk`），
实测一个明显短板：**同义表达完全命中不到**。

例如课程资料里写的是"二叉树的后序遍历"，用户问"二叉树后序怎么遍历"能中，
但问"如何按左右根的顺序访问节点"就搜不到 —— 因为 2-gram 交集的权重再高，
也需要字面重合。

因此增加一层语义相似度：用 DashScope 的 `text-embedding` 把查询与切片
各自编码成向量，按余弦相似度打分，再与关键词分**加权融合**：

    final = (1 - w) * keyword_score + w * semantic_score      w = SEMANTIC_WEIGHT

设计原则（与项目其它地方一致）
------------------------------
1. **诚实降级**：没有 `DASHSCOPE_API_KEY`、或调用失败时，**不伪装**成语义检索的结果，
   而是退回纯关键词，并在响应的 `retrievalMode` 里如实标注
   （`keyword+tag` vs `hybrid:semantic+keyword+tag`）。
2. **不静默改变既有行为**：`SEMANTIC_WEIGHT` 生效的前提是能真的拿到向量。
3. **可测试**：`encode` 允许注入，便于在无网络环境下用确定性假向量验证融合逻辑。
4. **有界**：对切片数设上限，避免一次检索打爆 embedding 配额。
"""

from __future__ import annotations

import json
import math
import os
from collections.abc import Callable
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

#: 语义分在最终得分里的权重。0.6 表示"以语义为主、关键词为辅" ——
#: 中文短查询下 embedding 通常比 2-gram 更稳，但保留关键词分可以兜住
#: 术语精确匹配（例如 `HTTP 404`、`O(n log n)` 这类 embedding 容易糊掉的串）。
SEMANTIC_WEIGHT = 0.6

#: 单次检索最多编码多少个切片。切片很多时按关键词分预筛，避免超配额。
MAX_EMBED_CHUNKS = 200

#: embedding 模型与维度上限（DashScope text-embedding-v3 支持 1024）
DEFAULT_EMBED_MODEL = "text-embedding-v3"

_TIMEOUT_SECONDS = 8.0


def semantic_available() -> bool:
    """是否具备真正做语义检索的条件（仅看 Key，不发请求）。"""
    return bool((os.getenv("DASHSCOPE_API_KEY") or "").strip())


def _base_url() -> str:
    return (os.getenv("LLM_BASE_URL")
            or "https://dashscope.aliyuncs.com/compatible-mode/v1").rstrip("/")


def _embed_model() -> str:
    return os.getenv("EMBED_MODEL", DEFAULT_EMBED_MODEL)


def encode(texts: list[str]) -> list[list[float]] | None:
    """调用 `POST {base}/embeddings` 批量取向量。

    返回 `None` 表示**不可用**（未配置 / 调用失败 / 返回形状异常）——
    调用方据此降级，绝不抛异常打断检索。
    """
    cleaned = [t for t in texts if isinstance(t, str) and t.strip()]
    if not cleaned or not semantic_available():
        return None

    payload = {"model": _embed_model(), "input": cleaned, "encoding_format": "float"}
    request = Request(
        f"{_base_url()}/embeddings",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {os.environ['DASHSCOPE_API_KEY'].strip()}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=_TIMEOUT_SECONDS) as response:
            body = json.loads(response.read().decode("utf-8"))
        rows = body["data"]
        # 兼容两种返回顺序：带 index 的（按 index 排序）与顺序即序的
        if rows and isinstance(rows[0], dict) and "index" in rows[0]:
            rows = sorted(rows, key=lambda item: item["index"])
        vectors = [row["embedding"] for row in rows]
        if len(vectors) != len(cleaned):
            return None
        return vectors
    except (HTTPError, KeyError, IndexError, TypeError, ValueError, OSError):
        return None


def cosine(left: list[float], right: list[float]) -> float:
    """余弦相似度；维度不一致或零向量返回 0.0（不抛异常）。"""
    if not left or not right or len(left) != len(right):
        return 0.0
    dot = norm_l = norm_r = 0.0
    for a, b in zip(left, right):
        dot += a * b
        norm_l += a * a
        norm_r += b * b
    if norm_l <= 0.0 or norm_r <= 0.0:
        return 0.0
    return dot / (math.sqrt(norm_l) * math.sqrt(norm_r))


def normalize_cosine(value: float) -> float:
    """把余弦 [-1, 1] 线性映射到 [0, 1]，便于与关键词分同尺度加权。

    文本 embedding 的余弦通常落在 [0.2, 1.0]，直接当 0-1 分会系统性偏低，
    导致语义分被关键词分淹没。
    """
    return max(0.0, min(1.0, (value + 1.0) / 2.0))


def blend(keyword_score: float, semantic_score: float | None,
          weight: float = SEMANTIC_WEIGHT) -> float:
    """融合关键词分与语义分。

    `semantic_score is None`（语义不可用）→ 原样返回关键词分，
    保证降级路径与第一期行为**完全一致**。
    """
    if semantic_score is None:
        return round(keyword_score, 4)
    w = max(0.0, min(1.0, weight))
    return round((1.0 - w) * keyword_score + w * semantic_score, 4)


def rerank(chunks: list[dict[str, Any]], query: str, keyword_scores: dict[str, float],
           encode_fn: Callable[[list[str]], list[list[float]] | None] | None = None,
           ) -> tuple[dict[str, float], str]:
    """用语义相似度重排候选切片。

    返回 `(chunkId -> 融合分, 实际使用的检索模式)`。

    `keyword_scores` 由调用方传入（即 `score_chunk` 的结果），本函数只负责
    取向量、算相似度、加权融合 —— 这样关键词逻辑仍留在 `knowledge.py` 一处，
    不产生第二份"真相"。
    """
    if not chunks:
        return {}, "keyword+tag"
    if not query.strip():
        return dict(keyword_scores), "keyword+tag"

    encoder = encode_fn or encode
    # 只对关键词分最高的前 MAX_EMBED_CHUNKS 个切片取向量，控制配额与延迟
    ordered = sorted(chunks, key=lambda c: (-keyword_scores.get(c.get("chunkId", ""), 0.0),
                                            str(c.get("chunkId", ""))))[:MAX_EMBED_CHUNKS]
    texts = [str(c.get("text", ""))[:2000] for c in ordered]
    try:
        vectors = encoder([query, *texts])
    except Exception:  # noqa: BLE001
        # 编码器抛异常（网络中断、配额耗尽、DNS 失败…）绝不能把检索打成 5xx。
        # 内置的 `encode()` 自己已经吞掉了常见异常，但 `encode_fn` 是可注入的，
        # 因此这里再兜一层 —— 降级必须是无条件的。
        return dict(keyword_scores), "keyword+tag"
    if not vectors or len(vectors) != len(texts) + 1:
        return dict(keyword_scores), "keyword+tag"

    query_vector, chunk_vectors = vectors[0], vectors[1:]
    fused: dict[str, float] = {}
    for chunk, vector in zip(ordered, chunk_vectors):
        chunk_id = str(chunk.get("chunkId", ""))
        semantic = normalize_cosine(cosine(query_vector, vector))
        fused[chunk_id] = blend(keyword_scores.get(chunk_id, 0.0), semantic)

    # 未参与语义编码的切片保留关键词分
    for chunk in chunks:
        chunk_id = str(chunk.get("chunkId", ""))
        fused.setdefault(chunk_id, round(keyword_scores.get(chunk_id, 0.0), 4))

    return fused, "hybrid:semantic+keyword+tag"
