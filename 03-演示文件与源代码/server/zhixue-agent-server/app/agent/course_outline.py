"""Course outlines with bounded model enrichment and deterministic fallback."""
import json
import re

from app.model_adapters.qwen_adapter import QwenAdapter

OUTLINE_TIMEOUT_SECONDS = 20
MAX_POINTS_PER_COURSE = 8
MAX_POINTS_TOTAL = 60
_COURSE_OUTLINE = {
	"数据结构": ["二叉树遍历基础", "二叉搜索树", "图算法", "排序算法", "哈希表"],
	"算法": ["算法复杂度先修", "递归基础先修", "排序算法", "图算法"],
	"操作系统": ["进程调度", "内存管理", "文件系统", "死锁与同步"],
	"计算机网络": ["TCP/IP 协议", "三次握手与四次挥手", "路由与转发", "HTTP 协议"],
	"高等数学": ["极限与连续", "导数与微分", "多元函数微分", "定积分与不定积分"],
	"线性代数": ["矩阵运算", "向量空间", "特征值与特征向量"],
	"概率统计": ["随机变量", "分布与期望", "参数估计与假设检验"],
	"数据库": ["SQL 基础", "事务与隔离级别", "索引与查询优化"],
	"编译原理": ["词法分析", "语法分析", "语义分析与中间代码"],
	"计算机组成": ["指令系统", "流水线", "存储层次"],
	"软件工程": ["需求分析", "设计模式", "软件测试"],
	"人工智能": ["搜索算法", "机器学习基础", "神经网络基础"],
}


def derive_knowledge_points(courses, use_llm=True, course_details=None):
	# Reuse the actual bank loader; do not create another bank or ID namespace.
	from app.api.exercises import _EXERCISE_BANK
	bank = {item["knowledgePointName"]: item["knowledgePointId"] for item in _EXERCISE_BANK}
	generated = {}
	if use_llm:
		try:
			adapter = QwenAdapter(timeout_seconds=OUTLINE_TIMEOUT_SECONDS,
				system_prompt="你是课程大纲分析助手。只输出严格 JSON，不要解释。")
			if adapter.api_key.strip():
				raw = json.loads(adapter.complete({"courses": courses, "details": course_details or [],
					"instruction": '每门课程给3至5个中文知识点，2至12字，不要章节号或课程名。格式 {"courses":[{"courseName":"课程名","points":[{"name":"知识点","importance":0.6}]}]}'}))
				for item in raw.get("courses", []):
					course = item.get("courseName")
					if course not in courses:
						continue
					points = list(dict.fromkeys(p.get("name", "").strip() for p in item.get("points", [])
						if isinstance(p, dict) and isinstance(p.get("name"), str)
						and re.fullmatch(r"[\u4e00-\u9fff]{2,12}", p["name"].strip())
						and p["name"].strip() != course))
					if 3 <= len(points) <= 5:
						generated[course] = points
		except Exception:
			generated = {}
	merged = {}
	for course in courses:
		names = [name for name in bank if name in course or course in name]
		for keyword, points in _COURSE_OUTLINE.items():
			if keyword in course:
				names.extend(points)
		names = list(dict.fromkeys(generated.get(course, []) + names)) or [f"{course} 课程概览"]
		for name in names[:MAX_POINTS_PER_COURSE]:
			if len(merged) >= MAX_POINTS_TOTAL:
				break
			merged.setdefault(name, {"name": name, "knowledgePointId": bank.get(name, name),
				"sourceCourse": course, "importance": 0.8 if name in bank else 0.6,
				"source": "llm" if name in generated.get(course, []) else "rules"})
	return list(merged.values())
