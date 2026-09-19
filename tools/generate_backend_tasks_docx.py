"""生成文档 3：后端同学 · 下一步工作总任务文件。

用法：python tools/generate_backend_tasks_docx.py
输出：deliverables/03-后端同学下一步工作总任务文件.docx
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from docx_kit import (COLOR_GREEN, COLOR_GREY, COLOR_ORANGE, COLOR_PRIMARY,
                      COLOR_RED, add_title, bullets, code, h, new_document,
                      note_box, page_break, para, save, table)


def build() -> Path:
    doc = new_document()

    add_title(doc, "后端同学 · 下一步工作总任务文件",
              "知学 Mate ｜ 2026-09-18 → 09-30 ｜ 责任人：黄恩博（Agent 逻辑与算法）"
              " ｜ 赛道：鸿蒙 · Agent 创新方向")

    # =====================================================================
    h(doc, "〇、你的目标与本文件用法", 1)
    para(doc, "一句话目标：后端已经不是短板了——10 项缺陷全部修复、90 个单测全绿、"
              "105 项自检全过。剩下 12 天你的核心任务是「把已有能力的价值榨干」，"
              "而不是再加功能。")
    note_box(doc,
             "你之前写的 B2（zhixue-agent-server）质量相当好——真 Agent 循环、工具注册表、"
             "确定性决策、trace、幂等、无 LLM 兜底全部可用。问题从来不在架构，而在「没接上」。"
             "现在接上了，并且它已经是全项目唯一的 /api/v1 真源。",
             color=COLOR_GREEN, label="先说结论")

    h(doc, "你明确不负责什么", 2)
    bullets(doc, [
        "不改前端界面与交互（除 P1-2 需要你出接口口径）。",
        "不改锁死的值，见 §一 红线清单。",
        "不重构架构——现在架构是对的，9/25 之后连新功能都不加。",
        "不改契约结构（字段增删必须先改 contracts/openapi.json，并重新冻结 sha256）。",
    ])

    page_break(doc)

    # =====================================================================
    h(doc, "一、现状：你的模块已经全部达标", 1)

    h(doc, "1.1 后端规模与结构（实测）", 2)
    table(doc,
          ["项", "内容"],
          [
              ["定位", "单进程 · 单端口 5000 · 唯一 /api/v1 真源"],
              ["代码规模", "64 个 .py 文件（含 app/ 下 11 个包）"],
              ["分层", "api（10 个）｜ agents（5 个）｜ decision（3 个）｜ domain（6 个）｜"
                       " tools（6 个）｜ runtime（4 个）｜ model_adapters（3 个）｜"
                       " repositories（3 个）｜ auth（2 个）｜ agent（2 个）"],
              ["核心接口", "18 个路径（含本轮新增的 5 个 /api/v1/auth/*）"],
              ["契约", "api-contract-v0.3，两份 openapi.json sha256 逐字节一致"],
              ["测试", "4 个测试文件 / 90 passed（test_domain_models 47 · test_auth 20 · "
                       "test_chat_llm 11 · test_proactive 6）"],
              ["题库", "data/question_bank.json：30 题 / 6 知识点 / 全部含 answerKey"],
          ],
          widths=[3.0, 12.0])

    h(doc, "1.2 十项缺陷修复状态（逐项已实测验证）", 2)
    table(doc,
          ["编号", "缺陷", "状态", "证据"],
          [
              ["B-1", "判分与答案无关（恒 67）", "✅ 已修",
               "assessment_tools.grade_exercise 按 answer_keys 逐题比对"],
              ["B-2", "题库缺失致判分恒 0", "✅ 已修", "30 题全部含 answerKey，锁定 A/B/C 正确"],
              ["B-3", "题集泄漏 answerKey", "✅ 已修",
               "exercise_tools._CLIENT_FIELDS 白名单投影"],
              ["B-4", "全错也涨掌握度", "✅ 已修",
               "四档：100→+29 / ≥60→+16 / ≥40→+4 / <40→−4，夹紧 0..100"],
              ["B-5", "重规划漂移", "✅ 已修",
               "_BASELINE_DURATIONS 锚定 V1，连跑 10 次稳定 45/15"],
              ["B-6", "两契约不一致", "✅ 已修", "冻结 v0.3，sha256 a6e58f90… 两份相同"],
              ["B-7", "两套后端并存", "✅ 已修", "合并单进程，B1 已并入 chat 子模块"],
              ["B-8", "前端双数据源", "🟡 部分", "真实模式主链已走后端；PartnerMatch 待收口"],
              ["B-9", "重复嵌套目录", "✅ 已修", "main 分支即完整工程"],
              ["B-10", "构建产物入库", "✅ 已修", ".gitignore + .gitattributes 钉死"],
          ],
          widths=[1.4, 4.0, 1.6, 8.0])

    h(doc, "1.3 红线：这些值改了会全线崩", 2)
    code(doc,
         '# data/question_bank.json —— 三个答案键锁死\n'
         'exercise-preorder-001  = "A"\n'
         'exercise-inorder-001   = "B"\n'
         'exercise-postorder-001 = "C"      ← 注意是 C，不是 A\n'
         '三题必须共用 knowledgePointId = "binary-tree-postorder"\n'
         '\n'
         '# 演示基线（105 项自检里有一整组断言守着）\n'
         'demo/reset            → 掌握度 42，Plan V1 时长 [30, 30]\n'
         '提交 √√×（A/B/A）      → score 66.67，掌握度 42 → 58\n'
         '重规划                → Plan V2 时长 [45, 15]，连跑 10 次不变\n'
         '游客身份              → 始终 demo-user')
    note_box(doc,
             "三题必须共用同一个 knowledgePointId。前端按 knowledgePointId 取题集，"
             "若拆成三个知识点，题集只会返回 1 道题（测试断言 len == 3 会挂）。",
             color=COLOR_RED, label="最容易踩的坑")

    h(doc, "1.4 你已具备的、别人没有的答辩素材", 2)
    table(doc,
          ["能力", "实测证据", "怎么用"],
          [
              ["真 Agent 循环", "单次 workflow 经 secretary → exercise → assessment，"
                               "trace 记录 3 事件 / 3 agent / 3 tool", "答辩现场打开 trace 讲自主性"],
              ["确定性兜底", "无 LLM 时两次运行 agent 序列完全一致",
               "「拔掉大模型也能跑完」是可验证的，不是宣传语"],
              ["不含思维链", "trace 无 reasoning / thoughts 字段", "符合竞赛红线"],
              ["幂等提交", "同一 idempotencyKey 重复提交返回逐字节相同响应",
               "演示可重复播放，不会第二次就露馅"],
              ["实验数据导出", "GET /api/v1/experiments/snapshot 返回 "
                              "evidences / planDiffs / submissions / traces",
               "★ 这是复赛「前景评估」章节的现成素材"],
              ["五因子可解释", "PriorityFactor 含 value / weight / contribution 三元组",
               "★ 评委可当场手算复现"],
          ],
          widths=[3.0, 7.6, 4.4])

    page_break(doc)

    # =====================================================================
    h(doc, "二、你的任务清单（按优先级）", 1)

    h(doc, "P0-1　配置 DASHSCOPE_API_KEY（10 分钟）★ 全场性价比最高", 2)
    para(doc, "做什么：在 server/zhixue-agent-server/.env 填入真实 DashScope Key。")
    code(doc,
         'cd server\\zhixue-agent-server\n'
         'Copy-Item .env.example .env\n'
         'notepad .env        # 填入 DASHSCOPE_API_KEY=sk-xxxx（真实 Key）')
    para(doc, "为什么：代码路径已经写好（chat_llm.py 已接 qwen-vl-plus），"
              "只差一个环境变量。配上之后「错题拍照 → Qwen-VL 真实识别」就能进演示视频，"
              "而不用再说「接口已预留」。")
    para(doc, "验收判据：启动日志显示「已配置 DASHSCOPE_API_KEY，走真实大模型」；"
              "/api/agent/health 返回 llm_ready=true；拍照上传能识别出知识点与错误类型。")
    note_box(doc,
             "未配 Key 时系统会主动标注「以上回复由本地确定性规则生成，不是大模型输出」"
             "（chat_llm.py 明确规定「不得伪装成真实 LLM 结果」）。"
             "这条设计本身是加分项，但演示视频里应该有真实识别画面。",
             color=COLOR_ORANGE, label="注意")

    h(doc, "P0-2　proactive 响应补充 cardData（0.5 天）", 2)
    para(doc, "做什么：前端要做服务卡片，需要 proactive 响应里有直接可渲染的结构化字段。")
    para(doc, "当前响应已有 shouldNotify / channel / title / body / action / contextTags / "
              "reason / factors。需要确认并补齐：")
    table(doc,
          ["字段", "用途", "状态"],
          [
              ["title / body", "卡片主文案", "✅ 已有"],
              ["action.type / label", "卡片点击行为与按钮文案", "✅ 已有"],
              ["reason", "2×4 卡片上那行 Agent 理由（答辩最值钱的一句）", "✅ 已有"],
              ["contextTags", "卡片上的上下文标签（考试 N 天 / 掌握度 X）", "✅ 已有"],
              ["cardData", "卡片渲染用的结构化数据（任务名、时长、知识点）", "🟡 需与前端对齐结构"],
          ],
          widths=[3.6, 8.4, 3.0])
    para(doc, "验收判据：与前端确认 cardData 最终结构后，写进 contracts/openapi.json "
              "的 ProactiveResponse schema，并保持两份契约 sha256 一致。")

    h(doc, "P0-3　通知触发规则的口径确认（0.5 天）", 2)
    para(doc, "做什么：前端要做系统通知，需要后端明确「什么时候该提醒」。"
              "当前 proactive.py 的判定是 days_left <= 7 and mastery_score < 80 and "
              "gap_days >= 2 and not focusSessionActive。需要把通知专用的三条规则补进去：")
    table(doc,
          ["触发条件", "建议判定口径", "优先级"],
          [
              ["DDL ≤2 天且未开始", "取最近的 pending 作业，daysLeft <= 2 且未开始",
               "高（最有说服力）"],
              ["连续 2 天未学习", "lastStudyAt 距今 >= 2 天", "高"],
              ["考试 ≤7 天且掌握度 <60", "daysLeft <= 7 且该知识点 masteryScore < 60", "中"],
          ],
          widths=[4.2, 7.4, 3.4])
    note_box(doc,
             "必须支持「不该提醒时不提醒」。shouldNotify=false 时前端不发通知。"
             "一个会乱推送的 Agent 比不推送更糟——「在不对的时刻出现」直接违背官方要求。",
             color=COLOR_RED, label="反向约束")

    h(doc, "P1-1　PartnerMatch 接口决策（0.5 天，二选一）", 2)
    para(doc, "背景：前端 PartnerMatch 在联机模式下直接置 realModeUnavailable=true，"
              "属于「承认未迁移」。这是 B-8 的唯一遗留项。")
    table(doc,
          ["方案", "内容", "成本", "建议"],
          [
              ["A 不做接口", "前端把该页明确标注为「离线演示能力」，界面说法与实现一致",
               "前端 0.5 天", "★ 推荐：12 天内性价比最高"],
              ["B 补接口", "新增 GET /api/v1/partners/match，把四因子匹配搬到后端",
               "后端 1.5 天 + 前端 1 天", "成本高，且要改契约"],
          ],
          widths=[2.6, 7.4, 2.6, 3.4])

    h(doc, "P1-2　Qwen-VL 识别链路稳定性（0.5 天）", 2)
    para(doc, "做什么：配好 Key 后，实测「拍照 → 识别」链路的成功率与耗时，"
              "确认超时与失败时的降级行为符合预期。")
    para(doc, "验收判据：连续 5 次拍照识别，成功率与耗时记录在案；"
              "断网时明确降级为确定性规则并标注，不静默伪装。")

    h(doc, "P2　回归、证据与文档（1.5 天）", 2)
    table(doc,
          ["#", "事项", "完成判据"],
          [
              ["P2-1", "主链连跑 10 次回归",
               "tools\\run_backend_core_regression.ps1 → 10/10 passed"],
              ["P2-2", "导出实验数据作前景评估素材",
               "GET /api/v1/experiments/snapshot 输出存档到 evidence/"],
              ["P2-3", "作品说明文档改稿（后端章节）",
               "删除「OCR / 大模型接口已预留」表述；补上五因子与确定性边界"],
              ["P2-4", "答辩素材准备：五因子手算演示",
               "整理 0.174 + 0.168 + 0.180 + 0.080 + 0.020 = 0.62 的逐项说明"],
          ],
          widths=[1.6, 6.4, 10.0])

    page_break(doc)

    # =====================================================================
    h(doc, "三、逐日排期（你负责的格子）", 1)
    table(doc,
          ["日期", "星期", "你的任务", "当日交付物"],
          [
              ["9/19", "五", "★ 配置 DASHSCOPE_API_KEY + 验证真实 LLM", "llm_ready=true"],
              ["9/20", "六", "proactive 响应补 cardData，与前端对齐结构", "cardData 字段冻结"],
              ["9/21", "日", "通知触发规则实现 + 单测补充", "三种条件可判定"],
              ["9/22", "一", "通知文案模板确认（与前端联调）", "文案定稿"],
              ["9/23", "二", "★ 主链连跑 10 次回归", "10/10 passed"],
              ["9/24", "三", "Qwen-VL 识别链路稳定性实测", "成功率 / 耗时记录"],
              ["9/25", "四", "PartnerMatch 方案定稿（A 或 B）", "决策记录"],
              ["9/26", "五", "接口稳定性检查 + 异常路径回归", "无回归"],
              ["9/27", "六", "备份演示视频录制（配合前端）", "后端素材"],
              ["9/28", "日", "作品说明文档改稿（后端章节）", "文档初稿"],
              ["9/29", "一", "★ 冻结：只修阻塞 Bug", "—"],
              ["9/30", "二", "配合打包提交", "★ 24:00 前提交"],
          ],
          widths=[1.8, 1.2, 6.4, 8.6])

    h(doc, "四、每晚必须自检的三条命令", 1)
    code(doc,
         '# 1. 单元测试（90 passed 是基线，不许降）\n'
         'cd server\\zhixue-agent-server\n'
         'python -m pytest -q tests/ --basetemp=..\\..\\.ptbase\n'
         '\n'
         '# 2. 全量自检 105 项（契约一致性、演示基线、鉴权、Agent 循环）\n'
         'python tools\\verify_liantiao1.py --start-server\n'
         '\n'
         '# 3. 主链连跑 10 次（复赛硬要求）\n'
         'powershell -ExecutionPolicy Bypass -File tools\\run_backend_core_regression.ps1')
    note_box(doc,
             "本机直接跑 pytest 可能因沙箱临时目录限制出现 PermissionError 干扰项，"
             "那是环境噪声不是代码问题。用 --basetemp 指到工程内目录即可看到真实结果。",
             color=COLOR_ORANGE, label="环境提示")

    h(doc, "五、交付清单（Definition of Done）", 1)
    table(doc,
          ["#", "交付项", "判据"],
          [
              ["1", "真实大模型可用", "/api/agent/health → llm_ready=true；拍照可识别"],
              ["2", "cardData 结构冻结", "写入 contracts/openapi.json，两份契约 sha256 一致"],
              ["3", "通知触发规则", "三种条件可判定，shouldNotify=false 时不提醒"],
              ["4", "PartnerMatch 决策落地", "方案 A 或 B 已执行，无哑状态"],
              ["5", "回归全绿", "90 passed；105/105 通过；主链 10/10"],
              ["6", "实验数据导出", "experiments/snapshot 输出存档"],
              ["7", "文档改稿", "后端章节无「已预留」表述"],
              ["8", "答辩素材", "五因子手算说明 + trace 截图"],
          ],
          widths=[1.2, 4.6, 10.2])

    h(doc, "六、你需要向前端索取/交付的固定清单", 1)
    table(doc,
          ["方向", "内容", "时点"],
          [
              ["交付", "proactive 响应 cardData 最终结构（前端卡片要用）", "9/20 前"],
              ["交付", "三种通知触发条件的判定口径确认", "9/21 前"],
              ["交付", "通知文案模板（前端不得硬编码）", "9/22 前"],
              ["决策", "PartnerMatch 是否补接口的最终结论", "9/25 前"],
              ["索取", "卡片消费了哪些字段（若需后端补字段）", "9/20 前"],
          ],
          widths=[1.8, 9.6, 2.6])

    para(doc, "")
    para(doc, "文档版本：v1.0 ｜ 生成日期：2026-09-18 ｜ "
              "对应工程：E:\\C4-liantiao\\liantiao1\\server\\zhixue-agent-server"
              "（90 passed，自检 105/105）",
         size=9.5, color=COLOR_GREY)

    return save(doc, "03-后端同学下一步工作总任务文件.docx")


if __name__ == "__main__":
    print(f"OK -> {build()}")
