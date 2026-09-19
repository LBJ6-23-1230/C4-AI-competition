"""把联调工程切分为「前端包」与「后端包」两个 zip，便于分别交给前后端同学。

用法：
    python tools/make_handoff_zips.py

输出（handoff/ 目录）：
    知学Mate-前端工程-暗影骑士王们.zip
    知学Mate-后端工程-暗影骑士王们.zip
    交付说明-给前端同学.txt
    交付说明-给后端同学.txt
"""

import sys
import zipfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "handoff"

# ---------------------------------------------------------------- 排除规则
SKIP_DIR_NAMES = {
    "__pycache__", ".git", ".idea", ".verify-tmp", ".verify-tmp2",
    ".pt", ".ptbase", ".pytest_cache", "node_modules", "oh_modules",
    ".dsh-module-fallback", "handoff",
}


def _skip(path: Path) -> bool:
    if any(part in SKIP_DIR_NAMES for part in path.parts):
        return True
    if path.suffix in {".pyc", ".pyo"}:
        return True
    name = path.name
    if name.endswith((".log",)) or name.startswith("~$"):
        return True
    return False


def _collect(items: list[Path]) -> list[tuple[Path, str]]:
    """展开文件列表 -> [(绝对路径, zip 内相对路径)]"""
    out: list[tuple[Path, str]] = []
    for item in items:
        if not item.exists():
            continue
        if item.is_file():
            if not _skip(item):
                out.append((item, item.relative_to(ROOT).as_posix()))
            continue
        for f in sorted(item.rglob("*")):
            if not f.is_file():
                continue
            rel = f.relative_to(ROOT)
            if _skip(rel):
                continue
            out.append((f, rel.as_posix()))
    return out


def _write_zip(zip_path: Path, entries: list[tuple[Path, str]], banner: str) -> tuple[int, int]:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for src, rel in entries:
            zf.write(src, rel)
        # 包内说明放在最前便于解压后第一眼看到
        zf.writestr("【先读我】交付说明.txt", banner)
    total = sum(s.stat().st_size for s, _ in entries)
    return len(entries), total


# ---------------------------------------------------------------- 前端包
FRONT_LETTER = """知学 Mate · 前端工程包（交给前端同学：周玥妍）
================================================================

一、解压后怎么跑起来
----------------------------------------------------------------
1. 用 DevEco Studio 打开【本目录】（解压后的根目录，不是 entry/）
2. 菜单 File → Sync and Refresh Project
3. 配置签名：File → Project Structure → Signing Configs
   → 勾选 Automatically generate signature
4. 选 entry 模块，运行到模拟器 / 真机

若 Sync 报找不到 SDK：本包已带 local.properties（sdk.dir 指向本机
D:\\DevEco\\DevEco Studio\\sdk）。换了电脑则改这一行，或设环境变量
DEVECO_SDK_HOME。

二、先读哪份文档（本包 docs/ 与 deliverables/ 内）
----------------------------------------------------------------
★ 必读：deliverables/02-前端同学下一步工作总任务文件.docx
   —— 你的任务清单、逐日排期、验收判据、每晚自检命令，全在里面。

配套：
  docs/03-联调说明与验收记录.md      联调做了什么、怎么验收
  docs/04-Agent运行界面信息架构_v2.md 界面结构与四标签语义
  docs/06-初赛文档与当前实现比对.md    与初赛文档的差异（改稿时要用）
  deliverables/01-下一步工作总任务文件.docx   全团队总任务线
  deliverables/05-原始版本与当前版本对比评估.docx 原版 vs 当前
  deliverables/ui_wireframes/          6 张界面线框图
  README.md                            工程总说明

三、你接下来要做的四件事（详见任务文件）
----------------------------------------------------------------
1. 桌面服务卡片（FormExtensionAbility，2×2 / 2×4）★ 最高优先级
2. 本地通知 / 代理提醒（触发规则由后端判定，前端只投递）
3. HAP 签名 + 装机验证
4. 语音输入落地（现在只是占位按钮，且已声明麦克风权限却无实现）

四、红线：这些值改了会全线崩
----------------------------------------------------------------
exercise-preorder-001  = "A"
exercise-inorder-001   = "B"
exercise-postorder-001 = "C"      ← 注意是 C，不是 A
三题必须共用 knowledgePointId = "binary-tree-postorder"

演示基线：提交 √√×（A/B/A）→ 得分 66.67 → 掌握度 42→58 → 计划 V1[30,30]→V2[45,15]
前端 FixtureApiTransport.ANSWER_KEYS 与后端题库各存一份，改一个必须两边同改。

五、每晚自检
----------------------------------------------------------------
# 1. 编译
node "D:\\DevEco\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.js" ^
     --mode module -p product=default assembleHap --no-daemon

# 2. 全量自检 105 项（需先起后端：tools\\start_dev.ps1）
python tools\\verify_liantiao1.py --start-server

★ 不要删除 entry\\build 目录——DevEco 部署要用它。
   要清理请用 DevEco 的 Build → Clean Project。

六、包内已包含
----------------------------------------------------------------
entry/          前端主模块（含 entry/build 编译产物与 HAP，1.76 MB）
AppScope/       应用级配置
contracts/      接口契约 openapi.json（前后端唯一真源，只读参考）
tools/          前端回归与 UI 流程脚本 + 文档生成脚本
docs/           工程文档
deliverables/   任务文件与线框图
build-profile.json5 / oh-package.json5 / hvigorfile.ts / hvigor/  构建配置
local.properties  SDK 路径（机器本地配置）
"""

# ---------------------------------------------------------------- 后端包
BACK_LETTER = """知学 Mate · 后端工程包（交给后端同学：黄恩博）
================================================================

一、解压后怎么跑起来
----------------------------------------------------------------
cd server\\zhixue-agent-server

# 首次：准备 Python 3.12 环境（工程用 str | Path 语法，3.8 跑不起来）
uv venv ..\\..\\.venv-lt --python 3.12
uv pip install --python ..\\..\\.venv-lt\\Scripts\\python.exe ^
    flask flask-cors "openai>=1.0.0" python-dotenv pytest

# 配置大模型（可选但强烈建议；不配也能跑，聊天层降级为确定性规则）
Copy-Item .env.example .env
notepad .env          # 填入 DASHSCOPE_API_KEY=sk-xxxx

# 启动
..\\..\\.venv-lt\\Scripts\\python.exe run.py
# → http://0.0.0.0:5000

也可以回到工程根目录用一键脚本：
powershell -ExecutionPolicy Bypass -File tools\\start_dev.ps1

二、先读哪份文档（本包 docs/ 与 deliverables/ 内）
----------------------------------------------------------------
★ 必读：deliverables/03-后端同学下一步工作总任务文件.docx
   —— 你的任务清单、逐日排期、验收判据、每晚自检命令，全在里面。

配套：
  docs/03-联调说明与验收记录.md      联调做了什么、怎么验收
  docs/06-初赛文档与当前实现比对.md    判断层从三因子改为五因子的完整对照
  deliverables/01-下一步工作总任务文件.docx   全团队总任务线
  deliverables/05-原始版本与当前版本对比评估.docx 原版 vs 当前（含 10 项缺陷验证）
  contracts/README.md                契约使用说明
  README.md                          工程总说明

三、你接下来要做的五件事（详见任务文件）
----------------------------------------------------------------
1. 配置 DASHSCOPE_API_KEY（10 分钟，全场性价比最高）★
2. proactive 响应补 cardData（前端服务卡片要用，结构需与前端对齐）
3. 通知触发规则实现（后端判定「该不该提醒」，前端只投递）
4. PartnerMatch 是否补 /api/v1/partners/match 接口 —— 需给前端最终结论
5. 主链连跑 10 次回归 + 导出 experiments/snapshot 作前景评估素材

四、红线：这些值改了会全线崩
----------------------------------------------------------------
# data/question_bank.json —— 三个答案键锁死
exercise-preorder-001  = "A"
exercise-inorder-001   = "B"
exercise-postorder-001 = "C"      ← 注意是 C，不是 A
三题必须共用 knowledgePointId = "binary-tree-postorder"

# 演示基线（105 项自检里有一整组断言守着）
demo/reset       → 掌握度 42，Plan V1 时长 [30, 30]
提交 √√×（A/B/A）→ score 66.67，掌握度 42 → 58
重规划           → Plan V2 时长 [45, 15]，连跑 10 次不变
游客身份         → 始终 demo-user

★ 三题必须共用同一 knowledgePointId。前端按它取题集，
  拆成三个知识点则题集只返回 1 道题（测试断言 len == 3 会挂）。

五、每晚自检
----------------------------------------------------------------
# 1. 单元测试（90 passed 是基线，不许降）
cd server\\zhixue-agent-server
python -m pytest -q tests/ --basetemp=..\\..\\.ptbase

# 2. 全量自检 105 项
python tools\\verify_liantiao1.py --start-server

# 3. 主链连跑 10 次（复赛硬要求）
powershell -ExecutionPolicy Bypass -File tools\\run_backend_core_regression.ps1

★ 本机直接跑 pytest 可能出现 PermissionError 干扰项，那是沙箱临时目录
  限制造成的环境噪声。用 --basetemp 指到工程内目录即可看到真实结果。

六、包内已包含
----------------------------------------------------------------
server/zhixue-agent-server/   后端全部代码
  app/api/          10 个路由模块（含 auth）
  app/agents/       5 个认知职能智能体
  app/decision/     五因子优先级 / 掌握度规则 / 重规划规则
  app/domain/       6 个领域模型
  app/tools/        6 个确定性工具
  app/runtime/      Agent 循环 / 编排 / 会话 / 工具注册表
  app/repositories/ JSON 与 SQLite 双实现（换库只改一行）
  app/auth/         鉴权领域逻辑
  app/agent/        chat_llm（Qwen-VL）+ proactive（主动决策）
  chat/prompts/     7 个 Prompt 模板 + mock 数据
  data/             题库（30 题）与 repository.json
  tests/            90 个单元测试
contracts/      接口契约 openapi.json（前后端唯一真源）
tools/          回归 / 契约校验 / 自检脚本 + 文档生成脚本
evidence/       verify_result.json（105 项自检原始输出）
docs/           工程文档
deliverables/   任务文件
"""


def build() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    # ---------------- 前端
    front_items = [
        ROOT / "entry", ROOT / "AppScope", ROOT / "contracts",
        ROOT / "tools", ROOT / "docs", ROOT / "deliverables",
        ROOT / "build-profile.json5", ROOT / "code-linter.json5",
        ROOT / "hvigorfile.ts", ROOT / "oh-package.json5",
        ROOT / "oh-package-lock.json5", ROOT / "hvigor",
        ROOT / "local.properties", ROOT / ".gitignore",
        ROOT / ".gitattributes", ROOT / "README.md",
    ]
    front_entries = _collect(front_items)
    # 前端包里去掉纯后端脚本与后端专用文档，避免混淆
    drop_exact = {
        "tools/start_dev.ps1", "tools/run_backend_core_regression.ps1",
        "docs/02-登录界面设计与用户数据库方案.md",
        "deliverables/03-后端同学下一步工作总任务文件.docx",
    }
    front_entries = [(s, r) for s, r in front_entries if r not in drop_exact]
    fz = OUT / "知学Mate-前端工程-暗影骑士王们.zip"
    fn, fb = _write_zip(fz, front_entries, FRONT_LETTER)

    # ---------------- 后端
    back_items = [
        ROOT / "server", ROOT / "contracts", ROOT / "tools",
        ROOT / "docs", ROOT / "deliverables", ROOT / "evidence",
        ROOT / ".gitignore", ROOT / ".gitattributes", ROOT / "README.md",
    ]
    back_entries = _collect(back_items)
    drop_back = {
        "tools/run_app_startup_smoke.ps1", "tools/run_fixture_ui_flow.ps1",
        "tools/run_focus_ui_flow.ps1", "tools/run_local_feature_ui_flow.ps1",
        "tools/run_ohos_regression.ps1", "tools/run_ui_navigation_smoke.ps1",
        "deliverables/02-前端同学下一步工作总任务文件.docx",
        "deliverables/ui_wireframes/01_home.png",
        "deliverables/ui_wireframes/02_suggestion.png",
        "deliverables/ui_wireframes/03_wrong_question.png",
        "deliverables/ui_wireframes/04_tags.png",
        "deliverables/ui_wireframes/05_match.png",
        "deliverables/ui_wireframes/wireframe_contact_sheet.png",
    }
    back_entries = [(s, r) for s, r in back_entries if r not in drop_back]
    bz = OUT / "知学Mate-后端工程-暗影骑士王们.zip"
    bn, bb = _write_zip(bz, back_entries, BACK_LETTER)

    # ---------------- 说明也单独落一份，便于直接发消息
    (OUT / "交付说明-给前端同学.txt").write_text(FRONT_LETTER, encoding="utf-8")
    (OUT / "交付说明-给后端同学.txt").write_text(BACK_LETTER, encoding="utf-8")

    print(f"前端包：{fz.name}")
    print(f"  文件 {fn} 个 | 原始 {fb/1024/1024:.2f} MB | 压缩后 {fz.stat().st_size/1024/1024:.2f} MB")
    print(f"后端包：{bz.name}")
    print(f"  文件 {bn} 个 | 原始 {bb/1024/1024:.2f} MB | 压缩后 {bz.stat().st_size/1024/1024:.2f} MB")
    print(f"\n输出目录：{OUT}")


if __name__ == "__main__":
    build()
