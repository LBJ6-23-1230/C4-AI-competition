# -*- coding: utf-8 -*-
"""知识库第一期回归测试。

覆盖 `docs/12-知识库设计方案.md` 第一期的验收点：
解析 / 切片 / 知识点提取 / 易错点 / 检索 / 用户隔离 / 诚实降级 / 输入护栏。
"""

import base64

from app import create_app

H = {"X-API-Contract-Version": "api-contract-v0.3"}

LECTURE = """# 第3章 树与二叉树

## 3.2 二叉树遍历

前序遍历的顺序是根-左-右。中序遍历的顺序是左-根-右。

## 3.2.3 后序遍历

后序遍历的顺序是左-右-根，因此根节点总是最后被访问。
常见错误：把后序遍历与中序遍历的访问时机混淆。

## 3.3 递归理解

递归理解的核心是终止条件与调用栈。递归理解不到位会导致遍历写错。
递归理解的练习建议从简单树开始。
"""


def _b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def _make_kb(client, name="结构复习库"):
    response = client.post("/api/v1/knowledge-bases",
                           json={"courseName": "数据结构", "name": name}, headers=H)
    assert response.status_code == 201
    return response.get_json()["kbId"]


def _upload(client, kb_id, file_name="二叉树复习讲义.md", text=LECTURE):
    return client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"fileName": file_name, "contentBase64": _b64(text),
                             "mimeType": "text/markdown"},
                       headers=H)


# --------------------------------------------------------------------- 切片与标题路径
def test_upload_extracts_chunks_with_heading_path(tmp_path):
    """切片必须带 `headingPath` —— 这是引用能标注"第几章第几节"的前提。"""
    client = create_app(tmp_path / "kb.json").test_client()
    kb_id = _make_kb(client)

    body = _upload(client, kb_id).get_json()

    assert body["status"] == "ready"
    assert body["chunkCount"] >= 3
    assert body["charCount"] > 100

    hits = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序遍历", "topK": 5}, headers=H).get_json()["hits"]
    assert hits, "应当能检索到内容"
    paths = [hit["headingPath"] for hit in hits]
    assert any("后序遍历" in path for path in paths), f"标题路径缺失：{paths}"
    assert any(">" in path for path in paths), "应当保留层级（用 > 连接）"


# --------------------------------------------------------------------- 知识点提取
def test_knowledge_points_come_from_headings(tmp_path):
    """知识点提取应来自标题层级，并剥掉编号前缀。"""
    client = create_app(tmp_path / "kb-points.json").test_client()
    kb_id = _make_kb(client)

    points = _upload(client, kb_id).get_json()["knowledgePoints"]

    assert "后序遍历" in points, f"应识别出后序遍历，实际 {points}"
    assert "递归理解" in points, f"应识别出递归理解，实际 {points}"
    # 编号前缀必须被剥掉（否则会出现 '.2.3 后序遍历' 这种脏标签）
    for point in points:
        assert not point.startswith("."), f"标题编号未剥离干净：{points}"
        assert not point.startswith("第"), f"标题编号未剥离干净：{points}"
    assert all(len(point) <= 12 for point in points), f"存在过长标签：{points}"


def test_error_point_candidates_are_extracted(tmp_path):
    """易错点候选来自命中小节标题/易错语境的句子（确定性规则，非模型生成）。"""
    client = create_app(tmp_path / "kb-errors.json").test_client()
    kb_id = _make_kb(client)

    candidates = _upload(client, kb_id).get_json()["errorPointCandidates"]

    assert candidates, "应当抽取出易错点候选"
    assert any("混淆" in item or "错误" in item for item in candidates), \
        f"应当命中易错语境：{candidates}"


# --------------------------------------------------------------------- 检索
def test_search_ranks_relevant_chunk_first(tmp_path):
    client = create_app(tmp_path / "kb-search.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id)

    hits = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序遍历的顺序", "topK": 3}, headers=H).get_json()["hits"]

    assert hits, "应当有命中"
    assert "后序" in hits[0]["headingPath"], f"最相关切片应排第一：{hits[0]['headingPath']}"
    assert hits[0]["score"] > 0
    # 分数必须递减
    scores = [hit["score"] for hit in hits]
    assert scores == sorted(scores, reverse=True)


def test_search_reports_retrieval_mode_honestly(tmp_path):
    """检索方式必须诚实标注（答辩时要能解释当前是关键词还是向量）。"""
    client = create_app(tmp_path / "kb-mode.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id)

    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "遍历"}, headers=H).get_json()

    assert body["retrievalMode"] == "keyword+tag"
    assert body["totalScanned"] >= 1


def test_search_hit_carries_file_name_for_citation(tmp_path):
    """命中必须带文件名 —— 引用要能指回来源。"""
    client = create_app(tmp_path / "kb-cite.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id, file_name="我的讲义.md")

    hits = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序"}, headers=H).get_json()["hits"]

    assert hits
    assert hits[0]["fileName"] == "我的讲义.md"


def test_search_rejects_bad_top_k(tmp_path):
    client = create_app(tmp_path / "kb-topk.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id)

    for bad in (0, -1, 21, "5", True):
        response = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                               json={"query": "遍历", "topK": bad}, headers=H)
        assert response.status_code == 400, f"topK={bad!r} 应当被拒"


# --------------------------------------------------------------------- 诚实降级
def test_pdf_upload_fails_honestly_not_silently(tmp_path):
    """PDF 第一期不支持，必须**明确失败并给出原因**，不能假装成功。"""
    client = create_app(tmp_path / "kb-pdf.json").test_client()
    kb_id = _make_kb(client)

    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"fileName": "真题.pdf",
                             "contentBase64": _b64("%PDF-1.4 fake")},
                       headers=H).get_json()

    assert body["status"] == "failed"
    assert "PDF" in body["statusMessage"]
    assert body["chunkCount"] == 0


def test_unsupported_extension_fails_honestly(tmp_path):
    client = create_app(tmp_path / "kb-ext.json").test_client()
    kb_id = _make_kb(client)

    body = _upload(client, kb_id, file_name="讲义.docx", text="内容").get_json()

    assert body["status"] == "failed"
    assert "不支持" in body["statusMessage"]


def test_invalid_base64_fails_honestly(tmp_path):
    client = create_app(tmp_path / "kb-b64.json").test_client()
    kb_id = _make_kb(client)

    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"fileName": "内容.md", "contentBase64": "!!!not-base64!!!"},
                       headers=H).get_json()

    assert body["status"] == "failed"
    assert body["statusMessage"]


def test_gbk_encoded_file_is_decoded(tmp_path):
    """国内 CSV 常见 GBK 编码，必须能正确解码而不是乱码。"""
    client = create_app(tmp_path / "kb-gbk.json").test_client()
    kb_id = _make_kb(client)

    content = "二叉树遍历,后序遍历是左右根".encode("gbk")
    body = client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"fileName": "题库.csv",
                             "contentBase64": base64.b64encode(content).decode("ascii")},
                       headers=H).get_json()

    assert body["status"] == "ready"
    hits = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "后序遍历"}, headers=H).get_json()["hits"]
    assert hits, "GBK 内容应当可被检索"


# --------------------------------------------------------------------- 用户隔离
def test_knowledge_bases_are_isolated_per_user(tmp_path):
    """知识库是个人资料，**必须按用户隔离**。

    这条是硬要求：审计已发现项目里存在"登录后仍读到 demo-user 数据"的缺陷，
    新模块不能重复这个错误。
    """
    client = create_app(tmp_path / "kb-isolation.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id)

    assert client.get("/api/v1/knowledge-bases?userId=other-user",
                      headers=H).get_json()["total"] == 0
    assert client.get(f"/api/v1/knowledge-bases/{kb_id}?userId=other-user",
                      headers=H).status_code == 404
    assert client.get(f"/api/v1/knowledge-bases/{kb_id}/documents?userId=other-user",
                      headers=H).status_code == 404
    assert client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "遍历", "userId": "other-user"},
                       headers=H).status_code == 404


def test_same_user_sees_own_knowledge_base(tmp_path):
    client = create_app(tmp_path / "kb-own.json").test_client()
    kb_id = _make_kb(client)

    body = client.get("/api/v1/knowledge-bases", headers=H).get_json()

    assert body["total"] == 1
    assert body["knowledgeBases"][0]["kbId"] == kb_id


# --------------------------------------------------------------------- 汇总与删除
def test_knowledge_base_summary_updates_after_upload(tmp_path):
    """上传后知识库的文档数/切片数/知识点汇总必须刷新。"""
    client = create_app(tmp_path / "kb-summary.json").test_client()
    kb_id = _make_kb(client)

    before = client.get(f"/api/v1/knowledge-bases/{kb_id}", headers=H).get_json()
    assert before["documentCount"] == 0
    assert before["chunkCount"] == 0

    _upload(client, kb_id)

    after = client.get(f"/api/v1/knowledge-bases/{kb_id}", headers=H).get_json()
    assert after["documentCount"] == 1
    assert after["chunkCount"] >= 3
    assert after["knowledgePoints"], "汇总里应当有知识点"
    assert len(after["documents"]) == 1
    assert after["documents"][0]["status"] == "ready"


def test_delete_document_clears_chunks(tmp_path):
    client = create_app(tmp_path / "kb-del-doc.json").test_client()
    kb_id = _make_kb(client)
    document_id = _upload(client, kb_id).get_json()["documentId"]

    assert client.delete(f"/api/v1/documents/{document_id}", headers=H).status_code == 200

    after = client.get(f"/api/v1/knowledge-bases/{kb_id}", headers=H).get_json()
    assert after["documentCount"] == 0
    assert after["chunkCount"] == 0
    hits = client.post(f"/api/v1/knowledge-bases/{kb_id}/search",
                       json={"query": "遍历"}, headers=H).get_json()["hits"]
    assert hits == [], "删除文档后不应还能检索到切片"


def test_delete_knowledge_base(tmp_path):
    client = create_app(tmp_path / "kb-del.json").test_client()
    kb_id = _make_kb(client)
    _upload(client, kb_id)

    assert client.delete(f"/api/v1/knowledge-bases/{kb_id}", headers=H).status_code == 200
    assert client.get(f"/api/v1/knowledge-bases/{kb_id}", headers=H).status_code == 404


# --------------------------------------------------------------------- 护栏
def test_duplicate_knowledge_base_name_is_conflict(tmp_path):
    client = create_app(tmp_path / "kb-dup.json").test_client()
    _make_kb(client, name="重名库")

    response = client.post("/api/v1/knowledge-bases",
                           json={"courseName": "数据结构", "name": "重名库"}, headers=H)

    assert response.status_code == 409
    assert response.get_json()["errorCode"] == "CONFLICT"


def test_one_course_has_one_knowledge_base(tmp_path):
    client = create_app(tmp_path / "kb-course-unique.json").test_client()
    first = client.post("/api/v1/knowledge-bases", json={
        "courseName": "数据结构", "name": "期中资料",
    }, headers=H)
    assert first.status_code == 201

    duplicate_course = client.post("/api/v1/knowledge-bases", json={
        "courseName": " 数据结构 ", "name": "期末资料",
    }, headers=H)
    assert duplicate_course.status_code == 409
    assert duplicate_course.get_json()["details"]["kbId"] == first.get_json()["kbId"]


def test_upload_rejects_path_traversal_in_file_name(tmp_path):
    """文件名必须是最后一段，防止路径穿越。"""
    client = create_app(tmp_path / "kb-traversal.json").test_client()
    kb_id = _make_kb(client)

    body = _upload(client, kb_id, file_name="../../etc/passwd.md").get_json()

    assert "/" not in body["fileName"]
    assert body["fileName"] == "passwd.md"


def test_upload_rejects_empty_payload(tmp_path):
    client = create_app(tmp_path / "kb-empty.json").test_client()
    kb_id = _make_kb(client)

    assert client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"fileName": "空.md", "contentBase64": ""},
                       headers=H).status_code == 400
    assert client.post(f"/api/v1/knowledge-bases/{kb_id}/documents",
                       json={"contentBase64": "YQ=="}, headers=H).status_code == 400


def test_knowledge_base_requires_course_and_name(tmp_path):
    client = create_app(tmp_path / "kb-required.json").test_client()

    assert client.post("/api/v1/knowledge-bases", json={}, headers=H).status_code == 400
    assert client.post("/api/v1/knowledge-bases",
                       json={"courseName": "数据结构"}, headers=H).status_code == 400


def test_non_object_body_is_rejected(tmp_path):
    """沿用统一护栏：非对象 JSON 返回 400 而不是 500。"""
    client = create_app(tmp_path / "kb-body.json").test_client()

    for raw in ('[1,2,3]', '"hello"', '123'):
        response = client.post("/api/v1/knowledge-bases", data=raw,
                               content_type="application/json", headers=H)
        assert response.status_code == 400, f"{raw} → {response.status_code}"


def test_upload_unknown_knowledge_base_is_404(tmp_path):
    client = create_app(tmp_path / "kb-404.json").test_client()

    response = client.post("/api/v1/knowledge-bases/kb-nonexistent/documents",
                           json={"fileName": "a.md", "contentBase64": _b64("x")},
                           headers=H)

    assert response.status_code == 404
