# -*- coding: utf-8 -*-
"""知识库语义检索（embedding 混合打分）测试。

覆盖三件事：
1. **纯函数正确性** —— 余弦、归一化、加权融合
2. **诚实降级** —— 没有 Key / 调用失败时，模式必须如实标注 `keyword+tag`，
   分数与第一期**完全一致**（不能悄悄改变既有行为）
3. **语义确实起作用** —— 用确定性假向量证明"字面不重合但语义相近"的切片
   能被排上来（这正是第一期纯关键词做不到的）

用假 encoder 而不是真调 DashScope：CI 无网络无 Key，且我们希望断言的是
**融合逻辑**而不是模型的输出质量。
"""

from __future__ import annotations

import pytest

from app.agent import knowledge, semantic


# ===========================================================================
# 1) 纯函数
# ===========================================================================
def test_cosine_identical_vectors_is_one():
    assert semantic.cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) == pytest.approx(1.0)


def test_cosine_orthogonal_is_zero():
    assert semantic.cosine([1.0, 0.0], [0.0, 1.0]) == pytest.approx(0.0)


def test_cosine_opposite_is_minus_one():
    assert semantic.cosine([1.0, 0.0], [-1.0, 0.0]) == pytest.approx(-1.0)


@pytest.mark.parametrize("left,right", [
    ([], [1.0]),                      # 空向量
    ([1.0], []),                      # 空向量
    ([1.0, 2.0], [1.0]),              # 维度不一致
    ([0.0, 0.0], [1.0, 1.0]),         # 零向量
])
def test_cosine_degenerate_inputs_return_zero_without_raising(left, right):
    """退化输入必须返回 0.0 而不是抛异常 —— 检索不能因为一条脏向量就 500。"""
    assert semantic.cosine(left, right) == 0.0


def test_normalize_cosine_maps_to_unit_interval():
    assert semantic.normalize_cosine(-1.0) == pytest.approx(0.0)
    assert semantic.normalize_cosine(0.0) == pytest.approx(0.5)
    assert semantic.normalize_cosine(1.0) == pytest.approx(1.0)
    # 越界输入被夹住
    assert semantic.normalize_cosine(5.0) == 1.0
    assert semantic.normalize_cosine(-9.0) == 0.0


def test_blend_without_semantic_returns_keyword_score_unchanged():
    """降级路径必须与第一期行为**逐位一致**。"""
    for value in (0.0, 0.3, 0.6667, 1.0):
        assert semantic.blend(value, None) == round(value, 4)


def test_blend_weights_semantic_and_keyword():
    # w=0.6: 0.4*keyword + 0.6*semantic
    assert semantic.blend(1.0, 0.0, weight=0.6) == pytest.approx(0.4)
    assert semantic.blend(0.0, 1.0, weight=0.6) == pytest.approx(0.6)
    assert semantic.blend(1.0, 1.0, weight=0.6) == pytest.approx(1.0)
    assert semantic.blend(0.5, 0.5, weight=0.6) == pytest.approx(0.5)


def test_blend_weight_is_clamped():
    assert semantic.blend(1.0, 0.0, weight=5.0) == pytest.approx(0.0)
    assert semantic.blend(0.0, 1.0, weight=-3.0) == pytest.approx(0.0)


def test_semantic_available_follows_api_key(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    assert semantic.semantic_available() is False
    monkeypatch.setenv("DASHSCOPE_API_KEY", "sk-test")
    assert semantic.semantic_available() is True
    monkeypatch.setenv("DASHSCOPE_API_KEY", "   ")
    assert semantic.semantic_available() is False, "空白 Key 不算已配置"


def test_encode_returns_none_without_key(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    assert semantic.encode(["任意文本"]) is None


def test_encode_returns_none_on_empty_input(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "sk-test")
    assert semantic.encode(["", "   "]) is None


# ===========================================================================
# 2) rerank：融合与降级
# ===========================================================================
def _chunks():
    return [
        {"chunkId": "c1", "text": "二叉树后序遍历的顺序是左右根", "headingPath": "二叉树 > 后序遍历",
         "knowledgePoints": ["binary-tree-postorder"]},
        {"chunkId": "c2", "text": "图的深度优先搜索使用栈", "headingPath": "图 > DFS",
         "knowledgePoints": ["graph-dfs"]},
        {"chunkId": "c3", "text": "先访问左子树再访问右子树最后访问根节点",
         "headingPath": "二叉树 > 遍历方式", "knowledgePoints": ["binary-tree-postorder"]},
    ]


def test_rerank_falls_back_to_keyword_when_encoder_unavailable():
    chunks = _chunks()
    keyword_scores = {"c1": 0.8, "c2": 0.1, "c3": 0.2}
    fused, mode = semantic.rerank(chunks, "后序遍历", keyword_scores,
                                  encode_fn=lambda texts: None)
    assert mode == "keyword+tag"
    assert fused == keyword_scores


def test_rerank_reports_hybrid_mode_when_encoder_works():
    """语义相近但**关键词分很低**的切片必须被提上来 —— 这正是第一期做不到的。

    构造：`c3` 字面几乎不重合（关键词分 0.05），但语义向量与查询几乎同向；
    `c2` 关键词分略高（0.20）但语义无关。融合后 `c3` 应当反超 `c2`。
    """
    chunks = _chunks()
    keyword_scores = {"c1": 0.80, "c2": 0.20, "c3": 0.05}

    def fake_encoder(texts):
        # texts[0] 是 query；随后依次对应 chunks（按关键词分降序：c1, c2, c3）
        return [
            [1.0, 0.0],    # query
            [0.9, 0.1],    # c1：与 query 很近
            [0.0, 1.0],    # c2：与 query 正交（语义无关）
            [1.0, 0.0],    # c3：与 query 完全同向（语义极近）
        ]

    fused, mode = semantic.rerank(chunks, "左右根的顺序", keyword_scores,
                                  encode_fn=fake_encoder)
    assert mode == "hybrid:semantic+keyword+tag"
    # c3 关键词分只有 0.05，但语义满分 → 融合后必须超过关键词分 0.20 的 c2
    assert fused["c3"] > fused["c2"], f"语义近似的切片没有被提上来：{fused}"
    assert fused["c1"] > fused["c3"], "关键词+语义都最好的 c1 应仍在最前"
    # 排序结果（不是绝对分值）才是检索契约：按融合分降序
    assert list(sorted(fused, key=lambda k: -fused[k])) == ["c1", "c3", "c2"]


def test_rerank_returns_hybrid_even_with_no_chunks():
    fused, mode = semantic.rerank([], "查询", {}, encode_fn=lambda t: [[1.0]])
    assert fused == {}
    assert mode == "keyword+tag"


def test_rerank_handles_mismatched_vector_count():
    """encoder 返回的向量数不对（服务端截断/异常）→ 降级而不是崩。"""
    chunks = _chunks()
    keyword_scores = {"c1": 0.5, "c2": 0.2, "c3": 0.1}
    fused, mode = semantic.rerank(chunks, "查询", keyword_scores,
                                  encode_fn=lambda texts: [[1.0, 0.0]])
    assert mode == "keyword+tag"
    assert fused == keyword_scores


def test_rerank_keeps_chunks_beyond_embed_limit():
    """超过 MAX_EMBED_CHUNKS 的切片不参与语义编码，但**不能丢**。"""
    chunks = [{"chunkId": f"c{i}", "text": f"文本{i}"} for i in range(5)]
    keyword_scores = {f"c{i}": 0.5 - i * 0.01 for i in range(5)}

    def fake_encoder(texts):
        return [[1.0, 0.0]] + [[1.0, 0.0] for _ in texts[1:]]

    original_limit = semantic.MAX_EMBED_CHUNKS
    try:
        semantic.MAX_EMBED_CHUNKS = 2
        fused, mode = semantic.rerank(chunks, "查询", keyword_scores, encode_fn=fake_encoder)
    finally:
        semantic.MAX_EMBED_CHUNKS = original_limit

    assert mode == "hybrid:semantic+keyword+tag"
    assert set(fused) == set(keyword_scores), "未参与语义编码的切片被丢掉了"


# ===========================================================================
# 3) knowledge.search 的契约
# ===========================================================================
def test_search_returns_tuple_and_keyword_mode_without_key(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    hits, mode = knowledge.search(_chunks(), "后序遍历", top_k=3)
    assert mode == "keyword+tag"
    assert hits, "纯关键词也应当能命中"
    assert hits[0]["chunkId"] == "c1"


def test_search_scores_are_descending(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    hits, _ = knowledge.search(_chunks(), "二叉树 遍历", top_k=3)
    scores = [hit["score"] for hit in hits]
    assert scores == sorted(scores, reverse=True)


def test_search_empty_query_returns_empty(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    hits, mode = knowledge.search(_chunks(), "   ")
    assert hits == []
    assert mode == "keyword+tag"


def test_search_use_semantic_false_skips_embedding(monkeypatch):
    """显式关闭语义时不应触碰 embedding 通路。"""
    monkeypatch.setenv("DASHSCOPE_API_KEY", "sk-test")
    called = {"n": 0}

    def exploding_encoder(texts):
        called["n"] += 1
        raise AssertionError("use_semantic=False 时不应调用 encoder")

    monkeypatch.setattr(semantic, "encode", exploding_encoder)
    hits, mode = knowledge.search(_chunks(), "后序遍历", top_k=3, use_semantic=False)
    assert mode == "keyword+tag"
    assert called["n"] == 0
    assert hits


# ===========================================================================
# 4) API 层的诚实标注
# ===========================================================================
def _make_kb(client):
    # `courseName` 与 `name` 都是必填（漏了会 400，拿不到 kbId）
    kb = client.post("/api/v1/knowledge-bases",
                     json={"courseName": "数据结构", "name": "数据结构复习"},
                     headers={"X-API-Contract-Version": "api-contract-v0.3"}).get_json()
    return kb["kbId"]


def _upload(client, kb_id: str, text: str):
    import base64

    client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                json={"fileName": "笔记.md",
                      "contentBase64": base64.b64encode(text.encode("utf-8")).decode()},
                headers={"X-API-Contract-Version": "api-contract-v0.3"})


def test_api_reports_keyword_mode_and_semantic_unavailable(tmp_path, monkeypatch):
    """无 Key 时：模式是 keyword+tag，且明确告知语义能力不可用。"""
    from app import create_app

    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    client = create_app(tmp_path / "kb.json").test_client()
    headers = {"X-API-Contract-Version": "api-contract-v0.3"}
    kb_id = _make_kb(client)
    _upload(client, kb_id, "# 二叉树\n\n## 后序遍历\n\n后序遍历的顺序是左右根。\n")

    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序遍历"}, headers=headers).get_json()
    assert body["retrievalMode"] == "keyword+tag"
    assert body["semanticAvailable"] is False
    assert body["semanticWeight"] == 0.0
    assert body["hits"], "降级后仍应能检索到内容"


def test_api_reports_hybrid_mode_when_encoder_available(tmp_path, monkeypatch):
    """配置 Key 且 encoder 可用时：模式如实变成 hybrid，并给出权重。"""
    from app import create_app

    monkeypatch.setenv("DASHSCOPE_API_KEY", "sk-test")
    monkeypatch.setattr(semantic, "encode",
                        lambda texts: [[1.0, 0.0]] + [[1.0, 0.0] for _ in texts[1:]])

    client = create_app(tmp_path / "kb-hybrid.json").test_client()
    headers = {"X-API-Contract-Version": "api-contract-v0.3"}
    kb_id = _make_kb(client)
    _upload(client, kb_id, "# 二叉树\n\n## 后序遍历\n\n后序遍历的顺序是左右根。\n")

    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序遍历"}, headers=headers).get_json()
    assert body["retrievalMode"] == "hybrid:semantic+keyword+tag"
    assert body["semanticAvailable"] is True
    assert body["semanticWeight"] == pytest.approx(semantic.SEMANTIC_WEIGHT)
    assert body["hits"]


def test_api_degrades_gracefully_when_embedding_request_fails(tmp_path, monkeypatch):
    """encoder 抛异常（网络问题）→ 仍返回关键词结果，不 500。"""
    from app import create_app

    monkeypatch.setenv("DASHSCOPE_API_KEY", "sk-test")

    def boom(texts):
        raise OSError("network down")

    monkeypatch.setattr(semantic, "encode", boom)
    client = create_app(tmp_path / "kb-fail.json").test_client()
    headers = {"X-API-Contract-Version": "api-contract-v0.3"}
    kb_id = _make_kb(client)
    _upload(client, kb_id, "# 二叉树\n\n## 后序遍历\n\n后序遍历的顺序是左右根。\n")

    response = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                           json={"query": "后序遍历"}, headers=headers)
    assert response.status_code == 200, "embedding 失败不应把检索打成 5xx"
    body = response.get_json()
    assert body["retrievalMode"] == "keyword+tag"
    assert body["hits"]
