# -*- coding: utf-8 -*-
"""请求体输入护栏。

为什么需要集中一处
------------------
原先每个路由各自 `request.get_json(silent=True) or {}`，但**只有部分路由**做了
`isinstance(data, dict)` 检查（`app/api/proactive.py` 有，其余没有）。

后果：客户端发一个**非对象**的 JSON（`[1,2,3]` / `"hello"` / `123` / `true`）
时，`data.get(...)` 会抛 `AttributeError`，向上冒泡成 **HTTP 500**。
实测 4 个入口全部中招（workflows 的 create 与 run、exercises 的 submit、
partner-match）。这类输入在真实环境里并不罕见——旧客户端、手写 curl、
第三个消费方都可能发出来。

统一放在这里，避免"改了一个入口忘了另一个"（本轮已经因此踩过一次：
`answers` 护栏只加在 `/run`，`/submit` 与 `autoRun` 分支漏掉了）。
"""

from __future__ import annotations

from typing import Any

from flask import jsonify, request

# 请求体字段的统一上限。任何"可被客户端无限放大"的字段都必须有上限，
# 否则会写进 repository.json —— 而 JsonRepository 每次 save 全量重写整个文件，
# 单次请求即可把仓库撑大数 MB（实测 20 万字符的 idempotencyKey 使
# repository.json 从 31,927 字节涨到 2,826,331 字节）。
MAX_ID_CHARS = 128
MAX_TEXT_CHARS = 2_000
MAX_ANSWERS = 200
MAX_ANSWER_CHARS = 200


def bad_request(message: str, details: dict[str, Any] | None = None):
    return jsonify({"errorCode": "BAD_REQUEST", "message": message, "details": details}), 400


def json_object() -> tuple[dict[str, Any] | None, Any]:
    """取请求体并确保它是 JSON 对象。

    返回 `(data, error_response)`：
    * `data` 为 dict 时，`error_response` 为 None
    * 否则 `data` 为 None，`error_response` 是可直接 return 的 400 响应

    语义边界（很重要，别把合法请求挡掉）：
    * **完全没有请求体** → 当作 `{}` 放行。多个端点本来就允许空 POST
      （例如 `POST /api/v1/workflows/<id>/run` 不传答案只推进到等待态），
      把"无 body"判成 400 会直接打挂这些正常用法。
    * **有 body 但不是对象**（`[1,2,3]` / `"hello"` / `123` / `true`）→ 400。
      这是原先变成 500 的那一类。
    """
    data = request.get_json(silent=True)
    if data is None:
        raw = request.get_data() or b""
        if not raw.strip():
            return {}, None          # 空请求体：按空对象处理
        return None, bad_request("请求体必须是 JSON 对象或留空",
                                 {"received": "非对象或非法 JSON"})
    if not isinstance(data, dict):
        return None, bad_request("请求体必须是 JSON 对象",
                                 {"received": type(data).__name__})
    return data, None


def bounded_str(value: Any, field: str, limit: int, *, required: bool = True,
                allow_empty: bool = False):
    """校验字符串字段并限制长度。

    返回 `(text, error_response)`；合法时 `text` 为字符串、`error_response` 为 None。
    """
    if value is None:
        if required:
            return None, bad_request(f"{field} 为必填字段", {"field": field})
        return "", None
    if not isinstance(value, str):
        return None, bad_request(f"{field} 必须是字符串", {"field": field})
    text = value.strip()
    if not text and not allow_empty:
        return None, bad_request(f"{field} 不能为空", {"field": field})
    if len(value) > limit:
        return None, bad_request(f"{field} 最长 {limit} 字符",
                                 {"field": field, "limit": limit, "received": len(value)})
    return text, None


def validate_answers(answers: Any):
    """校验答案数组：必须是对象数组，且数量与单条长度都有上限。

    返回 `(answers, error_response)`。
    """
    if not isinstance(answers, list):
        return None, bad_request("answers 必须是数组", {"field": "answers"})
    if len(answers) > MAX_ANSWERS:
        return None, bad_request(f"answers 最多 {MAX_ANSWERS} 条，收到 {len(answers)} 条",
                                 {"field": "answers", "limit": MAX_ANSWERS, "received": len(answers)})
    for item in answers:
        if not isinstance(item, dict):
            return None, bad_request("answers 中每一项都必须是对象",
                                     {"field": "answers", "received": type(item).__name__})
        answer = item.get("answer")
        if isinstance(answer, str) and len(answer) > MAX_ANSWER_CHARS:
            return None, bad_request(f"单个 answer 最长 {MAX_ANSWER_CHARS} 字符",
                                     {"field": "answer", "limit": MAX_ANSWER_CHARS,
                                      "received": len(answer)})
    return answers, None
