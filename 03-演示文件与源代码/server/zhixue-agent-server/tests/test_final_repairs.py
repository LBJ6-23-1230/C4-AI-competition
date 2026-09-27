import base64
import re
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import pytest

from app import create_app
from app.agent.course_outline import derive_knowledge_points
from app.api import exercises, profile as profile_api


@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path / 'final.json')
    client = app.test_client()
    auth = client.post('/api/v1/auth/register', json={
        'nickname': '最终验收', 'phone': '13812345678', 'seedDemoData': False}).get_json()
    user = auth['user']['userId']
    headers = {'Authorization': 'Bearer ' + auth['token']}
    return app, client, user, headers


def test_new_user_import_is_idempotent_and_creates_plan(setup):
    _, client, user, headers = setup
    path = f'/api/v1/profile/{user}/knowledge-points'
    assert client.get(f'/api/v1/profile/{user}').json['mastery'] == []
    first = client.post(path, json={'courses': ['数据结构', '操作系统']}, headers=headers)
    assert first.status_code == 200
    assert first.json['source'] == 'rules'
    assert all(p['masteryScore'] == 0 for p in first.json['mastery'])
    assert len(first.json['mastery']) >= 8
    assert client.post(path, json={'courses': ['数据结构', '操作系统']}, headers=headers).data == first.data
    plan = client.get('/api/v1/plans/current', headers=headers)
    assert plan.status_code == 200 and plan.json['tasks']
    assert plan.json['userId'] == user


def test_plan_task_names_are_human_readable(setup):
	"""计划任务的 `knowledgePointName` 必须是**中文名**，不能是内部英文 id。

	回归的是什么：`PriorityResult` 原先不带 name 字段、`to_dict()` 也不输出它，
	于是 `PlannerAgent` 里那句 `item.get("knowledgePointName") or item["knowledgePointId"]`
	**静默回落到 id** —— 计划页于是出现 `binary-tree-traversal`、`graph-algorithm`
	这类内部英文标识。

	为什么以前没暴露：题库命中的知识点 id 都是英文，而兜底分支拿课程名当 id 的
	那几个**碰巧**是中文，混在一起看不出问题。
	"""
	_, client, user, headers = setup
	client.post(f'/api/v1/profile/{user}/knowledge-points',
		json={'courses': ['数据结构', '操作系统']}, headers=headers)
	profile = client.get(f'/api/v1/profile/{user}', headers=headers).json
	plan = client.get('/api/v1/plans/current', headers=headers).json

	name_of = {row['knowledgePointId']: row['knowledgePointName'] for row in profile['mastery']}
	assert plan['tasks'], '导入后必须真的生成计划'
	# 至少要有命中题库的知识点（它们的 id 是英文），否则这条测试没有判别力
	assert any(re.fullmatch(r'[a-z]+(-[a-z]+)+', key) for key in name_of), name_of
	for task in plan['tasks']:
		assert task['knowledgePointName'] == name_of.get(task['knowledgePointId']), task
		assert not re.fullmatch(r'[a-z]+(-[a-z]+)+', task['knowledgePointName'] or ''), task


@pytest.mark.parametrize('courses', [None, [], [''], [None], '数据结构', ['a' * 81], ['课程'] * 61])
def test_import_validation(setup, courses):
    _, client, user, headers = setup
    assert client.post(f'/api/v1/profile/{user}/knowledge-points',
                       json={'courses': courses}, headers=headers).status_code == 400


def test_import_identity_and_concurrency(setup):
    app, client, user, headers = setup
    def send(_):
        with app.test_client() as c:
            return c.post('/api/v1/profile/someone-else/knowledge-points',
                          json={'courses': ['数据结构']}, headers=headers).json
    with ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(send, range(5)))
    assert all(result == results[0] for result in results)
    assert results[0]['profile']['userId'] == user
    assert client.get('/api/v1/profile/someone-else').status_code == 404


def test_import_preserves_existing_score_and_metadata_after_practice(setup):
    _, client, user, headers = setup
    repository = profile_api._repository
    repository.save('exercises', 'hash-test', {'exerciseId': 'hash-test', 'knowledgePointId': '哈希表',
                    'knowledgePointName': '哈希表', 'answerKey': 'A'})
    client.post(f'/api/v1/profile/{user}/knowledge-points', json={'courses': ['数据结构']}, headers=headers)
    client.post('/api/v1/exercises/set-demo-binary-tree-001/submit', json={
        'idempotencyKey': 'hash', 'answers': [{'exerciseId': 'hash-test', 'answer': 'A'}]}, headers=headers)
    before = client.get(f'/api/v1/profile/{user}').json
    after = client.post(f'/api/v1/profile/{user}/knowledge-points',
                        json={'courses': ['数据结构']}, headers=headers).json
    assert next(p for p in after['mastery'] if p['knowledgePointId'] == '哈希表')['masteryScore'] == 29
    assert before['mastery'] == after['mastery']
    assert 'courseOutlines' in after['profile']


def test_outline_model_filter_and_failure_fallback(monkeypatch):
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'unit-test-placeholder')
    response = '{"courses":[{"courseName":"数字信号处理","points":[{"name":"离散傅里叶变换"},{"name":"数字滤波"},{"name":"采样定理"}]}]}'
    with patch('app.model_adapters.qwen_adapter.QwenAdapter.complete', return_value=response):
        result = derive_knowledge_points(['数字信号处理'])
    assert len(result) == 3 and all(p['source'] == 'llm' for p in result)
    with patch('app.model_adapters.qwen_adapter.QwenAdapter.complete', return_value='bad json'):
        assert derive_knowledge_points(['数字信号处理']) == derive_knowledge_points(['数字信号处理'], False)
    with patch('app.model_adapters.qwen_adapter.QwenAdapter.complete', side_effect=TimeoutError):
        assert derive_knowledge_points(['操作系统']) == derive_knowledge_points(['操作系统'], False)


def test_document_and_diagnosis_seed_real_points(setup):
    _, client, user, headers = setup
    kb = client.post('/api/v1/knowledge-bases', json={'courseName': '数据结构', 'name': '资料'}, headers=headers).json
    content = '# 哈希表\n\n哈希表使用散列函数映射键。哈希表处理冲突。哈希表支持查找。'
    response = client.post(f'/api/v1/knowledge-bases/{kb["kbId"]}/documents', headers=headers, json={
        'fileName': '讲义.md', 'contentBase64': base64.b64encode(content.encode()).decode()})
    assert response.status_code == 201 and response.json['status'] == 'ready'
    assert client.get(f'/api/v1/profile/{user}').json['mastery']
    with patch('app.api.chat.chat_llm.chat', return_value={'reply': '诊断', 'intent': 'analyze_wrong',
               'card': None, 'llmUsed': True, 'wrongAnalysis': {'knowledgePoint': '进程调度', 'wrongType': '概念混淆'}}):
        assert client.post('/api/agent/chat', json={'message': '分析错题'}, headers=headers).status_code == 200
    assert any(p['knowledgePointName'] == '进程调度' for p in client.get(f'/api/v1/profile/{user}').json['mastery'])


def test_grading_baseline_and_trace_no_duplicate_write(setup):
    _, client, _, _ = setup
    client.post('/api/v1/demo/reset')
    payload = {'idempotencyKey': 'final-baseline', 'answers': [
        {'exerciseId': 'exercise-preorder-001', 'answer': 'A'},
        {'exerciseId': 'exercise-inorder-001', 'answer': 'B'},
        {'exerciseId': 'exercise-postorder-001', 'answer': 'A'}]}
    result = client.post('/api/v1/exercises/set-demo-binary-tree-001/submit', json=payload).json
    assert result['assessment']['score'] == 66.67
    assert result['masteryUpdate']['oldScore'] == 42 and result['masteryUpdate']['newScore'] == 58
    assert [t['durationMinutes'] for t in result['plan']['tasks']] == [45, 15]
    assert result['assessment']['errorTypes'] == ['二叉树后序遍历·答错']
    trace = client.get('/api/v1/traces/' + result['traceId']).json
    assert trace['events'][0]['toolCalls'] == ['grade_exercise', 'update_mastery']
    with patch.object(exercises, 'persist_mastery', side_effect=AssertionError('duplicate write')):
        assert client.post('/api/v1/exercises/set-demo-binary-tree-001/submit', json=payload).json == result
    assert client.get('/api/v1/traces/' + result['traceId']).json == trace
    payload['idempotencyKey'] = 'controlled-no-write'
    with patch.object(exercises, 'persist_mastery', return_value=None):
        controlled = client.post('/api/v1/exercises/set-demo-binary-tree-001/submit', json=payload).json
    assert client.get('/api/v1/traces/' + controlled['traceId']).json['events'][0]['toolCalls'] == ['grade_exercise']


def test_generated_exercises_have_selection_trace(setup):
    _, client, _, headers = setup
    item = {'exerciseId': 'generated-test', 'knowledgePointId': '哈希表', 'knowledgePointName': '哈希表',
            'stem': '题目', 'answerKey': 'A', 'options': ['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁'], 'source': 'llm'}
    with patch.object(exercises.exercise_gen, 'generate_exercises', return_value=[item]):
        result = client.get('/api/v1/exercises/set-demo-binary-tree-001?knowledgePointId=哈希表&generate=1', headers=headers).json
    assert 'answerKey' not in result['exercises'][0]
    trace = client.get('/api/v1/traces/' + result['traceId'], headers=headers).json
    assert trace['events'][0]['toolCalls'] == ['select_exercises']
