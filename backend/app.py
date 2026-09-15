# -*- coding: utf-8 -*-
"""
知学搭子 后端入口
启动: python app.py  (默认端口 5000)
"""
from flask import Flask
from flask_cors import CORS
from agent_routes import agent_bp
from v1_routes import v1_bp

app = Flask(__name__)
CORS(app)

# 注册 Agent 路由
app.register_blueprint(agent_bp)
app.register_blueprint(v1_bp)

@app.route('/')
def index():
    return {
        "status": "知学搭子 Agent 后端运行中",
        "version": "1.1",
        "contractVersion": "api-contract-v0.2",
        "learningApiMode": "stateful-contract-demo",
    }

if __name__ == '__main__':
    import os
    port = int(os.environ.get('PORT', 5000))
    debug_enabled = os.environ.get('FLASK_DEBUG', '').strip().lower() in ('1', 'true', 'yes')
    print(f"[知学搭子] Agent 后端启动: http://localhost:{port}")
    print(f"[知学搭子] LLM 状态: {'已配置' if os.environ.get('DASHSCOPE_API_KEY') else '等待 API Key'}")
    app.run(host='0.0.0.0', port=port, debug=debug_enabled)
