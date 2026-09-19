from pathlib import Path

from flask import Flask, g, request
from flask_cors import CORS

from app.api.auth import auth_api, configure_auth_repository
from app.api.demo import configure_demo_repository, demo_api, ensure_demo_data
from app.api.chat import chat_api
from app.api.exercises import exercises_api
from app.api.experiments import experiments_api
from app.api.plans import plans_api
from app.api.partner_match import partner_match_api
from app.api.profile import profile_api
from app.api.proactive import proactive_api
from app.api.traces import traces_api
from app.api.workflows import configure_workflows_repository, workflows_api
from app.auth import service as auth_service
from app.repositories.json_repository import JsonRepository

CONTRACT_VERSION = "api-contract-v0.3"


def create_app(repository_path: str | Path | None = None) -> Flask:
    app = Flask(__name__)
    CORS(app)
    path = Path(repository_path) if repository_path else Path(__file__).resolve().parents[1] / "data" / "repository.json"
    repository = JsonRepository(path)
    configure_demo_repository(repository)
    ensure_demo_data()
    configure_workflows_repository(repository)
    configure_auth_repository(repository)
    app.register_blueprint(demo_api)
    app.register_blueprint(auth_api)
    app.register_blueprint(chat_api)
    app.register_blueprint(profile_api)
    app.register_blueprint(plans_api)
    app.register_blueprint(partner_match_api)
    app.register_blueprint(exercises_api)
    app.register_blueprint(experiments_api)
    app.register_blueprint(traces_api)
    app.register_blueprint(workflows_api)
    app.register_blueprint(proactive_api)

    @app.before_request
    def resolve_optional_identity():
        """把可选的 `Authorization: Bearer <token>` 解析成 `g.current_user`。

        **关键设计：鉴权是可选的，不是门禁。**

        * 不带 token → `g.current_user = None`，请求按「演示/游客身份」正常处理。
          这样既有的 70 个单元测试、`run_integration` 风格的手工 curl、
          以及 demo-user 演示主链**全部不受影响**。
        * 带 token 但无效/过期 → 也降级为游客身份（不 401），
          避免评审过程中一个过期 token 把整个 App 打成不可用。
          需要严格身份的路由（`/api/v1/auth/me`、`/account`）自己在处理函数里校验。

        这是「先可用、再安全」的取舍：真实生产环境应当改为强制鉴权
        （见 docs/02-登录界面设计与用户数据库方案.md §2.2 障碍 2 的迁移路径）。
        """
        g.current_user = None
        g.auth_token = ""
        token = auth_service.parse_bearer(request.headers.get("Authorization"))
        if token:
            user = auth_service.resolve_session(repository, token)
            if user is not None:
                g.current_user = user
                g.auth_token = token

    @app.before_request
    def require_contract_version():
        """契约版本校验（api-contract-v0.3）。

        规则：`/api/v1/**` 只要带了 `X-API-Contract-Version` 头，就必须等于当前冻结版本；
        不带头则放行，便于用浏览器 / curl 手工抽查接口做答辩演示。

        `/api/agent/*`（聊天层与连通性探针）不做版本校验——否则前端在版本不匹配时
        会把「契约不一致」误读成「后端不可用」，把可诊断的问题变成不可诊断的问题。
        """
        if request.path.startswith("/api/v1"):
            supplied = request.headers.get("X-API-Contract-Version", "")
            if supplied and supplied != CONTRACT_VERSION:
                return {
                    "errorCode": "CONTRACT_VERSION_MISMATCH",
                    "message": f"请使用 X-API-Contract-Version: {CONTRACT_VERSION}",
                    "details": None,
                }, 409

    @app.get("/health")
    def health_check():
        return {"status": "ok"}

    @app.get("/")
    def service_index():
        """根路径自描述，方便评委直接打开浏览器确认服务确实在跑。"""
        from app.agent import chat_llm
        return {
            "service": "知学 Mate · 统一后端",
            "contractVersion": CONTRACT_VERSION,
            "layers": {
                "naturalLanguage": "/api/agent/chat",
                "workflow": "/api/v1/*",
                "auth": "/api/v1/auth/*",
            },
            "llm": {
                "ready": chat_llm.llm_ready(),
                "model": chat_llm.llm_model(),
            },
            "auth": {
                "mode": "optional-bearer",
                "guestUserId": auth_service.DEMO_USER_ID,
                "note": "不带 token 时按演示/游客身份处理，演示主链不受影响",
            },
        }

    @app.errorhandler(404)
    def handle_not_found(error):
        return {"errorCode": "NOT_FOUND", "message": "resource not found", "details": None}, 404

    @app.errorhandler(400)
    def handle_bad_request(error):
        return {"errorCode": "BAD_REQUEST", "message": "invalid request", "details": None}, 400

    @app.errorhandler(500)
    def handle_internal_error(error):
        return {"errorCode": "INTERNAL_ERROR", "message": "internal server error", "details": None}, 500

    return app
