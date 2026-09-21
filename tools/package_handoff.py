# -*- coding: utf-8 -*-
"""把 liantiao5 拆成「前端包 / 后端包」两个独立压缩包。

设计原则
--------
1. **各自自包含**：每人拿到手就能开工，不需要另一个包
2. **不含产物与依赖**：`entry/build`、`oh_modules`、`.hvigor`、`__pycache__`
   都是可再生的，打进去只会让包大 20 倍
3. **不含敏感信息**：`.env`、token、密钥一律排除，并在打包前**断言**
4. **契约双方都有**：前端只有镜像（`app/contracts/`），后端只有真源
   （`contracts/`），两侧的 `check_contract_sync()` 都已容错
5. **任务书按角色分发**：前端只拿前端相关的文档，避免信息过载

用法::

    python tools/package_handoff.py            # 生成两个 zip
    python tools/package_handoff.py --keep     # 保留中间 staging 目录（便于检查）
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "deliverables"
STAGE = ROOT / ".packaging"

VERSION = "liantiao5"

# 目录级排除（任何一层匹配即跳过）
EXCLUDE_DIRS = {
    "__pycache__", ".pytest-tmp", ".pytest_cache", ".idea", ".vscode",
    "node_modules", "oh_modules", ".hvigor", "build", ".cxx", ".git",
    "pytest-tmp", ".packaging", "deliverables", ".uv-cache",
}
# 文件级排除
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".tmp", ".bak", ".log", ".hap", ".har"}
EXCLUDE_NAMES = {".env", ".DS_Store", "Thumbs.db", "history.json"}
# 敏感内容断言：这些串不允许出现在任何被打包的文件里。
#
# ⚠️ 不要把裸 `sk-` 当特征 —— 它会命中 `task-postorder` 之类的普通字段
# （实测误报了 7 个 fixture 与测试文件）。真正的 DashScope key 是
# `sk-` 后跟 16 位以上字母数字，用这个形态判断才不会误伤。
ENV_KEY_ASSIGNMENT = "DASHSCOPE_API_KEY="
SECRET_KEY_RE = re.compile(r"sk-[A-Za-z0-9]{16,}")
#: 文档里允许出现的示例占位形态
PLACEHOLDER_HINTS = ("xxxxxxxx", "sk-你的", "sk-xxxx")


def _iter_files(base: Path):
    for path in base.rglob("*"):
        if not path.is_file():
            continue
        if any(part in EXCLUDE_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in EXCLUDE_SUFFIXES:
            continue
        if path.name in EXCLUDE_NAMES:
            continue
        yield path


def copy_tree(src: Path, dst: Path, *, skip_top: set[str] | None = None) -> int:
    """把 src 复制到 dst，按排除规则过滤。返回复制文件数。"""
    skip_top = skip_top or set()
    count = 0
    for path in _iter_files(src):
        rel = path.relative_to(src)
        if rel.parts and rel.parts[0] in skip_top:
            continue
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        count += 1
    return count


def copy_docs(dst: Path, names: list[str]) -> int:
    """只复制指定文档（按角色分发，避免信息过载）。"""
    dst.mkdir(parents=True, exist_ok=True)
    count = 0
    for name in names:
        src = ROOT / "docs" / name
        if src.exists():
            shutil.copy2(src, dst / name)
            count += 1
        else:
            print(f"  [WARN] 文档缺失：{name}")
    return count


def assert_no_secrets(stage: Path) -> None:
    """打包前断言：不得含 `.env`，不得含真实密钥。

    判定规则（避免误报）：
    * 文件名是 `.env` → 直接失败
    * 非文档文件中出现 `DASHSCOPE_API_KEY=` → 失败（说明有人写了真实配置）
    * 出现 `sk-` + 16 位以上字母数字 → 失败
      （文档里的 `sk-xxxxxxxx` 这类占位符会被排除）
    """
    problems: list[str] = []
    for path in stage.rglob("*"):
        if not path.is_file():
            continue
        if path.name == ".env":
            problems.append(f"发现 .env：{path.relative_to(stage)}")
            continue
        # `.env.example` 是**模板**，必须随包下发（后端同学照着它建 .env）。
        # 它里面只有占位符，不是秘密。
        if path.name == ".env.example":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if any(hint in text for hint in PLACEHOLDER_HINTS):
            # 该文件里只有示例占位符，跳过密钥形态检查
            continue
        if path.suffix.lower() not in {".md", ".txt"} and ENV_KEY_ASSIGNMENT in text:
            problems.append(f"{path.relative_to(stage)} 出现 {ENV_KEY_ASSIGNMENT}")
        if SECRET_KEY_RE.search(text):
            problems.append(f"{path.relative_to(stage)} 含疑似真实密钥（sk-****）")
    if problems:
        raise SystemExit("[FAIL] 打包前敏感信息检查未通过：\n  " + "\n  ".join(problems))
    print("  [OK] 敏感信息检查通过（无 .env、无真实密钥）")


FRONTEND_README = """# 知学 Mate · 前端工作包（{version}）

> **收件人**：前端同学
> **生成日期**：见压缩包内文件时间
> **基线**：后端 207/207 测试 · HTTP 联调 82/82 · 演示基线 12/12 无漂移

## 这个包里有什么

```
app/                      HarmonyOS ArkTS 工程（你可以直接构建）
  entry/src/main/ets/     源码：pages / services / api / viewmodels / components
  entry/src/test/         前端单测（hypium）
  contracts/openapi.json  接口契约**镜像**（后端真源的副本，逐字相同）
  docs/                   前端回归检查清单、测试方案、小样本体验表
  deliverables/           UI 线框图 PNG
contracts/openapi.json    契约真源副本（方便你对照字段）
docs/                     给你的任务书与相关报告
```

**包里没有**（都是可再生的，避免包体过大）：
`entry/build/`（编译产物，含 HAP）、`oh_modules/`、`.hvigor/`、`.idea/`、`.vscode/`

## 怎么开始

1. **读 `docs/17-前端同学任务书.md`** —— 这是你的工作清单，含验收标准
2. **在 DevEco Studio 里打开 `app/`** —— 目标 SDK 是 API 24（DevEco 6.1.1）
3. **第一件事：Build 一次**。本工程此前编译通过（0 ERROR / 90 WARN），
   但联调侧改过 16 个文件且**无法在本环境编译验证**，需要你确认。

## 你需要知道的关键约定

| 约定 | 说明 |
|---|---|
| 后端地址 | `ApiDefaults.DEFAULT_BASE_URL`，单一真源。模拟器 `10.0.2.2:5000`，真机用开发机局域网 IP |
| 契约头 | 所有 `/api/v1/**` 请求带 `X-API-Contract-Version: api-contract-v0.3` |
| 契约只读 | **不要直接改** `app/contracts/openapi.json`（它是镜像，由联调负责人同步） |
| 身份 | 读自己数据用 `appState.currentUser.userId`，**不要写死 demo-user** |

## 待你完成的（详见任务书）

| 优先级 | 事项 |
|---|---|
| 🔴 | **重新 Build + 真机验证**（16 处改动未编译） |
| 🟠 | 通知 `wantAgent` 深链（复用卡片已有参数协议） |
| 🟠 | 真实模式任务完成度恒 0% |
| 🟡 | 意图框架（2 个意图，鸿蒙 Agent 方向最对口） |

## 需要真机/外部配置的事

* **华为账号一键登录**：需 AppGallery Connect 配 `client_id` + 签名指纹，
  缺任何一条都会失败（代码会把失败原因原样展示，不假装成功）
* **语音识别**：模拟器通常不可用，提前准备降级话术
* **通知深链**：需真机验证点击后是否落到目标页
"""

BACKEND_README = """# 知学 Mate · 后端工作包（{version}）

> **收件人**：后端同学
> **基线**：后端 207/207 测试（真实 LLM 连跑 10 次一致）· HTTP 联调 82/82 · 演示基线 12/12 无漂移

## 这个包里有什么

```
server/zhixue-agent-server/   后端唯一真源（Flask，单进程提供两层）
  app/api/                      REST 端点
  app/agent/                    自然语言层（LLM 意图识别 + 多模态）
  app/runtime/                  工作流层（真 Agent 循环）
  app/auth/                     鉴权（手机号验证码 / 华为账号）
  app/tools/ app/decision/      确定性计算（判分、优先级、重规划）
  tests/                        207 项测试 + conftest.py
  data/                         question_bank.json + repository.json
contracts/openapi.json          ★ 契约真源（权威）
integration/                    一键联调脚本
tools/                          契约补丁与审计工具
docs/                           给你的任务书与相关报告
evidence/                       最近一次联调证据
```

**包里没有**：`app/`（前端工程）、`__pycache__`、`.env`、`.pytest-tmp`。
**注意**：联调脚本已处理"无前端目录"的情况（契约闸门会跳过镜像比对）。

## 怎么开始

1. **读 `docs/16-后端同学任务书.md`** —— 你的工作清单
2. 启动服务：

```powershell
cd server\\zhixue-agent-server
$env:PORT = "5000"
& <你的python> run.py
```

3. 跑一键自检（**从包根目录执行**）：

```powershell
& <你的python> integration\\run_liantiao5.py --port 5297
```

它会依次做：契约闸门 → 207 项测试 → 拉起服务 → 82 项 HTTP 验证 → 归档证据。
**退出码 0 = 可以合并。**

## 你需要知道的关键约定

| 约定 | 说明 |
|---|---|
| 契约 | `contracts/openapi.json` 是**真源**；前端那份是镜像，改完两边要一致 |
| 身份解析 | 统一走 `app/api/identity.py` 的 `resolve_user_id()`，不要自己写 `args.get("userId")` |
| 演示基线 | `66.67` / `全错 0.0` / `42→58` / `planVersion [1,2]` / 时长 `[[30,30],[45,15]]` **六个数字不可漂移** |
| 测试命令 | `python -m pytest tests/ -q` —— **不要加 `--basetemp`**（会抛 PermissionError） |
| `run.py` / `conftest.py` | 由联调负责人维护，改动前请先沟通 |

## 本轮工作清单

| 状态 | 事项 |
|---|---|
| ✅ | 工作流评估写入 `submissions`，`replanRate` 改用 `plan_histories` 口径 |
| ✅ | 手机号验证码接口：哈希存储、60 秒限流、24 小时上限、5 次锁定、开发模式回显 |
| ✅ | 真实 LLM 文本与多模态链路验证通过，均返回 `llmUsed=true` |
| ✅ | 10 次真实 LLM 端到端稳定性验证：`207/207`、`82/82`、基线无漂移 |
| ⬜ | 接收方需自行配置 `DASHSCOPE_API_KEY`（`.env` 不会进入交付包） |
| 不适用 | 当前交付包不含 `archive/`，无需清理死代码 |
"""


def build_frontend() -> Path:
    stage = STAGE / f"{VERSION}-frontend"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    print("[前端包] 复制 app/ ...")
    count = copy_tree(ROOT / "app", stage / "app")
    print(f"  app/ → {count} 个文件")
    print("[前端包] 复制契约 ...")
    (stage / "contracts").mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "contracts" / "openapi.json", stage / "contracts" / "openapi.json")
    print("[前端包] 复制文档 ...")
    docs = [
        "17-前端同学任务书.md",
        "01-联调分析报告.md",
        "02-下一步工作清单.md",
        "18-技术改进实施报告.md",
        "19-未完成事项清单.md",
        "20-token加密API核验报告.md",
        "13-全场景与华为账号登录方案.md",
        "12-知识库设计方案.md",
        "11-用户登录体系方案.md",
        "07-鸿蒙特性审计报告.md",
        "08-前端静态Bug排查报告.md",
        "10-全项目审计与Bug修复总结.md",
    ]
    n = copy_docs(stage / "docs", docs)
    print(f"  {n} 份文档")
    (stage / "README.md").write_text(FRONTEND_README.format(version=VERSION), encoding="utf-8")
    return stage


def build_backend() -> Path:
    stage = STAGE / f"{VERSION}-backend"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    print("[后端包] 复制 server/ ...")
    count = copy_tree(ROOT / "server", stage / "server")
    print(f"  server/ → {count} 个文件")
    for name in ("contracts", "integration", "tools", "evidence"):
        src = ROOT / name
        if src.exists():
            c = copy_tree(src, stage / name)
            print(f"  {name}/ → {c} 个文件")
    print("[后端包] 复制文档 ...")
    docs = [
        "16-后端同学任务书.md",
        "01-联调分析报告.md",
        "02-下一步工作清单.md",
        "21-后端同学完成报告_2026-09-21.md",
        "18-技术改进实施报告.md",
        "19-未完成事项清单.md",
        "20-token加密API核验报告.md",
        "11-用户登录体系方案.md",
        "12-知识库设计方案.md",
        "13-全场景与华为账号登录方案.md",
        "05-大模型接入检查报告.md",
        "06-后端配置LLM任务单.md",
        "09-后端Bug排查报告.md",
        "10-全项目审计与Bug修复总结.md",
    ]
    n = copy_docs(stage / "docs", docs)
    print(f"  {n} 份文档")
    (stage / "README.md").write_text(BACKEND_README.format(version=VERSION), encoding="utf-8")
    return stage


def zip_stage(stage: Path) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    archive = OUT / f"{stage.name}.zip"
    if archive.exists():
        archive.unlink()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(stage.parent))
    return archive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="保留 staging 目录")
    args = parser.parse_args()

    # 先清理会污染包体的残留
    for pattern in ("docs/_probe",):
        target = ROOT / pattern
        if target.exists():
            shutil.rmtree(target)
            print(f"[清理] 移除测试残留 {pattern}")

    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)

    print("=" * 72)
    frontend = build_frontend()
    assert_no_secrets(frontend)
    print()
    backend = build_backend()
    assert_no_secrets(backend)

    print("=" * 72)
    frontend_zip = zip_stage(frontend)
    backend_zip = zip_stage(backend)

    print("\n生成结果：")
    for archive in (frontend_zip, backend_zip):
        size = archive.stat().st_size / 1024 / 1024
        with zipfile.ZipFile(archive) as bundle:
            files = len(bundle.namelist())
        print(f"  {archive.name}")
        print(f"      {files} 个条目 / {size:.2f} MB")
        print(f"      {archive}")

    if not args.keep:
        shutil.rmtree(STAGE)
        print("\n（staging 目录已清理；加 --keep 可保留以便检查）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
