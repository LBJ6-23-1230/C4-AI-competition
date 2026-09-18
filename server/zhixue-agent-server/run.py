# -*- coding: utf-8 -*-
"""知学 Mate · 统一后端启动入口（联调收敛后为单一进程、单一端口）。

一个进程同时提供两层能力：

* 自然语言层 —— `POST /api/agent/chat`（LLM 意图识别 + 6 路子 Agent + Qwen-VL 识图）
* 结构化工作流层 —— `/api/v1/**`（真 Agent 循环 + 确定性判分 + 五因子决策 + trace）

启动::

    python run.py                 # 默认 http://0.0.0.0:5000
    $env:PORT=5001; python run.py # 换端口
    python run.py --check         # 只做自检并打印配置，不启动服务

环境变量（可写在同目录 `.env`，参考 `.env.example`）::

    DASHSCOPE_API_KEY   DashScope Key；不配置则聊天层降级为确定性规则（不会伪装成 LLM 输出）
    LLM_BASE_URL        默认 https://dashscope.aliyuncs.com/compatible-mode/v1
    LLM_MODEL           默认 qwen-vl-plus
    PORT                默认 5000
"""

import argparse
import os
import sys


def _load_env_file(path: str) -> None:
	"""极简 .env 解析：不覆盖已存在的真实环境变量。"""
	if not os.path.exists(path):
		return
	with open(path, "r", encoding="utf-8") as stream:
		for line in stream:
			line = line.strip()
			if not line or line.startswith("#") or "=" not in line:
				continue
			name, value = line.split("=", 1)
			value = value.strip().strip('"').strip("'")
			os.environ.setdefault(name.strip(), value)


_HERE = os.path.dirname(os.path.abspath(__file__))
_load_env_file(os.path.join(_HERE, ".env"))

from app import CONTRACT_VERSION, create_app  # noqa: E402  (必须在 .env 载入之后)

_CONTRACT_HINT = "api-contract-v0.3"


def _banner(app) -> None:
	key_ready = bool(os.getenv("DASHSCOPE_API_KEY", "").strip())
	port = int(os.getenv("PORT", "5000"))
	print("=" * 72)
	print("  知学 Mate · 统一后端（B1 + B2 已合并为单一真源）")
	print("=" * 72)
	print(f"  契约版本   : {CONTRACT_VERSION}")
	print(f"  监听地址   : http://0.0.0.0:{port}")
	print(f"  聊天层     : POST /api/agent/chat   (GET /api/agent/health 探针)")
	print(f"  工作流层   : /api/v1/demo|workflows|profile|plans|exercises|traces|agent/proactive|experiments")
	llm_line = ("已配置 DASHSCOPE_API_KEY，走真实大模型" if key_ready
				else "未配置 Key —— 聊天层降级为确定性规则（不伪装成 LLM 输出）")
	print(f"  LLM        : {llm_line}")
	print(f"  API Key 头 : X-API-Contract-Version: {_CONTRACT_HINT}")
	print("-" * 72)
	print("  前端 baseUrl 提示：")
	print("    · HarmonyOS 模拟器 / Android 模拟器 -> http://10.0.2.2:5000")
	print("    · HarmonyOS 真机（同一 WiFi）        -> http://<开发机局域网IP>:5000")
	print("    · 桌面预览 / 本机浏览器              -> http://127.0.0.1:5000")
	print("    可在 App 的「接口环境」页里直接修改并持久化。")
	print("=" * 72)


if __name__ == "__main__":
	parser = argparse.ArgumentParser(description="知学 Mate 统一后端")
	parser.add_argument("--check", action="store_true", help="只做配置自检，不启动服务")
	parser.add_argument("--port", type=int, default=int(os.getenv("PORT", "5000")))
	args = parser.parse_args()

	os.environ["PORT"] = str(args.port)
	application = create_app()
	_banner(application)

	if args.check:
		sys.exit(0)

	application.run(host="0.0.0.0", port=args.port, debug=False)
