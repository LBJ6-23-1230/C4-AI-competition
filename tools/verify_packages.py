# -*- coding: utf-8 -*-
"""复核两个交付压缩包的内容（独立脚本，避免 shell 转义问题）。"""

import sys
import zipfile
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
OUT = ROOT / "deliverables"

FORBIDDEN = ("__pycache__", ".pytest-tmp", "/build/", "oh_modules",
             ".hvigor/", ".idea/", "/.git/")


def is_forbidden(name: str) -> bool:
    """判断某个 zip 条目是否属于"不该出现"的类别。

    ⚠️ `.env` 要精确判断 —— 用 `'/.env' in name` 会把
    `.env.example` 一起误伤（实测），而那是**模板，必须随包下发**。
    """
    if any(token in name for token in FORBIDDEN):
        return True
    basename = name.rsplit("/", 1)[-1]
    return basename == ".env" or basename.startswith(".env.")


def check(archive: Path, required: list[str]) -> bool:
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()

    print(f"\n{'=' * 70}")
    print(f"  {archive.name}  ({archive.stat().st_size / 1024:.0f} KB, {len(names)} 条目)")
    print("=" * 70)

    bad = [n for n in names if is_forbidden(n) and not n.endswith(".env.example")]
    print(f"  违规条目（应排除却存在）: {len(bad)}")
    for item in bad[:8]:
        print(f"      ⚠️ {item}")

    print(f"  必需文件检查：")
    ok = True
    for rel in required:
        present = any(n.endswith(rel) for n in names)
        if not present:
            ok = False
        print(f"      {'OK  ' if present else 'MISS'}  {rel}")

    print(f"  分类统计：")
    stats = {
        "*.ets": sum(1 for n in names if n.endswith(".ets")),
        "*.py": sum(1 for n in names if n.endswith(".py")),
        "*.md": sum(1 for n in names if n.endswith(".md")),
        "*.json/.json5": sum(1 for n in names if n.endswith((".json", ".json5"))),
    }
    for key, value in stats.items():
        if value:
            print(f"      {key:16} {value}")

    return ok and not bad


def main() -> int:
    frontend = OUT / "liantiao5-frontend.zip"
    backend = OUT / "liantiao5-backend.zip"

    frontend_required = [
        "app/build-profile.json5",
        "app/hvigorfile.ts",
        "app/oh-package.json5",
        "app/AppScope/app.json5",
        "app/entry/build-profile.json5",
        "app/entry/src/main/module.json5",
        "app/entry/src/main/ets/pages/Login.ets",
        "app/entry/src/main/ets/pages/KnowledgeBase.ets",
        "app/entry/src/main/ets/services/HuaweiAccountService.ets",
        "app/entry/src/main/ets/services/ProactiveSurfaceService.ets",
        # 意图框架（本轮新增能力）：执行器 + profile 声明文件
        "app/entry/src/main/ets/insightintent/StartFocusIntent.ets",
        "app/entry/src/main/ets/insightintent/QueryTodayPlanIntent.ets",
        "app/entry/src/main/resources/base/profile/insight_intent.json",
        "app/entry/src/main/resources/base/profile/form_config.json",
        "app/entry/src/main/resources/base/profile/main_pages.json",
        "app/entry/src/test/AgentBridge.test.ets",
        # 本轮新增
        "app/entry/src/main/ets/api/TokenCipher.ets",
        "app/entry/src/main/ets/utils/DeviceLayout.ets",
        "app/entry/src/test/DeviceLayout.test.ets",
        "docs/01-联调分析报告.md",
        "docs/02-下一步工作清单.md",
        "app/contracts/openapi.json",
        "contracts/openapi.json",
        "docs/17-前端同学任务书.md",
        "docs/18-技术改进实施报告.md",
        "docs/19-未完成事项清单.md",
        "README.md",
    ]
    backend_required = [
        "server/zhixue-agent-server/run.py",
        "server/zhixue-agent-server/app/__init__.py",
        "server/zhixue-agent-server/app/api/identity.py",
        "server/zhixue-agent-server/app/api/knowledge.py",
        "server/zhixue-agent-server/app/auth/service.py",
        "server/zhixue-agent-server/tests/conftest.py",
        "server/zhixue-agent-server/tests/test_identity_isolation.py",
        "server/zhixue-agent-server/tests/test_auth_phone_huawei.py",
        # 验证码登录（本轮新增能力）
        "server/zhixue-agent-server/tests/test_auth_verification_code.py",
        "server/zhixue-agent-server/tests/test_knowledge.py",
        # 本轮新增
        "server/zhixue-agent-server/app/agent/semantic.py",
        "server/zhixue-agent-server/app/repositories/sqlite_repository.py",
        "server/zhixue-agent-server/tests/test_semantic_search.py",
        "server/zhixue-agent-server/tests/test_sqlite_backend.py",
        "server/zhixue-agent-server/tests/test_technical_improvements.py",
        "server/zhixue-agent-server/data/repository.json",
        "server/zhixue-agent-server/.env.example",
        "server/zhixue-agent-server/tests/test_chat_history_redirect.py",
        "docs/21-后端同学完成报告_2026-09-21.md",
        "contracts/openapi.json",
        "integration/run_liantiao5.py",
        "integration/verify_integration.py",
        # 本轮新增的联调工具
        "tools/sync_contract.py",
        "tools/clean_repository.py",
        "tools/migrate_repository.py",
        "tools/patch_contract_semantic.py",
        "docs/16-后端同学任务书.md",
        "docs/18-技术改进实施报告.md",
        "docs/19-未完成事项清单.md",
        "README.md",
    ]

    a = check(frontend, frontend_required)
    b = check(backend, backend_required)

    print(f"\n{'=' * 70}")
    print(f"  前端包: {'PASS' if a else 'FAIL'}    后端包: {'PASS' if b else 'FAIL'}")
    print("=" * 70)
    return 0 if (a and b) else 1


if __name__ == "__main__":
    raise SystemExit(main())
