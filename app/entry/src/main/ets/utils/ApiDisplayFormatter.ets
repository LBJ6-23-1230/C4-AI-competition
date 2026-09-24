/** Converts API enum values and timestamps into concise user-facing labels. */
export class ApiDisplayFormatter {
  static workflowStatus(value: string): string {
    if (value === 'running') return '进行中';
    if (value === 'completed') return '已完成';
    if (value === 'failed') return '执行失败';
    if (value === 'error') return '执行出错';
    if (value === 'fallback') return '已降级处理';
    if (value === 'success') return '成功';
    return value;
  }

  static agent(value: string | null): string {
    if (value === null || value.length === 0) return '等待调度';
    if (value === 'secretary') return '学习秘书';
    if (value === 'diagnosis') return '薄弱点诊断';
    if (value === 'exercise') return '练习生成';
    if (value === 'assessment') return '学习评估';
    if (value === 'planner') return '计划调整';
    return value;
  }

  static tool(value: string): string {
    if (value === 'get_learner_profile') return '读取学习画像';
    if (value === 'select_knowledge_point') return '筛选薄弱知识点';
    if (value === 'generate_exercise_set') return '生成诊断练习';
    if (value === 'assess_submission') return '评估答题结果';
    if (value === 'update_mastery') return '更新掌握度';
    if (value === 'replan_current_plan') return '调整当前计划';
    return value;
  }

  static tools(values: string[]): string {
    const labels: string[] = [];
    for (let index: number = 0; index < values.length; index++) {
      labels.push(ApiDisplayFormatter.tool(values[index]));
    }
    return labels.join('、');
  }

  static evidenceSource(value: string): string {
    if (value === 'exercise') return '诊断练习';
    if (value === 'assessment') return '学习评估';
    return value;
  }

  static metric(value: string): string {
    if (value === 'perKnowledgeAccuracy') return '知识点正确率';
    return value;
  }

  static knowledgePoint(value: string): string {
    if (value === 'binary-tree-postorder') return '二叉树后序遍历';
    if (value === 'graph-traversal') return '图遍历';
    return value;
  }

  static timestamp(value: string): string {
    const date: Date = new Date(value);
    if (isNaN(date.getTime())) return value;
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const hour: number = date.getHours();
    const minute: number = date.getMinutes();
    return `${date.getFullYear()}年${month}月${day}日 ${ApiDisplayFormatter.pad(hour)}:${ApiDisplayFormatter.pad(minute)}`;
  }

  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}
