"""Provider-neutral Qwen-compatible adapter wrapper."""

from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from collections.abc import Callable, Mapping
import json
import os
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from typing import Any

from app.model_adapters.llm import ModelAdapter, ModelAdapterError


class QwenAdapter(ModelAdapter):
	def __init__(self, completion: Callable[[Mapping[str, Any]], str] | None = None,
				 timeout_seconds: float = 8, api_key: str | None = None,
				 base_url: str | None = None, model: str | None = None) -> None:
		self.completion = completion
		self.timeout_seconds = timeout_seconds
		self.api_key = api_key if api_key is not None else os.getenv("DASHSCOPE_API_KEY", "")
		self.base_url = (base_url or os.getenv(
			"LLM_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")).rstrip("/")
		self.model = model or os.getenv("LLM_MODEL", "qwen-plus")

	@classmethod
	def from_environment(cls) -> "QwenAdapter | None":
		try:
			from dotenv import load_dotenv
			load_dotenv()
		except ImportError:
			pass
		if not os.getenv("DASHSCOPE_API_KEY", "").strip():
			return None
		return cls()

	def _http_completion(self, state: Mapping[str, Any]) -> str:
		if not self.api_key.strip():
			raise ModelAdapterError("model API key is not configured")
		payload = {
			"model": self.model,
			"messages": [
				{"role": "system", "content": (
					"你是学习工作流决策器。只返回 JSON，不要 markdown。"
					"JSON 必须包含 step，取值为 diagnosis、planner、exercise、assessment 或 finish。"
				)},
				{"role": "user", "content": json.dumps(dict(state), ensure_ascii=False)},
			],
			"temperature": 0,
			"response_format": {"type": "json_object"},
		}
		request = Request(
			f"{self.base_url}/chat/completions",
			data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
			headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
			method="POST",
		)
		try:
			with urlopen(request, timeout=self.timeout_seconds) as response:
				body = json.loads(response.read().decode("utf-8"))
		except HTTPError as error:
			raise ModelAdapterError(f"model request failed with HTTP {error.code}") from error
		except Exception as error:
			raise ModelAdapterError("model request failed") from error
		try:
			content = body["choices"][0]["message"]["content"]
		except (KeyError, IndexError, TypeError) as error:
			raise ModelAdapterError("model response shape is invalid") from error
		if not isinstance(content, str) or not content.strip():
			raise ModelAdapterError("model response is empty")
		return content

	def complete(self, state: Mapping[str, Any]) -> str:
		executor = ThreadPoolExecutor(max_workers=1)
		future = executor.submit(self.completion or self._http_completion, state)
		try:
			response = future.result(timeout=self.timeout_seconds)
		except FutureTimeoutError as error:
			future.cancel()
			executor.shutdown(wait=False, cancel_futures=True)
			raise ModelAdapterError("model request timed out") from error
		except ModelAdapterError:
			executor.shutdown(wait=False, cancel_futures=True)
			raise
		except Exception as error:
			executor.shutdown(wait=False, cancel_futures=True)
			raise ModelAdapterError("model request failed") from error
		executor.shutdown(wait=True, cancel_futures=True)
		if not isinstance(response, str) or not response.strip():
			raise ModelAdapterError("model response is empty")
		return response
