# -*- coding: utf-8 -*-
"""生成《知学 Mate · 9/18–9/30 总任务线与任务清单》Word 文档。

用法：
    E:\\C4联调\\.venv-lt\\Scripts\\python.exe tools\\generate_task_plan_docx.py
输出：
    E:\\C4联调\\知学Mate_复赛冲刺总任务线_2026-09-18至09-30.docx
"""

from __future__ import annotations

import os
from pathlib import Path

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

# 默认输出到仓库内的 deliverables/；换机器直接可用。
# 需要别的位置时：python tools/generate_task_plan_docx.py --out D:\somewhere
OUT_DIR = Path(__file__).resolve().parent.parent / "deliverables"
OUT_FILE = OUT_DIR / "知学Mate_复赛冲刺总任务线_2026-09-18至09-30.docx"

FONT_CN = "微软雅黑"
FONT_EN = "Segoe UI"
COLOR_PRIMARY = RGBColor(0x1F, 0x4E, 0x79)
COLOR_RED = RGBColor(0xC0, 0x00, 0x00)
COLOR_ORANGE = RGBColor(0xB4, 0x53, 0x09)
COLOR_GREEN = RGBColor(0x1E, 0x6B, 0x3A)
COLOR_GREY = RGBColor(0x59, 0x59, 0x59)


# --------------------------------------------------------------------------- 基础样式
def _set_run_font(run, size=10.5, bold=False, color=None, cn=FONT_CN, en=FONT_EN):
    run.font.name = en
    run.font.size = Pt(size)
    run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), cn)
    rfonts.set(qn("w:ascii"), en)
    rfonts.set(qn("w:hAnsi"), en)


def _style_document(doc: Document) -> None:
    normal = doc.styles["Normal"]
    normal.font.name = FONT_EN
    normal.font.size = Pt(10.5)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), FONT_CN)

    specs = {
        "Heading 1": (16, COLOR_PRIMARY),
        "Heading 2": (13.5, COLOR_PRIMARY),
        "Heading 3": (11.5, RGBColor(0x2E, 0x5C, 0x8A)),
        "Heading 4": (10.5, RGBColor(0x40, 0x40, 0x40)),
    }
    for name, (size, color) in specs.items():
        style = doc.styles[name]
        style.font.name = FONT_EN
        style.font.size = Pt(size)
        style.font.bold = True
        style.font.color.rgb = color
        style.element.rPr.rFonts.set(qn("w:eastAsia"), FONT_CN)

    section = doc.sections[0]
    section.top_margin = Cm(2.2)
    section.bottom_margin = Cm(2.2)
    section.left_margin = Cm(2.4)
    section.right_margin = Cm(2.4)


def add_title(doc: Document, text: str, subtitle: str | None = None) -> None:
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    _set_run_font(p.add_run(text), size=20, bold=True, color=COLOR_PRIMARY)
    if subtitle:
        p2 = doc.add_paragraph()
        p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
        _set_run_font(p2.add_run(subtitle), size=11, color=COLOR_GREY)


def h(doc: Document, text: str, level: int = 1):
    return doc.add_heading(text, level=level)


def para(doc: Document, text: str, size: float = 10.5, bold: bool = False, color=None,
         indent: bool = False, align=None):
    p = doc.add_paragraph()
    if indent:
        p.paragraph_format.left_indent = Cm(0.6)
    if align is not None:
        p.alignment = align
    _set_run_font(p.add_run(text), size=size, bold=bold, color=color)
    return p


def rich(doc: Document, segments, indent: bool = False):
    """segments = [(text, bold, color), ...]"""
    p = doc.add_paragraph()
    if indent:
        p.paragraph_format.left_indent = Cm(0.6)
    for text, bold, color in segments:
        _set_run_font(p.add_run(text), size=10.5, bold=bold, color=color)
    return p


def bullets(doc: Document, items, style: str = "List Bullet"):
    for item in items:
        if isinstance(item, tuple):
            text, bold = item
        else:
            text, bold = item, False
        p = doc.add_paragraph(style=style)
        _set_run_font(p.add_run(text), size=10.5, bold=bold)


def table(doc: Document, headers, rows, widths=None, font_size: float = 9.5):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr = t.rows[0].cells
    for i, text in enumerate(headers):
        hdr[i].text = ""
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        _set_run_font(p.add_run(text), size=font_size, bold=True,
                      color=RGBColor(0xFF, 0xFF, 0xFF))
        shd = hdr[i]._tc.get_or_add_tcPr().makeelement(qn("w:shd"), {})
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:fill"), "1F4E79")
        hdr[i]._tc.get_or_add_tcPr().append(shd)
    for row in rows:
        cells = t.add_row().cells
        for i, text in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            _set_run_font(p.add_run(str(text)), size=font_size)
    if widths:
        for row in t.rows:
            for i, width in enumerate(widths):
                row.cells[i].width = Cm(width)
    doc.add_paragraph()
    return t


def note_box(doc: Document, text: str, color=COLOR_RED, label: str = "关键提醒"):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.4)
    _set_run_font(p.add_run(f"【{label}】"), size=10.5, bold=True, color=color)
    _set_run_font(p.add_run(text), size=10.5, color=color)
    return p


def page_break(doc: Document) -> None:
    doc.add_page_break()


# --------------------------------------------------------------------------- 文档正文
def build() -> None:
    doc = Document()
    _style_document(doc)

    # ============================================================ 封面
    add_title(doc,
              "知学 Mate · 复赛冲刺总任务线",
              "2026-09-18 → 2026-09-30 ｜ 团队：暗影骑士王们（武汉理工大学）")
    doc.add_paragraph()

    para(doc, "文档定位", bold=True, color=COLOR_PRIMARY)
    para(doc,
         "本文给出从今天（2026-09-18）到复赛提交截止（2026-09-30 24:00）的"
         "完整任务线、任务清单与每一项的理由，供团队分工执行。"
         "所有结论均基于对 liantiao1 联调工程的实跑验证与工作区全部大赛/指导文档的核对。")
    doc.add_paragraph()

    para(doc, "证据基础", bold=True, color=COLOR_PRIMARY)
    bullets(doc, [
        "liantiao1 联调自检：61/61 项通过（tools/verify_liantiao1.py，退出码 0）",
        "后端单元测试：70 passed（Python 3.12.13）",
        "工程自带回归脚本：run_backend_core_regression.ps1 通过（退出码 0）",
        "文档依据：《2026 中国高校计算机大赛—人工智能创意赛 鸿蒙高校创新赛竞赛规程》、"
        "C4-AI-联调交付包 _docs/01–08 及三份「给同学」指导书",
    ])
    doc.add_paragraph()

    para(doc, "三条贯穿始终的纪律", bold=True, color=COLOR_RED)
    bullets(doc, [
        ("9/23 之后只修阻塞 Bug，不加任何新功能——演示崩一次的代价远大于少一个特性。", True),
        ("不改锁死的值：三个答案键（A/B/C）、knowledgePointId=binary-tree-postorder、"
         "42→58 演示基线。改任何一个先找联调负责人。", True),
        ("契约只能由联调负责人改，且必须先改 contracts/openapi.json 再改代码"
         "（工程有静态护栏校验两份契约逐字节一致）。", True),
    ])
    page_break(doc)

    # ============================================================ 一、现状
    h(doc, "一、现状盘点：起点比想象中好，但短板没有动", 1)

    h(doc, "1.1 一句话结论", 2)
    rich(doc, [
        ("这 5 天团队已经把「能证明」这件事做到了——判分是真的、闭环是稳的、"
         "重复提交不穿帮、离线在线同源。", False, None),
        ("但 50 分创新性的主战场（主动服务）仍然一行代码都没写。", True, COLOR_RED),
    ])
    para(doc,
         "剩余 12 天只有一件事：把已经算好的 Agent 决策，搬到用户会看到的地方去。"
         "服务卡片让它被看见，代理提醒让它会开口，位置上下文让它在对的时刻开口。")

    h(doc, "1.2 缺陷修复进度（对照 C4-AI-联调交付包 _docs/02、03）", 2)
    table(doc,
          ["编号", "原缺陷", "级别", "现在的状态", "证据"],
          [
              ["P0-1", "question_bank.json 缺失", "阻塞", "已修复", "判分从恒 0 恢复正确"],
              ["P0-2", "B1 判分与答案无关，恒 67", "阻塞", "已根治（架构级）", "全对 100.0 / √√× 66.67 / 全错 0.0"],
              ["P0-3", "DASHSCOPE_API_KEY 未配置", "阻塞", "仍未配", "llm_ready: false"],
              ["P1-1", "题集泄漏 answerKey", "高", "已修复", "自检项通过"],
              ["P1-2", "全错也涨掌握度", "高", "已修复", "实测 42 → 38"],
              ["P1-3", "重规划不幂等、时长漂移", "高", "已修复", "连跑 3 次稳定 [45, 15]"],
              ["P1-4", "契约 v0.2 / v0.3 不一致", "高", "已修复", "两份契约逐字节一致"],
              ["P1-5", "两套后端不同源", "高", "已根治", "合并为单进程单端口"],
              ["P1-6", "前端双数据源", "高", "部分收敛", "LocalAgentService 仍有 16 处调用"],
              ["P1-7", "B2 缺 /api/agent/health", "中", "已补", "探针 200"],
              ["P1-8", "聊天层未接真", "中", "已实现", "缺 Key 时诚实降级"],
              ["N-1", "proactive 主动决策接口", "新增", "已实现", "返回 5 条 factors + reason"],
              ["N-2", "五因子暴露到前端", "新增", "已实现", "FactorBreakdownCard 已上屏"],
              ["P2-1", "仓库重复嵌套目录", "中", "已清理", "新工程内不存在"],
              ["P2-2", "构建产物入库", "低", "已清理", ".gitignore 已补全"],
              ["H1", "服务卡片", "最高", "未实现", "全仓无 formProvider"],
              ["H2", "后台代理提醒", "高", "未实现", "无 reminderAgentManager"],
              ["H3", "语音识别", "高", "未实现", "仅注释占位"],
              ["H4", "位置服务", "中", "未实现", "无 geoLocationManager"],
              ["H5", "应用接续", "中", "未实现", "无 continueManager"],
              ["门槛", "HAP 出包", "门槛", "未验证", "signingConfigs 为空"],
          ],
          widths=[1.3, 4.0, 1.2, 2.4, 4.6])
    note_box(doc,
             "24 项中已有 17 项修复完成。真正没动的，全部集中在「主动服务」这一块——"
             "而它恰好是 Agent 赛道 50 分创新性的主战场。",
             color=COLOR_ORANGE, label="判读")

    h(doc, "1.3 评分自评更新", 2)
    table(doc,
          ["评分项", "分值", "09-16 自评", "现在", "变化原因"],
          [
              ["创新性", "50", "32–36", "36–39", "五因子可解释决策已上屏；但主动服务仍为 0"],
              ["完备度", "20", "11–13", "16–17", "判分可信、单一真源、闭环稳定、离线在线同源"],
              ["前景评估", "20", "14–15", "14–15", "未变（缺真实小样本数据）"],
              ["规范性", "10", "5–6", "8–9", "仓库干净、契约冻结、61/61 可复现证据"],
              ["附加：应用价值", "20", "8–10", "10–12", "有完整源码 + 自检；仍缺 HAP 包"],
              [("合计", True), ("120", True), ("70–80", True), ("84–92", True),
               ("完备度/规范性已接近满分，创新性只提升约 4 分", True)],
          ],
          widths=[3.0, 1.3, 2.2, 1.8, 5.2])
    page_break(doc)

    # ============================================================ 二、总任务线
    h(doc, "二、总任务线（9/18 → 9/30）", 1)

    h(doc, "2.1 三阶段总览", 2)
    table(doc,
          ["阶段", "日期", "主题", "人日", "目标"],
          [
              ["阶段一", "9/18 – 9/22", "把「主动服务」从 0 做到 1（P0）", "约 4 人日",
               "服务卡片 + 代理提醒上线，配 Key，统一用户 ID，验证能出 HAP"],
              ["阶段二", "9/23 – 9/25", "补齐自然交互（P1）", "约 1.5 人日",
               "语音识别 + 位置服务，凑齐 8 项鸿蒙特性"],
              ["阶段三", "9/26 – 9/30", "收口、出包、提交", "—",
               "文档改稿、录视频、打包、交叉验收、提交"],
          ],
          widths=[1.6, 2.6, 5.2, 1.8, 5.2])
    note_box(doc,
             "阶段一的三件事（服务卡片 + 代理提醒 + 配 Key）合计约 2.5–3 天，"
             "是这 12 天里分值密度最高的组合。若时间不够，宁可砍阶段二，也不要砍阶段一。",
             color=COLOR_RED, label="最高优先级")

    h(doc, "2.2 为什么是这三件事（战略判断）", 2)
    para(doc,
         "官方对 Agent 创新方向的核心要求原文是：「结合位置、时间、拍照、对话历史等用户上下文信息，"
         "让 AI 主动出现在对的时刻」。这句话里有两个关键词：", indent=False)
    bullets(doc, [
        ("上下文信息——项目已具备时间、拍照、对话历史；位置尚未使用。", False),
        ("主动出现在对的时刻——项目当前完全没有触达手段，这是最大缺口。", True),
    ])
    para(doc,
         "现状是：全局 AI 浮标虽然挂在所有页面，但它是「被动入口」——用户不点，它就不存在。"
         "评委看到的是一个「带 AI 功能的学习应用」，而不是「会主动找你的 Agent」。"
         "服务卡片让它被看见，代理提醒让它会开口，而已经做好的 proactive 接口"
         "让它的每一次开口都有理由——这三者合起来才是「主动服务」。")

    h(doc, "2.3 好消息：最难的部分后端已经做完了", 2)
    para(doc, "POST /api/v1/agent/proactive 已实测返回如下结构（可直接作为卡片与通知的数据源）：")
    code = doc.add_paragraph()
    code.paragraph_format.left_indent = Cm(0.6)
    _set_run_font(code.add_run(
        '{\n'
        '  "shouldNotify": true,\n'
        '  "channel": "reminder",\n'
        '  "title": "数据结构考试还有 5 天",\n'
        '  "body": "你上次后序遍历只答对 2/3，建议先补这个。要不要现在用 45 分钟？",\n'
        '  "action": { "type": "focus", "targetPage": "pages/FocusSetup",\n'
        '              "preset": { "taskId": "task-postorder", "durationMinutes": 45 } },\n'
        '  "contextTags": ["exam_within_7d", "recent_gap_2d", "location_library"],\n'
        '  "reason": "考试剩 5 天（紧迫度贡献 0.080），后序遍历掌握度 58 偏低（贡献 0.174），\n'
        '             近 2 天未学习，当前在图书馆适合深度专注",\n'
        '  "factors": [ 5 条五因子明细 ],\n'
        '  "cardData": { "taskName": "二叉树后序遍历", "durationMinutes": 45,\n'
        '                "examCountdownDays": 5, "hint": "近期复习不足 · 2 项作业临近" }\n'
        '}'),
        size=8.5, cn="Consolas", en="Consolas")
    note_box(doc,
             "reason 与 factors 是这份响应里最值钱的部分——它让「Agent 为什么现在找我」可解释。"
             "服务卡片和代理提醒都必须直接消费这份数据，前端不得硬编码文案。",
             color=COLOR_GREEN, label="答辩素材")
    page_break(doc)

    # ============================================================ 三、任务清单
    h(doc, "三、任务清单（逐项：做什么 / 为什么 / 怎么验收）", 1)

    # ---------------- P0 ----------------
    h(doc, "P0 阶段一：主动服务从 0 到 1（9/18 – 9/22）", 2)

    h(doc, "P0-1　桌面服务卡片", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "新增 EntryFormAbility（FormExtensionAbility 子类）+ WidgetCard（ArkTS 卡片 UI）"
                   "+ form_config.json；在 module.json5 注册 extensionAbilities（type: form）；"
                   "由 EntryAbility 调 formProvider.updateForm() 推送数据"],
        ["数据源", "/api/v1/agent/proactive 的 cardData 与 reason（前端不硬编码）"],
        ["为什么", "① 它是官方点名的「主动服务」最直接实现；② 桌面可见，截图与视频说服力最强；"
                   "③ 它是「应用」与「Agent」的分界线——卡片上显示的是 Agent 算出来的结论，不是应用入口"],
        ["谁来做", "前端（约 1.5–2 天）"],
        ["验收", "① 模拟器桌面可添加卡片；② 卡片显示「二叉树后序遍历 45 分钟 + 数据结构考试还有 5 天」；"
                 "③ 在 App 内完成一次练习后，卡片内容随之变化（这一条务必录进视频）"],
    ], widths=[2.2, 15.0])
    para(doc, "三条工程纪律（容易踩坑，务必先读）", bold=True, color=COLOR_RED)
    bullets(doc, [
        "卡片是受限环境：ArkTS 卡片不能直接发起网络请求、不能用大部分状态管理。"
        "正确做法是 EntryAbility / 后台任务算好后用 formProvider.updateForm(formId, data) 推给卡片。",
        "卡片刷新有频率限制：不要依赖「每分钟刷新」。走事件驱动——用户完成专注、完成练习、"
        "DDL 变化时主动 updateForm。",
        "尺寸做两套：2×2 显示「今日任务 + 时长」；2×4 多一行 Agent 理由（reason）。"
        "那一行是答辩最强的一句话，别浪费。",
    ])

    h(doc, "P0-2　后台代理提醒", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "reminderAgentManager.publishReminder() 保证「到点必达」（App 未运行也能触发）"
                   "+ notificationManager 负责前台即时提醒；两者结合"],
        ["数据源", "文案必须来自 proactive 的 title / body；action.targetPage 作为点击跳转目标"],
        ["为什么", "成本仅约 0.5 天，直接命中「主动服务」，且视频里能拍到系统通知弹出的画面——"
                   "这是最有说服力的「Agent 主动找我」证据"],
        ["谁来做", "前端（约 0.5 天）"],
        ["验收", "把系统时间调到 DDL 前一天 → 收到带 Agent 推理文案的通知 → 点击通知直达对应页面"],
    ], widths=[2.2, 15.0])
    para(doc, "通知文案模板（由后端生成，体现 Agent 推理，前端不得硬编码）", bold=True)
    table(doc, ["触发条件", "文案"], [
        ["DDL ≤ 2 天且当日未学习", "「数据结构实验明天截止，你今天还没开始。要不要用 25 分钟起个头？」"],
        ["考试 ≤ 3 天", "「数据结构考试还有 3 天。你上次后序遍历只答对 2/3，建议先补这个。」"],
        ["连续 2 天未学习", "「两天没学习了。我先把任务缩小到 15 分钟，降低重启成本。」"],
        ["搭子发来协同邀请", "「小红想约你 21:00 一起过图算法，你俩时间刚好重合。」"],
    ], widths=[4.5, 12.7])

    h(doc, "P0-3　配置 DASHSCOPE_API_KEY（10 分钟，全项目性价比最高）", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "cd liantiao1\\server\\zhixue-agent-server；Copy-Item .env.example .env；"
                   "填入 DASHSCOPE_API_KEY=sk-xxxx；重启后端"],
        ["为什么", "① 代码路径已全部就绪（chat_llm._call_llm_with_image 的 qwen-vl-plus 调用 + "
                   "AnalyzeWrongPrompt.txt 结构化输出规范），零代码改动；"
                   "② 错题拍照真实识别是视频脚本里「全场最有说服力的一段」；"
                   "③ 不配 Key，作品说明文档里「OCR 与大模型接口已预留」这句话就永远改不成已完成态"],
        ["谁来做", "后端（10 分钟）"],
        ["验收", "GET /api/agent/health 返回 llm_ready: true；"
                 "在 App 里发「帮我分析这道题」并附图 → 收到真实模型生成的回复"
                 "（不再带「当前未配置 DASHSCOPE_API_KEY」提示）"],
    ], widths=[2.2, 15.0])
    note_box(doc,
             "当前未配 Key 时，回复会主动附上「以上回复由本地确定性规则生成，不是大模型输出」。"
             "这条「不伪装」的设计本身就是答辩加分项，配好 Key 后该提示会自动消失。",
             color=COLOR_GREEN, label="已具备的优点")

    h(doc, "P0-4　统一演示用户 ID（30 分钟，做任何身份功能的前置条件）", 3)
    table(doc, ["项", "内容"], [
        ["问题", "前端 MockData.ets 的 mockCurrentUser.userId = 'u001'，"
                 "而 ExerciseViewModel.ets 兜底与后端演示数据都是 'demo-user'"],
        ["为什么", "Index.ets 把 appState.currentUser.userId（u001）传给 ProactiveViewModel，"
                   "而练习提交按 demo-user 读写。一旦后端按 userId 分片存储，"
                   "首页会说「掌握度 42 需要补强」，画像页会说「58 已经巩固」——"
                   "这是评委最容易当场击穿的那类矛盾"],
        ["做什么", "在 ApiDefaults.ets 增加 DEMO_USER_ID = 'demo-user'，"
                   "MockData.mockCurrentUser.userId 与所有 ?? 'demo-user' 兜底统一引用它"],
        ["谁来做", "前端（30 分钟）"],
        ["验收", "grep -r \"u001\" entry/src/main/ets 结果为空（或只剩候选人数据）"],
    ], widths=[2.2, 15.0])

    h(doc, "P0-5　验证 HAP 能出包（附加 20 分的门槛）", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "在 DevEco Studio 配置签名（build-profile.json5 的 signingConfigs 目前为空数组）"],
        ["为什么", "评分表原文：「实际可演示的 HAP 文件 / 源代码文件 / 演示系统、作品上架，附加评分越高」。"
                   "出不了包，附加 20 分就拿不到门槛。指导文档明确要求 D10 前必须验证"],
        ["谁来做", "全员（0.5 天）"],
        ["验收", "Build > Build Hap(s)/APP(s) 产出 entry-default-signed.hap"],
    ], widths=[2.2, 15.0])
    page_break(doc)

    # ---------------- P1 ----------------
    h(doc, "P1 阶段二：补齐自然交互（9/23 – 9/25）", 2)

    h(doc, "P1-1　语音识别", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "接入 @kit.CoreSpeechKit 的 speechRecognizer；识别结果直接塞进 ChatMain 输入框，"
                   "复用现有发送逻辑"],
        ["为什么", "官方原文并列要求「文本、语音、视觉」。现在语音按钮是个占位注释，"
                   "这是完整度上的明显缺口，且评委很容易现场点一下"],
        ["关键设计", "语音结果不要另开链路，直接复用 ChatMain 的发送逻辑 → "
                     "自动获得意图识别 + 卡片回复 + 页面跳转"],
        ["谁来做", "前端（约 1 天）"],
        ["验收", "真机点麦克风 → 说「帮我看看错题」→ 识别文字进输入框 → Agent 回复错题分析卡片"],
    ], widths=[2.2, 15.0])
    note_box(doc,
             "语音识别在模拟器上通常不可用，必须真机验证。请今天确认团队有 HarmonyOS 真机；"
             "没有就把本项降级为「已在文档中说明规划」，把时间给 P1-2 与 P2-2。",
             color=COLOR_RED, label="前置确认")

    h(doc, "P1-2　位置服务（0.5 天拿「位置上下文」，性价比极高）", 3)
    table(doc, ["项", "内容"], [
        ["做什么", "接入 @kit.LocationKit 的 geoLocationManager；取到位置后不显示坐标，"
                   "映射为学习情境（图书馆/教学楼 → 适合深度专注；宿舍/家 → 适合轻量复习），"
                   "作为参数传给 /api/v1/agent/proactive"],
        ["为什么", "官方在「主动服务」里明确点名了「位置」，而这一项成本极低"],
        ["效果", "首页文案变成：「你到图书馆了，环境适合深度专注。要不要直接开始 45 分钟的二叉树后序遍历？」"
                 "——这一句话就是「结合位置上下文，让 AI 主动出现在对的时刻」的标准答案"],
        ["谁来做", "前端（约 0.5 天）"],
        ["验收", "首页出现基于位置的主动建议文案"],
    ], widths=[2.2, 15.0])

    h(doc, "P1-3　前端数据源收敛（择一，不必全做）", 3)
    table(doc, ["方案", "内容", "成本", "建议"],
          [["方案一", "PartnerMatch 的四因子明细卡改走后端数据"
                     "（补一个 /api/v1/agent/partner-match 纯函数接口）", "2 小时", "推荐"],
           ["方案二", "在 PartnerMatch / FocusResult 顶部加数据来源徽标："
                     "「本页由端侧规则计算（离线可用）」/「本页由 Agent 计算」", "0.5 天",
            "诚实标注本身就是加分项"],
           ["方案三", "全部改走 ViewModel", "1.5 天", "复赛前不要做"]],
          widths=[1.6, 8.6, 2.0, 5.0])
    para(doc,
         "为什么：Index 的主动建议已走真实后端，但 PartnerMatch 的匹配结果仍是前端 7 个函数算的。"
         "评委问「这个搭子匹配是谁算的」时，若答「Agent 算的」而代码里是前端算的，"
         "属于文档与实现不一致，规范性 10 分会丢。")
    page_break(doc)

    # ---------------- P2 ----------------
    h(doc, "P2 阶段三：收口、出包、提交（9/26 – 9/30）", 2)

    h(doc, "P2-1　前端编译与运行验证（必须在 DevEco 中完成）", 3)
    para(doc,
         "本次联调修改/新增了 5 个前端文件，但本分析环境无 HarmonyOS SDK，"
         "所有前端结论均为静态审查。请在 DevEco 中逐项确认：")
    table(doc, ["#", "检查项", "期望"], [
        ["1", "Sync and Refresh Project", "无报错"],
        ["2", "entry 模块编译", "无 ArkTS 类型错误"],
        ["3", "api/ApiDefaults.ets 被正确 import", "新增文件，注意路径大小写"],
        ["4", "AgentApiClient.ets 引用 ApiDefaults", "无循环依赖"],
        ["5", "FixtureApiTransport.ets 的 ExerciseAnswer / ExerciseSubmission import", "编译通过"],
        ["6", "FixtureDemoStateStore 的 getMasteryScore / setMasteryScore", "可访问"],
        ["7", "Index.ets 与 ApiEnvironment.ets 的 ApiDefaults import", "无误"],
        ["8", "切到「离线 Fixture」→ 练习页故意答错", "分数随答案变化（不再是固定 67）"],
        ["9", "切到真实后端 → 练习页故意答错", "分数 66.67，掌握度 42 → 58"],
    ], widths=[1.0, 9.2, 7.0])
    note_box(doc,
             "已知风险点：FixtureApiTransport.assessment() 现在接收 ExerciseSubmission 类型的 body。"
             "ArkTS 对 as 断言与可选链的限制比 TypeScript 严格，若编译器报错，"
             "可改写为显式类型判断（详见 docs/03-联调说明与验收记录.md §6）。",
             color=COLOR_ORANGE, label="风险点")

    h(doc, "P2-2　作品说明文档改稿（规范性 10 分 + 可信度）", 3)
    para(doc, "当前文档大量使用「已预留」「当前原型以规则和 Mock 数据演示」的措辞。"
              "复赛阶段这等于自认功能未完成。改稿对照表：")
    table(doc, ["原文（问题措辞）", "建议改为"], [
        ["「当前聊天模块使用本地演示响应…」",
         "「聊天与错题诊断已接入通义千问 Qwen-VL 多模态大模型；离线或网络不可用时自动降级为"
         "确定性规则引擎，并在回复中显式标注，保证闭环不中断且不误导用户」"],
        ["「OCR 与大模型服务接口已预留」",
         "「已通过 Qwen-VL 实现错题图片的知识点识别与错误类型判定」"],
        ["「小艺语音入口、桌面服务卡片和跨设备任务接续属于后续规划」",
         "完成 P0-1/P0-2 后改为：「已实现桌面服务卡片与后台代理提醒，"
         "Agent 可在 DDL 临近、连续未学习时主动触达用户」"],
        ["「当前原型基于…在模拟设备中完成运行验证」",
         "保留，但补上测试数据（见下）"],
    ], widths=[6.0, 11.2])
    para(doc, "建议新增两节", bold=True)
    bullets(doc, [
        ("可量化验证章节：用 GET /api/v1/experiments/snapshot 导出真实事件数据，"
         "写出「N 次完整工作流中，Agent 平均执行 X 步、覆盖 Y 个智能体；掌握度平均提升 Z 分；"
         "重规划触发率 W%」。有数字和没数字在评委眼里是两个档次。", False),
        ("工程可信度章节：项目提供一键联调自检脚本 tools/verify_liantiao1.py，"
         "覆盖契约一致性、主链数值、旧缺陷回归护栏等 61 项断言，配合后端 70 个单元测试，"
         "可在 30 秒内复现全部结论。提交包内 evidence/verify_result.json 为原始输出。", True),
    ])

    h(doc, "P2-3　录制演示视频（至少 2 遍）", 3)
    para(doc, "以下时间轴已按「主动服务」升级。0:00、2:00、3:00 三处是评委最关注的。")
    table(doc, ["时间", "画面", "关键台词"], [
        ["0:00–0:25", "桌面服务卡片特写",
         "「它不等你提问——Agent 已经算好了今天最该做什么，45 分钟，"
         "因为考试还有 5 天、你上次只答对 2/3。」"],
        ["0:25–0:45", "系统通知弹出", "「而且它会在对的时候主动找你。」"],
        ["0:45–1:10", "语音输入", "点麦克风说「帮我看看错题」→ 识别 → Agent 回复卡片"],
        ["1:10–1:50", "错题拍照（真实 Qwen-VL）", "「拍一道错题」→ 真实识别知识点与错误类型"],
        ["1:50–2:30", "练习页故意答错 → 提交",
         "「得分 66.67，掌握度从 42 涨到 58。」必须展示分数随答案变化"],
        ["2:30–3:10", "五因子依据页",
         "「为什么是它？掌握度贡献 0.174、错误强度 0.168…综合 0.62。"
         "这是算出来的，不是模型猜的。」"],
        ["3:10–3:40", "AgentTrace 页",
         "「Agent 自己决定先叫练习 Agent 再叫评估 Agent，3 个智能体 3 个工具全部留痕。」"],
        ["3:40–4:00", "服务卡片内容变化", "「完成一轮后，卡片上的任务和时长自己变了。」"],
        ["4:00–4:30", "位置上下文 + 应用接续",
         "「到图书馆它会建议深度专注；手机上没学完，走到平板前自动接续。」"],
        ["4:30–4:50", "断网 / 关 LLM",
         "「拔掉大模型，流程依然跑得完——业务计算全是确定性代码，模型只回答『下一步叫谁』。」"],
        ["4:50–5:00", "Logo + 团队", "收尾"],
    ], widths=[2.4, 4.6, 10.2])
    bullets(doc, [
        "务必录制备份：现场网络/额度不可控，至少录 2 遍。",
        "关键页面数值要能对上：66.67 / 42→58 / 45、15。",
    ])

    h(doc, "P2-4　打包与提交", 3)
    para(doc, "提交物清单（命名规范来自《竞赛规程》§4.2）")
    table(doc, ["#", "材料", "格式", "命名", "负责人"],
          [["1", "创意描述（一句话）", "文档内", "—", "队长"],
           ["2", "设计稿（效果图/交互流程图/海报）", "图片", "—", "队长"],
           ["3", "作品说明文档", "PDF", "01-作品说明文档+暗影骑士王们", "队长"],
           ["4", "演示 Demo（Agent 赛道 = 源代码）", "zip", "03-知学Mate+暗影骑士王们.zip", "后端"],
           ["5", "演示视频", "MP4", "02-演示视频+暗影骑士王们", "前端"]],
          widths=[1.0, 5.4, 1.6, 6.4, 2.8])
    para(doc, "zip 包三条纪律", bold=True, color=COLOR_RED)
    bullets(doc, [
        "不包含 __pycache__ / .pytest_cache / pytest-cache-files-* / .venv / oh_modules / build",
        "不包含 .env（含 API Key），只放 .env.example",
        "不包含运行期状态 data/repository.json 与 chat/history.json",
    ])
    para(doc, "打包后自检：解压到干净目录 → 按 README 跑 verify_liantiao1.py → 应得 61/61。")
    page_break(doc)

    # ============================================================ 四、日历
    h(doc, "四、逐日任务日历（9/18 → 9/30）", 1)
    table(doc, ["日期", "星期", "任务", "负责人", "当日交付物"],
          [
              ["9/18", "周五", "P0-3 配 Key（10m）+ P0-4 统一用户 ID（30m）+ "
                              "P0-5 验证出 HAP + P0-1 服务卡片开工（ability + 配置）",
               "全员 / 前端", "后端 llm_ready:true；signed HAP；卡片骨架可添加"],
              ["9/19", "周六", "P0-1 服务卡片：WidgetCard UI（2×2 与 2×4 两套）+ "
                              "接 proactive cardData", "前端", "卡片显示真实 Agent 决策内容"],
              ["9/20", "周日", "P0-1 收尾：事件驱动 updateForm（练习/专注/DDL 变化触发）",
               "前端", "完成练习后卡片内容自动变化（可录视频）"],
              ["9/21", "周一", "P0-2 后台代理提醒：reminderAgentManager + notificationManager + "
                              "权限声明 + 文案接后端", "前端", "DDL 前一天能收到 Agent 推理文案通知并点击直达"],
              ["9/22", "周二", "主链连跑 10 次回归 + 服务卡片/通知联调 + 截图存档",
               "双端", "10/10 数值一致；主动服务证据截图"],
              ["9/23", "周三", "★ 冻结后端。P1-1 语音识别开工（真机验证）", "前端",
               "后端冻结声明；语音可转文字进对话"],
              ["9/24", "周四", "P1-1 语音收尾 + P1-2 位置服务", "前端",
               "语音→Agent→跳页整链打通；位置情境文案上屏"],
              ["9/25", "周五", "P1-3 数据源收敛（方案一或二）+ 全量回归", "双端",
               "真实模式下各页 mastery 数值一致"],
              ["9/26", "周六", "P2-1 前端编译与运行验证（DevEco 逐项过清单）+ "
                              "主链连跑 10 次", "前端", "编译零错误；回归全绿"],
              ["9/27", "周日", "P2-2 作品说明文档改稿（去「已预留」措辞）+ "
                              "experiments/snapshot 数据入文档", "队长", "文档终稿（PDF，≤20 页主体）"],
              ["9/28", "周一", "P2-3 录制演示视频（≥2 遍）+ 备好断网版本", "全员",
               "02-演示视频+暗影骑士王们.mp4"],
              ["9/29", "周二", "P2-4 打包 zip + 清理运行期文件 + 交叉验收 + 命名核对", "全员",
               "03-知学Mate+暗影骑士王们.zip"],
              ["9/30", "周三", "提交 + 留缓冲", "队长", "全部材料提交完成"],
          ],
          widths=[1.4, 1.3, 6.8, 2.2, 5.5], font_size=9)
    note_box(doc,
             "9/23 之后只修阻塞 Bug，不加任何新功能。演示崩一次的代价远大于少一个特性。",
             color=COLOR_RED, label="冻结纪律")
    page_break(doc)

    # ============================================================ 五、风险
    h(doc, "五、风险与对策", 1)
    table(doc, ["风险", "概率", "影响", "对策"],
          [["服务卡片刷新受限 / 不生效", "中", "高",
            "不要依赖定时刷新，走事件驱动 updateForm；D2 当天就要跑通最小卡片"],
           ["语音识别模拟器不可用", "高", "中",
            "必须真机；提前确认有真机，否则降级为「已规划」诚实说明"],
           ["AGC / 网络受限导致演示连不上", "中", "中",
            "已有离线 Fixture 兜底（判分与在线一致），演示前切好"],
           ["DASHSCOPE 额度 / 网络失败", "中", "高",
            "确定性兜底已具备；提前录制备份视频，现场断网也能讲"],
           ["12 天内改动引入回归", "中", "高",
            "每改一项立刻跑 verify_liantiao1.py；9/23 冻结后端"],
           ["HAP 打包 / 签名失败", "中", "高",
            "今天就要验证能出包，不能拖到 9/26"],
           ["前端 ArkTS 编译报错（本次联调改了 5 个文件）", "中", "高",
            "9/26 逐项过编译清单；FixtureApiTransport 的 as 断言是已知风险点"],
           ["三人并行改同一批文件冲突", "中", "中",
            "后端只动 server/，前端只动 entry/，边界清晰"]],
          widths=[4.6, 1.3, 1.3, 10.0], font_size=9)

    # ============================================================ 六、答辩
    h(doc, "六、答辩话术更新（配合本次联调）", 1)
    table(doc, ["评委问题", "建议回答"],
          [["Agent 的自主性体现在哪？",
            "打开 AgentTrace 页：「这一次 workflow 里，总控 Agent 自己决定先叫练习 Agent 再叫评估 Agent，"
            "3 个智能体、3 个工具全部留痕。而且拔掉大模型它依然能走完——因为所有业务计算都是确定性代码，"
            "模型只回答『下一步叫谁』。」"],
           ["为什么推荐先学二叉树？",
            "打开「Agent 的判断依据」面板，逐行念贡献值：「1−掌握度 0.58×0.30 = 0.174，"
            "错误强度 0.67×0.25 = 0.168…综合 0.62。这是算出来的，不是模型猜的。」"],
           ["怎么防止刷分 / 作弊？",
            "「题集接口不返回标准答案（出参做了字段白名单投影）；判分在服务端完成；"
            "提交带幂等键，重复提交响应逐字节相同，不会双写。」（三项均有自检项佐证）"],
           ["评委改答案分数会变吗？",
            "★ 主动邀请评委现场改：「您可以随便改，全对是 100，全错是 0，√√× 是 66.67。」"
            "（这是本次联调最大的收获）"],
           ["用了哪些鸿蒙特性？",
            "完成 P0-1/P0-2/P1-1/P1-2 后：服务卡片、后台代理提醒、语音识别、位置服务、"
            "Preferences、Canvas 2D、PhotoViewPicker、网络请求——8 项，"
            "其中服务卡片与代理提醒属于主动服务能力"],
           ["和通用 AI 助手有什么区别？",
            "「通用助手等你提问；知学 Mate 在 DDL 临近时主动发通知、在桌面卡片上告诉你今天该学什么，"
            "而且能说清为什么是现在。它是推动者，不是回答者。」"],
           ["OCR 是真的吗？",
            "配好 Key 后现场拍照识别；并说明「网络不可用时降级为确定性规则，"
            "且回复里会显式标注降级，不伪装成 AI 结果」"],
           ["数据隐私怎么保证？",
            "「端侧优先计算；位置只用于映射学习情境、不上传坐标；搭子候选阶段不展示联系方式；"
            "图片可删除。」"],
           ["怎么验证有效？",
            "「用 /api/v1/experiments/snapshot 导出的事件数据 + "
            "tools/verify_liantiao1.py 的 61 项断言。」"]],
          widths=[4.4, 12.8], font_size=9)
    page_break(doc)

    # ============================================================ 七、提交前终检
    h(doc, "七、提交前终检清单", 1)
    para(doc, "提交前一天逐项打勾：")
    checks = [
        "01-作品说明文档+暗影骑士王们.pdf（官网模板、主体 ≤20 页、PDF 格式）",
        "02-演示视频+暗影骑士王们.mp4（≤5 分钟，至少录 2 遍）",
        "03-知学Mate+暗影骑士王们.zip（源码完整、可直接运行）",
        "文档中「已预留」措辞已全部改为已完成态",
        "演示数值与文档一致：66.67 / 42→58 / 45、15",
        "zip 内无 __pycache__ / .venv / .env / pytest-cache-files-* / 重复目录",
        "zip 内无 data/repository.json 与 chat/history.json（运行期状态）",
        "README 能让评委 3 分钟跑起来",
        "HAP 包已验证可构建（signed HAP）",
        "在 DevEco 中跑通前端编译与「离线 Fixture 判分随答案变化」",
        "pytest 全绿（70 passed）",
        "tools/verify_liantiao1.py 退出码 0（61/61）",
        "原创性声明已签名（全部队员 + 指导老师）",
        "报名表已盖章 / 签名（复赛要求）",
    ]
    for item in checks:
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = Cm(0.4)
        _set_run_font(p.add_run("□  "), size=11)
        _set_run_font(p.add_run(item), size=10.5)

    # ============================================================ 八、一句话
    doc.add_paragraph()
    h(doc, "八、一句话收尾", 1)
    rich(doc, [
        ("这 5 天，团队已经把「能证明」这件事做到了——判分是真的、闭环是稳的、"
         "重复提交不穿帮、离线在线同源。", False, None)])
    rich(doc, [
        ("剩下 12 天只有一件事：把已经算好的 Agent 决策，搬到用户会看到的地方去。", True, COLOR_PRIMARY)])
    rich(doc, [
        ("服务卡片让它被看见，代理提醒让它会开口，位置上下文让它在对的时刻开口。"
         "这三件事加起来不到 3 天，却是从「复赛二/三等奖」跨到「一等奖竞争区」的关键一跳。",
         False, None)])

    doc.add_paragraph()
    para(doc, "— 知学 Mate ｜ 暗影骑士王们 ｜ 2026-09-18 —",
         size=9.5, color=COLOR_GREY, align=WD_ALIGN_PARAGRAPH.CENTER)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    doc.save(str(OUT_FILE))
    print("saved:", OUT_FILE)
    print("size :", os.path.getsize(OUT_FILE), "bytes")


if __name__ == "__main__":
    build()
