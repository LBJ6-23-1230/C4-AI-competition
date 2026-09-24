# -*- coding: utf-8 -*-
"""按知识点**现场出题** —— 固定题库覆盖不到时的兜底。

## 为什么需要

`data/question_bank.json` 是固定题库（30 题 / **6 个知识点**）。
用户真正薄弱的知识点不可能只落在这 6 个里 —— 一旦落空，原行为是
"回落到演示那 3 道题"，也就是用户反馈的「**永远是那三个题目**」。

本模块让模型针对**任意知识点**出题，把覆盖面从"6 个知识点"扩到"任意"。

## ⚠️ 一条不能越的边界：模型只出题，**判分仍是确定性算式**

判分走 `app/tools/assessment_tools.grade_exercise`，按**存下来的 `answerKey`**
逐题比对，和模型没有任何关系。也就是说本题库与生成题的**判分口径完全一致**、
可复现、可断言。

这样"判断是算式，不是模型觉得"这条设计纪律**没有被打折**，
被放宽的只有一件小事：题从哪来。答辩时这正是最好讲的分层——
**"题库优先（可复现），覆盖不到时让模型出（并标注），判分始终是算式"**。

## 诚实边界（必须保留）

生成题的 `answerKey` 是模型给的，**存在出错的可能**。所以：
* 每题必须带 `explanation`（一句话说明为什么对），异常时它会被展示出来，可人工核对；
* 返回的题带 `source="llm"`，接口如实标注，前端据此提示"这组题由大模型生成"；
* 校验不过整批丢弃，宁可回落到题库默认题，**也不端出一批残缺的题**。
"""

from __future__ import annotations

import hashlib
import re
import uuid
from typing import Any

from app.agent import chat_llm

#: 一次最多生成几道（防止一句 prompt 要 20 道，既慢又容易出废题）
MAX_GENERATE_COUNT = 6
#: 选项必须是 A-D 四个
_OPTION_LETTERS = ("A", "B", "C", "D")
_OPTION_RE = re.compile(r"^\s*([A-D])\s*[.、．:：]\s*(\S.*)$")


def generation_available() -> bool:
	"""是否具备出题能力（本质是"配没配 Key"）。"""
	return chat_llm.llm_ready()


def _slug(knowledge_point_name: str) -> str:
	"""把知识点名字压成可安全用作 id 片段的短串。

	中文知识点名不能直接进 id（长度、编码都不稳），所以取 sha1 前 10 位。
	这样同一知识点每次生成的 id 前缀相同，便于按知识点排查。
	"""
	digest = hashlib.sha1(knowledge_point_name.strip().encode("utf-8")).hexdigest()
	return digest[:10]


def _normalize_options(raw: Any) -> list[str] | None:
	"""校验并规范化选项：必须恰好 4 个，且形如 `A. xxx`。

	模型有时会把选项写成 `["根-左-右", ...]`（不带字母前缀），
	这里补上前缀；若有别的形状（个数不对、空串）一律判为不合格。
	"""
	if not isinstance(raw, list) or len(raw) != len(_OPTION_LETTERS):
		return None
	normalized: list[str] = []
	for index, item in enumerate(raw):
		text = str(item).strip()
		if not text:
			return None
		match = _OPTION_RE.match(text)
		body = match.group(2).strip() if match else text
		if not body:
			return None
		normalized.append(f"{_OPTION_LETTERS[index]}. {body}")
	return normalized


def _normalize_item(item: Any, knowledge_point_name: str, index: int,
					nonce: str) -> dict[str, Any] | None:
	"""把模型给出的一道题校验成题库同构的记录；不合格返回 None。"""
	if not isinstance(item, dict):
		return None
	stem = str(item.get("stem") or "").strip()
	if not stem:
		return None
	options = _normalize_options(item.get("options"))
	if options is None:
		return None
	answer = str(item.get("answer") or "").strip().upper()[:1]
	if answer not in _OPTION_LETTERS:
		return None
	explanation = str(item.get("explanation") or "").strip()
	return {
		# ⚠️ id 必须带 nonce：判分表是"exerciseId → answerKey"，
		# 若两次生成用同一个 id，后一次会覆盖前一次的答案，
		# 前一位用户交卷时就会按新题的答案被判 —— 串题。
		# 加 nonce 后每次生成都是独立的一批；`_slug` 前缀保留知识点可追溯性。
		"exerciseId": f"llm-{_slug(knowledge_point_name)}-{nonce}-{index:02d}",
		"knowledgePointId": knowledge_point_name,
		"knowledgePointName": knowledge_point_name,
		"difficulty": "medium",
		"stem": stem,
		"options": options,
		"answerKey": answer,
		"explanation": explanation,
		# ⚠️ 打标：前端与答辩都要能一眼看出"这题是模型出的"
		"source": "llm",
	}


_SYSTEM_PROMPT = (
	"你是高校计算机课程的出题老师。只输出 JSON，不要任何解释性文字。"
)

_USER_PROMPT = """请针对知识点「{point}」出 {count} 道**单项选择题**，难度中等，考查概念理解与常见误区。

硬性要求：
1. 每题**恰好 4 个选项**，按 `A. xxx` 的格式书写；
2. `answer` 只能是 "A"/"B"/"C"/"D" 之一，且必须是**唯一的正确答案**；
3. 题干要具体、可判断，不要出现"以上都对""以上都不对"这类选项；
4. `explanation` 用一句话说明为什么这个答案对，并点出最常见的错误理解。

只输出如下 JSON（不要 markdown 代码块）：
{{"exercises":[{{"stem":"题干","options":["A. ...","B. ...","C. ...","D. ..."],"answer":"A","explanation":"..."}}]}}"""


def generate_exercises(knowledge_point_name: str, count: int) -> list[dict[str, Any]] | None:
	"""让模型针对该知识点出题。

	返回题库同构的记录列表；**任何一步不达标都返回 None**（调用方回落到题库默认题）。
	不抛异常：出题失败不该把练习页打挂。
	"""
	point = (knowledge_point_name or "").strip()
	if not point or count < 1:
		return None
	wanted = min(count, MAX_GENERATE_COUNT)
	if not generation_available():
		return None

	try:
		content = chat_llm._call_llm(
			_SYSTEM_PROMPT,
			_USER_PROMPT.format(point=point, count=wanted),
			temperature=0.6,
			# 4 道题 × (题干+4 选项+解析) 的中文量，800 会截断
			max_tokens=1600,
			response_json=True,
		)
	except Exception:  # noqa: BLE001  —— 网络/额度/超时都不该把页面打挂
		return None

	parsed = chat_llm.extract_json(content)
	if not isinstance(parsed, dict):
		return None
	raw_items = parsed.get("exercises")
	if not isinstance(raw_items, list):
		return None

	items: list[dict[str, Any]] = []
	seen_stems: set[str] = set()
	nonce = uuid.uuid4().hex[:6]
	for raw in raw_items:
		item = _normalize_item(raw, point, len(items) + 1, nonce)
		if item is None:
			continue
		key = item["stem"]
		if key in seen_stems:      # 模型偶尔会重复出同一道
			continue
		seen_stems.add(key)
		items.append(item)
		if len(items) >= wanted:
			break

	# 一道都没通过校验 → 当作失败，让调用方回落题库
	return items if items else None
