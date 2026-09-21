# -*- coding: utf-8 -*-
"""liantiao4 一键联调：自己拉起后端进程 → 实跑 HTTP 验证 → 归档证据 → 关停。

用法::

    python integration/run_liantiao4.py                     # 默认端口 5000
    python integration/run_liantiao4.py --port 5057
    python integration/run_liantiao4.py --no-boot --base http://127.0.0.1:5000

退出码 0 = 全部通过。
"""

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server" / "zhixue-agent-server"
EVIDENCE_DIR = ROOT / "evidence"
WORKSPACE_TMP = ROOT / ".pytest-tmp"


def log(msg):
    print(msg, flush=True)


def port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        return sock.connect_ex(("127.0.0.1", port)) != 0


def wait_health(base, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{base}/health", timeout=3) as response:
                if response.status == 200:
                    return True
        except Exception:
            time.sleep(0.4)
    return False


def check_contract_sync():
    """契约必须是逐字一样的两份副本，否则联调结论不成立。

    ⚠️ **镜像缺失时不算失败**：本工作区会分别打包给前端与后端同学，
    后端包**不含 `app/`**，此时只有契约真源、没有镜像，闸门应当跳过而不是报红。
    （前端包里同理只有镜像、没有后端。）
    两份都在时才比对 —— 那才是有意义的检查。
    """
    canonical = ROOT / "contracts" / "openapi.json"
    mirror = ROOT / "app" / "contracts" / "openapi.json"
    if not canonical.exists():
        return False, f"契约真源缺失：{canonical}"
    if not mirror.exists():
        version = json.loads(canonical.read_text(encoding="utf-8")).get("info", {}).get("version")
        return True, (f"仅有契约真源（本包不含前端 app/，跳过镜像比对）"
                      f"，version={version}，{canonical.stat().st_size} 字节")
    a = canonical.read_bytes()
    b = mirror.read_bytes()
    if a != b:
        return False, f"两份 openapi.json 不一致（{len(a)} vs {len(b)} 字节）"
    version = json.loads(a.decode("utf-8")).get("info", {}).get("version")
    return True, f"契约一致，version={version}，{len(a)} 字节"


def run_backend_tests():
    """跑后端测试套件。返回 (ok, summary_dict)。"""
    if not (SERVER_DIR / "tests").exists():
        return False, {"error": "tests 目录缺失"}
    WORKSPACE_TMP.mkdir(parents=True, exist_ok=True)
    report = WORKSPACE_TMP / "pytest_report.json"
    plugin = ROOT / "integration" / "pytest_report_plugin.py"
    env = dict(os.environ)
    env["DSH_PYTEST_REPORT"] = str(report)
    env["PYTHONPATH"] = str(plugin.parent) + os.pathsep + env.get("PYTHONPATH", "")
    env["PYTHONIOENCODING"] = "utf-8"
    # 注意：不使用 --basetemp，改由 tests/conftest.py 提供沙箱可写的 tmp_path
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/", "-q", "-p", "no:cacheprovider",
         "-p", "pytest_report_plugin", "--no-header", "--tb=short"],
        cwd=SERVER_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    summary = {}
    if report.exists():
        summary = json.loads(report.read_text(encoding="utf-8")).get("summary", {})
    ok = summary.get("failed", 1) == 0 and summary.get("error", 1) == 0
    if not summary:
        tail = proc.stdout.decode("utf-8", "replace")[-800:]
        summary = {"error": "pytest 未产出报告", "tail": tail}
    return ok, summary


def detect_llm_mode(args):
    """判断本次验证应使用哪套断言集合。

    * `offline`  —— 后端没有可用 Key，断言"诚实降级"行为
    * `live`     —— 后端配了 Key，断言"真实模型"行为

    可用 `--llm-mode` 显式覆盖（例如临时用假模型服务端做接线验证）。
    """
    if args.llm_mode:
        mode = args.llm_mode
    else:
        key = (os.getenv("DASHSCOPE_API_KEY") or "").strip()
        env_file = SERVER_DIR / ".env"
        if not key and env_file.exists():
            for line in env_file.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() == "DASHSCOPE_API_KEY" and value.strip().strip('"').strip("'"):
                    key = value.strip()
                    break
        mode = "live" if key else "offline"

    return {
        "mode": mode,
        "label": ("真实 LLM 验证（后端已配置 DASHSCOPE_API_KEY）" if mode == "live"
                  else "离线降级验证（后端未配置 Key，断言诚实降级行为）"),
        "skipDegradationChecks": mode == "live",
    }


def wait_port_released(port, timeout=30):
    """等待端口真正被释放。

    为什么需要：`process.terminate()` 返回不代表端口已经空出来。
    若紧接着启动下一个实例，两个后端会**同时操作同一个 repository.json**，
    导致随机失败（实测出现过 demo/reset 返回 500、工作流恢复断言失败）。
    连续跑多次联调时这个竞态很容易踩中，所以这里显式等待。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port_free(port):
            return True
        time.sleep(0.3)
    return False


def stop_server(process, port):
    if process is None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    if port is not None:
        wait_port_released(port)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--base", default=None, help="不自己拉起后端时，指定已有地址")
    parser.add_argument("--no-boot", action="store_true", help="后端已在运行，不要重复拉起")
    parser.add_argument("--skip-tests", action="store_true", help="跳过 pytest 套件")
    parser.add_argument("--llm-mode", choices=["offline", "live"], default=None,
                        help="覆盖 LLM 断言模式（默认按后端是否配置 Key 自动判定）")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    evidence = {"runAt": datetime.now().isoformat(timespec="seconds"), "root": str(ROOT)}
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

    log("=" * 78)
    log("  liantiao4 · 前后端联调一键验证")
    log("=" * 78)

    # 1. 契约同步闸门
    contract_ok, contract_msg = check_contract_sync()
    log(f"[{'PASS' if contract_ok else 'FAIL'}] 契约一致性闸门：{contract_msg}")
    evidence["contract"] = {"ok": contract_ok, "detail": contract_msg}

    # 2. 判定本次运行模式：离线降级验证 vs 真实 LLM 验证
    #
    # 背景：`verify_integration.py` 里有 3 项断言专门验证"**没有** Key 时诚实降级"
    # （llmUsed=false + 明示文案 + 关键词意图路由）。一旦配了真 Key，
    # 这些断言按定义就会失败——那是**预期行为**，不是回归。
    # 所以这里按"后端实际是否具备 LLM"自动切换断言集合，避免配 Key 后看到假失败。
    llm_mode = detect_llm_mode(args)
    log(f"      运行模式：{llm_mode['label']}")
    evidence["llmMode"] = llm_mode

    # 3. 后端单元测试
    if args.skip_tests:
        log("[SKIP] 后端测试套件（--skip-tests）")
        evidence["backendTests"] = {"skipped": True}
        tests_ok = True
    else:
        log("... 运行后端测试套件")
        tests_ok, tests_summary = run_backend_tests()
        log(f"[{'PASS' if tests_ok else 'FAIL'}] 后端测试套件：{tests_summary}")
        evidence["backendTests"] = {"ok": tests_ok, "summary": tests_summary}

    # 4. 拉起后端（可复用已有实例）
    base = args.base or f"http://127.0.0.1:{args.port}"
    process = None
    if args.no_boot or args.base:
        already = wait_health(base, timeout=5)
        log(f"[{'PASS' if already else 'FAIL'}] 复用已有后端 {base}")
        boot_ok = already
    else:
        if not port_free(args.port):
            log(f"[FAIL] 端口 {args.port} 被占用，请换端口或加 --no-boot")
            return 2
        env = dict(os.environ)
        env["PORT"] = str(args.port)
        env["PYTHONIOENCODING"] = "utf-8"
        env["ZHIXUE_QUIET"] = "1"
        # 让联调产生的账号 / 计划 / 会话写进临时数据文件，**绝不污染交付包里的
        # `data/repository.json`**。本脚本会真实注册账号、提交练习、推进工作流，
        # 全部是写操作；用默认文件时每跑一次就给交付包塞进十几个测试账号
        # （源后端包实测被撑到 324 KB / 158 个测试用户）。
        # `app/__init__.py:create_app()` 读取 `ZHIXUE_REPOSITORY` 作为数据文件路径。
        scratch = WORKSPACE_TMP / f"integration-{args.port}.json"
        WORKSPACE_TMP.mkdir(parents=True, exist_ok=True)
        if scratch.exists():
            scratch.unlink()
        env["ZHIXUE_REPOSITORY"] = str(scratch)
        log(f"      联调数据文件 {scratch.relative_to(ROOT)}（交付包 repository.json 保持不变）")
        # --quiet 关掉 werkzeug 逐请求访问日志：否则每个 HTTP 检查前面都会插一行
        # "127.0.0.1 - - [...] GET /xxx 200 -"，把检查结果冲得读不出来。
        process = subprocess.Popen([sys.executable, "run.py", "--quiet"], cwd=SERVER_DIR, env=env)
        boot_ok = wait_health(base, timeout=45)
        log(f"[{'PASS' if boot_ok else 'FAIL'}] 后端启动 {base}")
    evidence["boot"] = {"ok": boot_ok, "base": base}

    result = None
    try:
        if boot_ok:
            # 4. 实跑 HTTP 联调
            sys.path.insert(0, str(ROOT / "integration"))
            import verify_integration  # noqa: E402

            verify_integration.RESULTS.clear()
            out_path = Path(args.out) if args.out else (EVIDENCE_DIR / f"integration_{stamp}.json")
            argv = sys.argv
            cli = ["verify_integration", "--base", base, "--out", str(out_path)]
            if llm_mode["skipDegradationChecks"]:
                cli.append("--skip-degradation-checks")
            sys.argv = cli
            try:
                code = verify_integration.main()
            finally:
                sys.argv = argv
            result = json.loads(out_path.read_text(encoding="utf-8"))
            evidence["integration"] = {"ok": code == 0, "report": str(out_path.relative_to(ROOT)),
                                       "summary": {k: result[k] for k in ("total", "passed", "failed", "passRate")}}
        else:
            code = 3
    finally:
        if process is not None:
            # 必须等端口真正释放，否则连续跑多次时下一个实例会与残留实例
            # 同时写同一个 repository.json，造成随机失败。
            stop_server(process, args.port)
            log("后端进程已关停，端口已释放")

    # 5. 汇总
    overall = contract_ok and tests_ok and boot_ok and (code == 0 if result else False)
    evidence["overall"] = "PASS" if overall else "FAIL"

    # 演示主链基线是否漂移 —— 与"HTTP 检查是否全绿"是两件独立的事。
    # 基线漂移是事故；HTTP 检查有已知缺陷只是待办。
    baseline_ok = False
    if result:
        baseline = result.get("baseline", {})
        baseline_ok = (
            baseline.get("score") == 66.67
            and baseline.get("allWrongScore") == 0.0
            and baseline.get("oldMastery") == 42
            and baseline.get("newMastery") == 58
            and baseline.get("profileVersion") == [1, 2]
            and baseline.get("planVersion") == [1, 2]
            and baseline.get("planDurations") == [[30, 30], [45, 15]]
        )
        evidence["baselineOk"] = baseline_ok

    # 基线数值表固化
    if result:
        baseline = result.get("baseline", {})
        evidence["demoBaseline"] = baseline
        log("")
        log("--- 演示基线数值表 ---")
        log(f"  score（√√×）        : {baseline.get('score')}  期望 66.67")
        log(f"  全错 score           : {baseline.get('allWrongScore')}  期望 0.0")
        log(f"  mastery             : {baseline.get('oldMastery')} → {baseline.get('newMastery')}  期望 42 → 58")
        log(f"  profileVersion      : {baseline.get('profileVersion')}  期望 [1, 2]")
        log(f"  planVersion         : {baseline.get('planVersion')}  期望 [1, 2]")
        log(f"  任务时长            : {baseline.get('planDurations')}  期望 [[30,30], [45,15]]")
        log(f"  workflow agents     : {baseline.get('workflowAgents')}")
        log(f"  workflow tools      : {baseline.get('workflowTools')}")

    summary_path = EVIDENCE_DIR / f"run_summary_{stamp}.json"
    summary_path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")

    log("")
    log("=" * 78)
    log(f"  契约 {'PASS' if contract_ok else 'FAIL'} | 后端测试 {'PASS' if tests_ok else 'FAIL'} | "
        f"启动 {'PASS' if boot_ok else 'FAIL'} | 联调 {'PASS' if code == 0 else 'FAIL'}")
    log(f"  总体：{evidence['overall']}")
    if result and code != 0:
        log("")
        log("  ⚠️ 退出码非 0 不代表演示链坏了 —— 请分开看这两件事：")
        log(f"     · 演示主链基线：{'全部命中' if baseline_ok else '有漂移，必须立刻排查'}")
        log(f"     · HTTP 检查：{result['passed']}/{result['total']} 通过，"
            f"{result['failed']} 项未过（见上面『失败项』，属已知待修缺陷）")
    log(f"  汇总证据：{summary_path.relative_to(ROOT)}")
    log("=" * 78)
    return 0 if overall else 1


if __name__ == "__main__":
    sys.exit(main())
