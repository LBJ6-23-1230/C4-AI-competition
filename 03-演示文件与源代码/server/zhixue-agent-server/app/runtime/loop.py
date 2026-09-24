"""Observe/decide/act/write-back workflow loop."""

from collections.abc import Callable, Mapping
from typing import Any

from app.runtime.orchestrator import decide_next_step
from app.runtime.session import WorkflowSession


def run_workflow(session: WorkflowSession, observe: Callable[[], Mapping[str, Any]],
				act: Callable[[str, Mapping[str, Any]], Mapping[str, Any] | None],
				model_decider: Callable[[Mapping[str, Any]], Any] | None = None,
				trace_recorder: Callable[..., Any] | None = None) -> WorkflowSession:
	"""Run bounded state transitions and keep every transition versioned.

	关于步数上限（`for ... else` 的准确语义）
	--------------------------------------
	这里用 `for ... else` 表达"步数用尽"，写法不常见但**语义是正确的**，
	实测确认如下：

	* **`else` 是可达的** —— 当某一轮走到"普通步"（`act` 既未返回 `waiting`
	  也未返回 `error`）、把 `act` 的结果写回后循环条件耗尽时，就会进入 `else`。
	  这正是"跑满 `max_steps` 仍未走到终态"，**如实报错是正确行为**。
	* `finish` / `waiting` / `error` 三条出口各自都 `break`，因此：
	  - `finish` 恰好落在最后一次迭代 → 走 `break`，**不会**被误标超限
	  - `waiting` 恰好落在最后一次迭代 → 走 `break`，**不会**被误标超限
	  这两条已由
	  `tests/test_technical_improvements.py::test_finish_on_last_allowed_step_is_not_marked_as_error`
	  与 `::test_waiting_on_last_allowed_step_is_not_marked_as_error` 固化。

	> ⚠️ **两次误判记录（避免重犯）**
	> 1. 一度认为"`max_steps` 恰好用满时会把正常结束误标 `status=error`"，
	>    并把 `else` 判为死代码 —— **错**。`else` 可达，且在那种情形下报错是对的。
	> 2. 据此把逻辑改成"循环后按 `session.status` 判定是否超限" —— **更错**：
	>    `waiting` 分支把 status 写成 `"running"`，新判据会把它当成"没到终态"
	>    从而把**正常等答题**误标成 `max_steps` error（对照实验 1 例误判 vs 原版 0 例）。
	>
	> 已回退为原实现；`run_workflow` 的字节码与改动前**逐指令一致**，
	> 本次仅新增注释与测试。
	> 教训：`for/else` 读起来像 bug，但它在这里恰好表达了想要的语义；
	> 改这类"看起来可疑"的控制流之前，必须先构造受控实验把行为测出来，
	> 不能凭语义直觉下结论。
	"""
	for _ in range(session.max_steps):
		if session.status != "running":
			break
		state = dict(observe())
		if state.get("awaitingAnswers") and not state.get("pendingSubmission"):
			break
		decision = decide_next_step(state, model_decider)
		input_version = session.state_version
		if decision.step == "finish":
			session.advance("finish", {"reason": decision.reason}, "completed", "学习流程已完成")
			if trace_recorder:
				trace_recorder(agent="secretary", tool_calls=[], input_summary=decision.reason,
					output_summary="学习流程已完成", evidence_ids=[], state_version=session.state_version,
					status="completed", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		result = dict(act(decision.step, state) or {})
		if result.get("status") == "waiting":
			session.advance(decision.step, {**result, "awaitingAnswers": True},
				"running", result.get("nextAction"))
			if trace_recorder:
				trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
					input_summary=decision.reason, output_summary=result.get("nextAction", "waiting"),
					evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
					status="waiting", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		if result.get("status") == "error":
			session.advance("error", result, "error", result.get("message", "workflow step failed"))
			if trace_recorder:
				trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
					input_summary=decision.reason, output_summary=result.get("message", "workflow step failed"),
					evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
					status="error", session_id=session.session_id, step_id=f"step-{input_version}",
					input_state_version=input_version, output_state_version=session.state_version)
			break
		session.advance(decision.step, result)
		if trace_recorder:
			trace_recorder(agent=decision.step, tool_calls=list(result.get("toolCalls", [])),
				input_summary=decision.reason, output_summary=str(result),
				evidence_ids=list(result.get("evidenceIds", [])), state_version=session.state_version,
				status="completed", session_id=session.session_id, step_id=f"step-{input_version}",
				input_state_version=input_version, output_state_version=session.state_version)

	# 每条出口都靠 `break`，因此这个 `else` 实际不可达（见 docstring）。
	# 保留它作为"步数上限"的语义兜底：万一将来有人给循环加了不带 break 的
	# 出口路径，这里仍然会如实报错，而不是静默地把未完成的工作流当成成功。
	else:
		session.advance("max_steps", {}, "error", "已达到工作流步数上限")
		if trace_recorder:
			trace_recorder(agent="secretary", tool_calls=[], input_summary="工作流步数上限",
				output_summary="已达到工作流步数上限", evidence_ids=[], state_version=session.state_version,
				status="error", session_id=session.session_id, step_id=f"step-{session.state_version}",
				input_state_version=session.state_version - 1,
				output_state_version=session.state_version)
	return session
