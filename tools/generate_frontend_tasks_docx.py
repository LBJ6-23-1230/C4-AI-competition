"""生成文档 2：前端同学 · 下一步工作总任务文件。

用法：python tools/generate_frontend_tasks_docx.py
输出：deliverables/02-前端同学下一步工作总任务文件.docx
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from docx_kit import (COLOR_GREEN, COLOR_GREY, COLOR_ORANGE, COLOR_PRIMARY,
                      COLOR_RED, add_title, bullets, code, h, new_document,
                      note_box, page_break, para, save, table)


def build() -> Path:
    doc = new_document()

    add_title(doc, "前端同学 · 下一步工作总任务文件",
              "知学 Mate ｜ 2026-09-18 → 09-30 ｜ 责任人：周玥妍（HarmonyOS 原生开发）"
              " ｜ 赛道：鸿蒙 · Agent 创新方向")

    # =====================================================================
    h(doc, "〇、你的目标与本文件用法", 1)
    para(doc, "一句话目标：把后端已经算好的 Agent 决策，搬到用户看得见的地方去——"
              "做成桌面服务卡片与系统通知，让 Agent 从「等你打开」变成「主动出现」。")
    note_box(doc,
             "创新性占 50 分，是唯一的主战场。官方对 Agent 方向的原话是"
             "「结合位置、时间、拍照、对话历史等用户上下文信息，让 AI 主动出现在对的时刻」。"
             "上下文数据后端已经算好了，缺的是触达手段——这一块全部在你手上。",
             color=COLOR_PRIMARY, label="你的战场")

    h(doc, "你明确不负责什么（避免越界改动）", 2)
    bullets(doc, [
        "不改后端算法：判分、掌握度、优先级、重规划都是确定性代码，有回归断言守着。",
        "不改契约：contracts/openapi.json 由联调负责人改，且两份契约必须 sha256 逐字节一致。",
        "不改锁死的值，见 §一 的红线清单。",
        "不在 9/25 之后加新功能——那时进入冻结期，只修阻塞 Bug。",
    ])

    page_break(doc)

    # =====================================================================
    h(doc, "一、现状：工程底座已完成，你的起点很好", 1)

    h(doc, "1.1 当前前端规模（实测）", 2)
    table(doc,
          ["项", "数量", "说明"],
          [
              ["页面（pages/*.ets）", "18", "含本轮新增的 Login / Account"],
              ["组件（components/*.ets）", "6", "AIFloatButton / ChatBubble / FactorBreakdownCard / "
                                            "FollowUpCard / PlanDiffCard / RadarChart"],
              ["服务（services/*.ets）", "4", "AgentBridge / ChatNavigation / FileParserService / LocalAgentService"],
              ["ViewModel", "6", "Exercise / Plan / Proactive / Profile / Trace / Workflow"],
              ["API 层", "10", "含本轮新增的 AuthModels / AuthResult / AuthStore / AuthClient"],
              ["当前状态", "—", "编译 BUILD SUCCESSFUL，已产出 HAP（1.76 MB，未签名）"],
          ],
          widths=[4.6, 1.6, 8.8])

    h(doc, "1.2 已完成的架构收敛（你可以依赖的部分）", 2)
    table(doc,
          ["能力", "状态", "你可以怎么用"],
          [
              ["单一 baseUrl", "✅ AgentApiClient 是唯一 HTTP 入口",
               "所有网络调用都走它，不要新增 httpRequest"],
              ["离线 Fixture", "✅ 判分规则与后端逐字节对齐",
               "断网演示时分数依然正确，可放心演示"],
              ["登录态", "✅ AuthStore + AuthClient 已就绪",
               "需要身份时读 appState.isSignedIn / authNickname"],
              ["四标签导航", "✅ 对话/智能体/学习/我的，互不重叠",
               "新增入口要归到唯一一个标签下，不要重复罗列"],
              ["FollowUpCard", "✅ 统一「接下来」组件",
               "每个终点页都用它收口，保证 Agent 循环不断"],
          ],
          widths=[3.6, 5.6, 5.8])

    h(doc, "1.3 红线：这些值改了会全线崩", 2)
    code(doc,
         'exercise-preorder-001  = "A"\n'
         'exercise-inorder-001   = "B"\n'
         'exercise-postorder-001 = "C"      ← 注意是 C，不是 A\n'
         '三题必须共用 knowledgePointId = "binary-tree-postorder"\n'
         '\n'
         '演示基线（改动会同时打破前后端两套自检）：\n'
         '  提交 √√×（A / B / A）  → 得分 66.67\n'
         '  掌握度                → 42 → 58\n'
         '  计划                  → V1 [30,30] → V2 [45,15]')
    note_box(doc,
             "这三个值前后端各存一份（后端 data/question_bank.json，"
             "前端 FixtureApiTransport.ANSWER_KEYS），改一个必须两边同时改，"
             "否则在线/离线分数对不上，演示会自相矛盾。",
             color=COLOR_RED, label="锁死值")

    page_break(doc)

    # =====================================================================
    h(doc, "二、你的任务清单（按优先级）", 1)

    h(doc, "P0-1　桌面服务卡片（1.5–2 天）★ 最高优先级", 2)
    para(doc, "做什么：新增 FormExtensionAbility，提供 2×2 与 2×4 两种尺寸的桌面卡片。")
    bullets(doc, [
        "2×2：显示「今日最优任务 + 建议时长」。",
        "2×4：多一行 Agent 理由（reason），这一行是答辩最强的一句话。",
        "点击卡片 → 直达 pages/FocusSetup，且任务已预填。",
    ])
    para(doc, "为什么：这是官方点名的「主动出现在对的时刻」最直接的实现，"
              "也是本次 12 天里投入产出比最高的一项。", bold=True)

    para(doc, "数据来源（后端已就绪，不要硬编码文案）：", bold=True)
    code(doc,
         'POST /api/v1/agent/proactive\n'
         '{\n'
         '  "shouldNotify": true,\n'
         '  "channel": "reminder",\n'
         '  "title": "数据结构考试还有 5 天",\n'
         '  "body": "你最近 3 天没有复习二叉树后序遍历，掌握度 42 偏低。",\n'
         '  "action": { "type": "focus", "label": "开始 45 分钟专注" },\n'
         '  "contextTags": ["考试 5 天", "掌握度 42", "3 天未复习"],\n'
         '  "reason": "考试剩 5 天（紧迫度贡献 0.080），后序遍历掌握度 42 偏低"\n'
         '}')

    para(doc, "三条工程纪律（容易踩坑，务必先读）：", bold=True)
    bullets(doc, [
        ("卡片是受限环境：ArkTS 卡片不能直接发起网络请求，也不能用大部分状态管理。"
         "正确做法是 EntryAbility / 后台任务算好后用 formProvider.updateForm 推送数据。", True),
        "卡片刷新有频率限制：不要依赖「每分钟刷新」。走事件驱动——用户完成专注、"
        "完成练习、DDL 变化时主动 updateForm。",
        "module.json5 需要补 forms 声明与 FormExtensionAbility 的 abilities 条目。",
    ])

    para(doc, "验收判据：", bold=True)
    bullets(doc, [
        "模拟器桌面能添加该卡片，两种尺寸都能正常渲染",
        "卡片内容来自 /api/v1/agent/proactive，改后端数据卡片会跟着变",
        "点击卡片跳转到 FocusSetup，任务已预填",
        "105 项自检仍然全绿（tools/verify_liantiao1.py）",
    ])

    h(doc, "P0-2　本地通知 / 代理提醒（0.5–1 天）", 2)
    para(doc, "做什么：DDL ≤2 天、或连续 2 天未学习时，Agent 主动发一条系统通知。")
    para(doc, "关键设计：通知文案由后端 /api/v1/agent/proactive 生成，前端只负责投递。"
              "响应里的 channel 字段已区分 reminder / silent，直接消费即可。")
    table(doc,
          ["触发条件", "通知文案（后端生成，前端不得硬编码）"],
          [
              ["DDL ≤2 天且未开始", "「{作业名} 还有 {N} 天截止，建议现在用 {M} 分钟开个头」"],
              ["连续 2 天未学习", "「你已经 2 天没来了，今天从 {最优任务} 开始只要 {M} 分钟」"],
              ["考试 ≤7 天且掌握度 <60", "「{课程} 考试还有 {N} 天，{知识点} 掌握度只有 {X}」"],
          ],
          widths=[4.6, 9.4])
    note_box(doc,
             "shouldNotify=false 时必须不发通知。一个会乱推送的 Agent 比不推送更糟——"
             "「在不对的时刻出现」直接违背官方要求。",
             color=COLOR_ORANGE, label="反向约束")

    h(doc, "P0-3　HAP 签名与装机验证（0.5 天）", 2)
    para(doc, "做什么：DevEco Studio → File → Project Structure → Signing Configs → "
              "勾选 Automatically generate signature，然后装到模拟器/真机。")
    para(doc, "为什么：附加分 20 分明确指向「实际可演示的 HAP 文件 / 源代码 / 演示系统」。"
              "当前 HAP 已能产出，但 build-profile.json5 里 signingConfigs 仍为空，属 unsigned。")
    para(doc, "验收判据：带签名的 HAP 能安装并正常启动，无「签名校验失败」。")

    h(doc, "P1-1　语音输入落地（1–1.5 天）", 2)
    para(doc, "做什么：接入 @kit.CoreSpeechKit 或 speechRecognizer，"
              "把 ChatMain 里那个占位语音按钮换成真实识别。")
    para(doc, "当前状态（实测）：ChatMain.ets:645 的文案是"
              "「语音输入需要真机支持。你可以直接打字，或者拍照上传错题～」——"
              "纯占位，没有任何 speech API 调用。")
    note_box(doc,
             "module.json5 已声明 ohos.permission.MICROPHONE 但没有对应实现。"
             "这是「声明了权限却不用」的规范性问题：要么补实现，要么删权限。"
             "两件事必须做一件。",
             color=COLOR_ORANGE, label="合规问题")
    para(doc, "验收判据：真机上点语音按钮能说话并转成文字进输入框；"
              "无权限时给出明确提示而不是静默失败。")

    h(doc, "P1-2　PartnerMatch 数据源收口（0.5–1 天）", 2)
    para(doc, "当前状态（实测）：PartnerMatch.ets:25 直接置 "
              "realModeUnavailable = !useFixture —— 也就是说联机模式下这个页面"
              "明确承认「不可用」。")
    para(doc, "两个选项，选一个：", bold=True)
    bullets(doc, [
        "选项 A（推荐，成本低）：在联机模式下把该页做成明确的「离线演示能力」说明页，"
        "而不是保留一个存在但不可用的哑状态。",
        "选项 B（成本高）：等后端补匹配接口后全部走后端。当前后端没有这个接口。",
    ])
    para(doc, "为什么必须处理：评委若问「这个匹配是谁算的」，"
              "答「前端 TypeScript 里的函数」会削弱 Agent 叙事。"
              "至少要让界面上的说法与实现一致。")

    h(doc, "P2　文档与演示（1 天）", 2)
    table(doc,
          ["#", "事项", "完成判据"],
          [
              ["P2-1", "作品说明文档改稿（前端章节）",
               "无「已预留 / Mock 演示」措辞；界面截图更新为当前 18 页面版本"],
              ["P2-2", "演示视频录制（前端部分）",
               "覆盖服务卡片 → 点击 → 专注页 → 语音输入"],
              ["P2-3", "界面截图存档", "桌面卡片、通知、语音三张新截图入库"],
          ],
          widths=[1.6, 6.4, 10.0])

    page_break(doc)

    # =====================================================================
    h(doc, "三、逐日排期（你负责的格子）", 1)
    table(doc,
          ["日期", "星期", "你的任务", "当日交付物"],
          [
              ["9/19", "五", "服务卡片技术调研 + FormExtensionAbility 骨架", "卡片能渲染静态内容"],
              ["9/20", "六", "卡片接 proactive 数据 + 2×4 尺寸", "卡片显示今日任务与 reason"],
              ["9/21", "日", "卡片点击跳转 + 事件驱动刷新", "卡片闭环可用"],
              ["9/22", "一", "本地通知投递", "通知可触发"],
              ["9/23", "二", "★ HAP 签名 + 装机验证", "带签名 HAP"],
              ["9/24", "三", "语音输入接入", "语音可用"],
              ["9/25", "四", "PartnerMatch 数据源收口", "哑状态消除"],
              ["9/26", "五", "演示脚本走查", "脚本定稿"],
              ["9/27", "六", "★ 演示视频录制（前端部分）", "视频素材"],
              ["9/28", "日", "作品说明文档改稿（前端章节）", "文档初稿"],
              ["9/29", "一", "★ 冻结：只修阻塞 Bug", "—"],
              ["9/30", "二", "配合打包提交", "★ 24:00 前提交"],
          ],
          widths=[1.8, 1.2, 6.4, 8.6])

    h(doc, "四、每晚必须自检的三条命令", 1)
    code(doc,
         '# 1. 编译（每次改完 .ets 都要跑，确认没破坏构建）\n'
         'node "D:\\DevEco\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.js" '
         '--mode module -p product=default assembleHap --no-daemon\n'
         '\n'
         '# 2. 全量自检 105 项（含契约一致性、无硬编码地址、文件齐备性）\n'
         'python tools\\verify_liantiao1.py --start-server\n'
         '\n'
         '# 3. 确认关键产物还在（DevEco 部署要用，不要删 build 目录）\n'
         'dir entry\\build\\default\\outputs\\default\\*.hap')
    note_box(doc,
             "绝对不要删除 entry/build 目录。曾经因为编译后清理 build 目录，"
             "导致 DevEco 部署报「Error opening file ... entry-default-unsigned.hap」。"
             "要清理请用 DevEco 的 Build → Clean Project。",
             color=COLOR_RED, label="踩过的坑")

    h(doc, "五、交付清单（Definition of Done）", 1)
    table(doc,
          ["#", "交付项", "判据"],
          [
              ["1", "桌面服务卡片", "两种尺寸在模拟器桌面可见，内容来自后端，点击可跳转"],
              ["2", "本地通知", "三种触发条件均可触发，shouldNotify=false 时不发"],
              ["3", "带签名 HAP", "能安装并启动，无签名错误"],
              ["4", "语音输入", "真机可说话转文字进输入框"],
              ["5", "PartnerMatch 收口", "联机模式下界面说法与实现一致，无哑状态"],
              ["6", "权限合规", "MICROPHONE 权限有实现，或已删除"],
              ["7", "回归全绿", "105/105 通过；HAP 仍能产出"],
              ["8", "截图存档", "卡片 / 通知 / 语音三张新截图"],
          ],
          widths=[1.2, 4.6, 10.2])

    h(doc, "六、你需要向后端索取/交付的固定清单", 1)
    table(doc,
          ["方向", "内容", "时点"],
          [
              ["索取", "proactive 响应里 cardData 字段的最终结构（卡片要用）", "9/19 前"],
              ["索取", "三种通知触发条件的后端判定口径确认", "9/21 前"],
              ["索取", "PartnerMatch 是否补后端接口的最终决定", "9/24 前"],
              ["交付", "卡片消费的字段清单（若需后端补字段）", "9/20 前"],
              ["交付", "前端章节的说明文档改稿", "9/28 前"],
          ],
          widths=[1.8, 9.6, 2.6])

    para(doc, "")
    para(doc, "文档版本：v1.0 ｜ 生成日期：2026-09-18 ｜ "
              "对应工程：E:\\C4-liantiao\\liantiao1（编译 BUILD SUCCESSFUL）",
         size=9.5, color=COLOR_GREY)

    return save(doc, "02-前端同学下一步工作总任务文件.docx")


if __name__ == "__main__":
    print(f"OK -> {build()}")
