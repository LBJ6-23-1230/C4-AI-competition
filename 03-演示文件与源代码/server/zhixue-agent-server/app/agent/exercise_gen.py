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
import json
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

_REVIEW_SYSTEM_PROMPT = (
	"你是严谨的高校课程助教。只输出 JSON；必须依据题干、全部选项与标准答案讲解，"
	"不得更改标准答案，不得省略错误选项分析。"
)

_REVIEW_USER_PROMPT = """请为下面这组已经判分的单项选择题生成详细解析。

每题解析必须包含：
1. 正确选项为什么正确，给出关键概念或推导过程；
2. 其余每个选项为什么不成立；
3. 结合用户选择指出容易混淆之处和一个可操作的记忆/检查方法。
不要只写“正确答案是 X”，也不要重新判分。每题建议 120—260 个汉字。

题目 JSON：
{questions}

只输出如下 JSON（不要 markdown 代码块）：
{{"reviews":[{{"exerciseId":"题目ID","explanation":"详细解析"}}]}}"""


def _fallback_review_explanation(question: dict[str, Any], selected_answer: str,
								 correct_answer: str) -> str:
	"""LLM 暂不可用时的可核对兜底；不再返回“请重新核对概念”式空话。"""
	options = [str(item).strip() for item in question.get("options", []) if str(item).strip()]
	correct_option = next((item for item in options if item[:1] == correct_answer), correct_answer)
	other_options = [item for item in options if item[:1] != correct_answer]
	selected_note = (f"你选择了 {selected_answer}，应重点比较它与 {correct_answer} 在定义、"
		"适用条件和执行顺序上的差别。" if selected_answer and selected_answer != correct_answer
		else "你的选择与标准答案一致，仍建议用定义逐项排除，避免只靠记忆字母。")
	return (f"标准答案是 {correct_option}。判断这道题时，应先锁定题干考查的核心定义，再把选项逐一代入；"
		f"其余选项（{'；'.join(other_options) or '无'}）至少有一处不符合题干限定，不能作为标准答案。"
		f"{selected_note}复习时请用“定义—条件—结论”三步重新验证，并说明每个错误选项错在哪里。")


def generate_review_explanations(questions: list[dict[str, Any]],
								 submitted_answers: dict[str, str],
								 answer_keys: dict[str, str]) -> tuple[dict[str, str], set[str]]:
	"""一次 LLM 调用批量生成逐题详解，失败时返回信息完整、且不冒充 AI 的兜底解析。"""
	requested: list[dict[str, Any]] = []
	by_id: dict[str, dict[str, Any]] = {}
	for question in questions:
		exercise_id = str(question.get("exerciseId") or "")
		if exercise_id not in submitted_answers or exercise_id not in answer_keys:
			continue
		by_id[exercise_id] = question
		requested.append({
			"exerciseId": exercise_id,
			"stem": question.get("stem", ""),
			"options": question.get("options", []),
			"selectedAnswer": submitted_answers[exercise_id],
			"correctAnswer": answer_keys[exercise_id],
		})

	result: dict[str, str] = {}
	llm_ids: set[str] = set()
	if requested and generation_available():
		try:
			content = chat_llm._call_llm(
				_REVIEW_SYSTEM_PROMPT,
				_REVIEW_USER_PROMPT.format(
					questions=json.dumps(requested, ensure_ascii=False, separators=(",", ":"))),
				temperature=0.2,
				max_tokens=min(4000, 900 + len(requested) * 650),
				response_json=True,
			)
			parsed = chat_llm.extract_json(content)
			rows = parsed.get("reviews") if isinstance(parsed, dict) else None
			if isinstance(rows, list):
				for row in rows:
					if not isinstance(row, dict):
						continue
					exercise_id = str(row.get("exerciseId") or "")
					explanation = str(row.get("explanation") or "").strip()
					if exercise_id in by_id and len(explanation) >= 40:
						result[exercise_id] = explanation
						llm_ids.add(exercise_id)
		except Exception:  # noqa: BLE001 -- 解析失败不能让确定性判分与交卷失败
			pass

	for exercise_id, question in by_id.items():
		if exercise_id not in result:
			result[exercise_id] = _fallback_review_explanation(
				question, submitted_answers[exercise_id], answer_keys[exercise_id])
	return result, llm_ids


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
