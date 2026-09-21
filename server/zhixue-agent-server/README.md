# zhixue-agent-server

Zhixue Mate agent backend. The implementation follows the B0-B12 task plan.

## LLM routing

- Natural-language chat and image analysis use `LLM_MODEL` / `LLM_VL_MODEL`
  (default: `qwen-vl-plus`).
- Workflow decisions use `LLM_DECISION_MODEL` (default: `qwen-plus`).
- Keeping the two paths separate is intentional: image analysis needs a VL
  model, while workflow decisions use a cheaper text model.

## Persistence

- Default: JSON at `data/repository.json`, convenient for local demos.
- Multi-process deployment: set `ZHIXUE_DB=sqlite` (or
  `ZHIXUE_DB=sqlite:<path>`) to use the concurrency-safe SQLite backend.

Phone verification endpoints:

- `POST /api/v1/auth/send-code`
- `POST /api/v1/auth/verify-code`

Without a configured SMS adapter, development mode returns `devCode` with
`smsDelivered=false`; production mode refuses to expose the development code.
