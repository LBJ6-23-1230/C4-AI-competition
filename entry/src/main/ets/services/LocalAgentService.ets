import {
  CourseInfo,
  HomeworkDDL,
  LearningBadge,
  LearningReview,
  OverlapResult,
  PartnerMatch,
  MatchFactor,
  StudySuggestion,
  TaskPriority,
  WeaknessJudgment,
  MatchFeasibility,
  TimeRange,
  UserProfile,
  WrongAnalysisResult,
  KnowledgeResult,
  KnowledgeAnalysis,
  GoalUnderstanding,
  FocusSession,
  AgentFeedback,
  AgentDecisionTrace,
  LearningPlanTask,
  WeeklyLearningPlan
} from '../models/AgentModels';
import { appState } from '../data/AppState';
import { DateHelper, WeekDay } from '../utils/DateHelper';

/**
 * LocalAgentService — 5层Agent工作流业务逻辑
 *
 * 【第1层：输入层】汇集课程表、考试时间、DDL、错题图片、用户目标、空闲时间
 * 【第2层：理解层】识别课程、考试紧迫度、错题知识点、错误类型、学习目标
 * 【第3层：判断层】判断最优学习任务、知识薄弱点、可匹配学习伙伴
 * 【第4层：行动层】生成学习建议、错题补强建议、学习标签、搭子匹配结果
 * 【第5层：输出层】输出今日学习卡、错题诊断卡、学习搭子卡、协同学习计划
 *
 * v2.0 增强：支持基于真实导入数据（课程表/DDL）进行分析，
 * Agent 自动识别数据来源并在输出中标注。
 */
export class LocalAgentService {

  /** 生成可解释、可调整的一周学习计划 */
  static generateWeeklyPlan(
    courses: CourseInfo[],
    ddls: HomeworkDDL[],
    user: UserProfile
  ): WeeklyLearningPlan {
    const priorities: TaskPriority[] = LocalAgentService.judgeOptimalTask(courses, ddls, user);
    const tasks: LearningPlanTask[] = [];
    // 使用真实日历日期替代抽象的"今天/明天/后天"
    const weekDays: WeekDay[] = DateHelper.getWeekDays();
    // 为学习任务分配日期：前两个紧迫任务放明后两天，其余按紧迫度往后排
    // 同时确保 DDl 截止日前能完成
    const taskDateIndices: number[] = [];
    for (let index: number = 0; index < priorities.length; index++) {
      // 紧迫度高的任务优先分配前3天，其余往后排
      if (index < 2) {
        taskDateIndices.push(1); // 前两个最紧迫任务放明天（周一）
      } else if (index < 4) {
        taskDateIndices.push(2); // 接下来两个放后天（周二）
      } else {
        taskDateIndices.push(Math.min(3 + index - 4, 6)); // 其余从第4天起往后排
      }
    }

    for (let index: number = 0; index < priorities.length; index++) {
      const priority: TaskPriority = priorities[index];
      const knowledge: string = LocalAgentService.resolveKnowledgePoint(priority.courseName, user, index);
      const dayIndex: number = taskDateIndices[index];
      const dateLabel: string = dayIndex < weekDays.length ? weekDays[dayIndex].fullLabel : weekDays[weekDays.length - 1].fullLabel;
      tasks.push(LocalAgentService.createPlanTask(
        `agent-${priority.courseName}-${index}`,
        priority.courseName,
        priority.task,
        knowledge,
        index === 0 ? 'learn' : 'practice',
        dateLabel,
        priority.suggestedDuration,
        priority.priorityScore,
        priority.urgencyFactors.join('、') || '保持复习节奏',
        `完成 ${index === 0 ? '1 个核心知识点讲解和 3 道练习' : '2 道针对性练习'}，并记录 1 个易错点。`,
        ['理解核心概念', '完成针对性练习', '记录易错点'],
        'agent'
      ));
    }

    // 按DDL紧迫度分配日期：将DDL安排到对应截止日期前的合理时间
    const sortedDDLs: HomeworkDDL[] = [...ddls].sort((first: HomeworkDDL, second: HomeworkDDL) => first.daysLeft - second.daysLeft);
    for (let index: number = 0; index < sortedDDLs.length && index < 5; index++) {
      const ddl: HomeworkDDL = sortedDDLs[index];
      // 根据实际剩余天数，在截止日期之前安排任务
      // 紧急的(≤3天)放在明天或后天；一般的按剩余天数分配
      let ddlDayIndex: number;
      if (ddl.daysLeft <= 1) {
        ddlDayIndex = 0; // 今天
      } else if (ddl.daysLeft <= 2) {
        ddlDayIndex = 1; // 明天
      } else if (ddl.daysLeft <= 4) {
        ddlDayIndex = 2; // 后天
      } else if (ddl.daysLeft <= 7) {
        ddlDayIndex = Math.min(3 + index, 5);
      } else {
        ddlDayIndex = Math.min(4 + index, 6);
      }
      const ddlDateLabel: string = ddlDayIndex < weekDays.length ? weekDays[ddlDayIndex].fullLabel : weekDays[weekDays.length - 1].fullLabel;
      tasks.push(LocalAgentService.createPlanTask(
        `ddl-${ddl.id}`,
        ddl.courseName,
        ddl.title,
        '作业交付',
        'assignment',
        ddlDateLabel,
        ddl.estimatedMinutes,
        Math.min(100, 70 + Math.max(0, 7 - ddl.daysLeft) * 4),
        `作业将在 ${ddl.daysLeft} 天后截止（${DateHelper.formatDueDate(ddl.dueDate)}）`,
        '完成可提交版本，并检查题目要求。',
        ['梳理要求', '完成主体内容', '检查并提交'],
        'ddl'
      ));
    }

    tasks.sort((first: LearningPlanTask, second: LearningPlanTask) => second.priorityScore - first.priorityScore);
    const highCourse: CourseInfo | null = courses.length > 0 ? courses[0] : null;
    const trace: AgentDecisionTrace = {
      inputSummary: LocalAgentService.collectInputData(courses, ddls, user),
      urgencyReason: highCourse !== null ? `${highCourse.courseName} 距考试 ${highCourse.exam.daysLeft} 天，优先级上调。` : '等待导入课程与考试信息。',
      weaknessReason: user.knowledge.weakness.length > 0 ? `薄弱点 ${user.knowledge.weakness.slice(0, 2).join('、')} 已被放入前序任务。` : '暂未识别薄弱点，先保持基础复习。',
      timeReason: `按你的空闲时间 ${user.time.freeTime.join('、')}，优先拆成 20–45 分钟可执行任务。`,
      recommendation: tasks.length > 0 ? `先完成“${tasks[0].title}”，再根据结果调整下一项。` : '导入课程后即可生成计划。',
      updatedAt: new Date().toLocaleString()
    };
    return { weekLabel: '本周学习计划', tasks: tasks, decisionTrace: trace, adjustmentMessage: 'Agent 已根据当前课程、DDL 和薄弱点排好优先顺序。' };
  }

  static adjustPlanAfterFocus(plan: WeeklyLearningPlan, session: FocusSession): WeeklyLearningPlan {
    const task: LearningPlanTask | undefined = plan.tasks.find((item: LearningPlanTask) =>
      (session.planTaskId !== undefined && item.id === session.planTaskId) ||
      (session.planTaskId === undefined && item.title === session.task)
    );
    const feedback: AgentFeedback = LocalAgentService.createFocusFeedback(session);
    if (task !== undefined) {
      if (session.completionRate >= 90 && session.selfAssessment === 'completed') {
        task.status = 'completed';
      } else if (session.completionRate >= 40 || session.selfAssessment === 'partial') {
        task.status = 'partial';
      } else {
        task.status = 'deferred';
        const weekDays: WeekDay[] = DateHelper.getWeekDays();
        const tomorrowLabel: string = weekDays.length > 1 ? weekDays[1].fullLabel : '明天';
        const retryTask: LearningPlanTask = LocalAgentService.createPlanTask(
          `retry-${session.taskId}`,
          session.course,
          `补完：${session.task}`,
          task.knowledgePoint,
          'review',
          tomorrowLabel,
          15,
          Math.min(100, task.priorityScore + 5),
          '本次未完成，Agent 将任务缩小以降低重启成本。',
          '完成 1 个例题，并写下仍不确定的步骤。',
          ['回顾一个例题', '写下卡点', '重新开始'],
          'focus_feedback'
        );
        plan.tasks.unshift(retryTask);
      }
    }
    plan.adjustmentMessage = feedback.nextSuggestion;
    plan.decisionTrace.recommendation = feedback.feedback;
    plan.decisionTrace.updatedAt = new Date().toLocaleString();
    return plan;
  }

  static createWrongQuestionReviewTask(result: WrongAnalysisResult): LearningPlanTask {
    const weekDays: WeekDay[] = DateHelper.getWeekDays();
    const tomorrowLabel: string = weekDays.length > 1 ? weekDays[1].fullLabel : '明天';
    return LocalAgentService.createPlanTask(
      `wrong-${Date.now()}`,
      result.course,
      `复习：${result.knowledge[0] ?? '错题知识点'}`,
      result.knowledge[0] ?? '错题知识点',
      'review',
      tomorrowLabel,
      25,
      92,
      `错题分析发现“${result.wrongType}”，需在遗忘前完成针对性复盘。`,
      '完成 1 次知识点回顾和 2 道同类题。',
      ['回看错误原因', '完成同类题', '记录易错点'],
      'wrong_question'
    );
  }

  static createCollaborativeTask(partner: PartnerMatch, user: UserProfile): LearningPlanTask {
    const weekDays: WeekDay[] = DateHelper.getWeekDays();
    const dateLabel: string = weekDays.length > 0 ? weekDays[0].fullLabel : '今天';
    const knowledgePoint: string = user.knowledge.weakness[0] ?? '当前薄弱点';
    const duration: number = partner.duration > 0 ? Math.min(90, partner.duration) : 30;
    return LocalAgentService.createPlanTask(
      `partner-${partner.userId}-${knowledgePoint}`,
      user.learningGoal.course,
      `与${partner.matchName}协同复习`,
      knowledgePoint,
      'review',
      dateLabel,
      duration,
      88,
      `与${partner.matchName}在${partner.studyTime ?? '双方约定时间'}互讲互测，利用知识结构互补完成巩固。`,
      '完成互讲概念、互测练习和错题复盘三个阶段。',
      ['互讲核心概念', '互测两道练习', '共同复盘错题'],
      'partner_match'
    );
  }

  private static createPlanTask(
    id: string, course: string, title: string, knowledgePoint: string, type: 'learn' | 'practice' | 'review' | 'test' | 'assignment',
    dateLabel: string, plannedMinutes: number, priorityScore: number, reason: string, completionCriteria: string,
    steps: string[], source: 'agent' | 'ddl' | 'wrong_question' | 'focus_feedback' | 'partner_match'
  ): LearningPlanTask {
    return {
      id: id, course: course, title: title, knowledgePoint: knowledgePoint, type: type, dateLabel: dateLabel,
      plannedMinutes: plannedMinutes, priorityScore: priorityScore,
      priorityLabel: priorityScore >= 80 ? '高优先级' : priorityScore >= 50 ? '中优先级' : '低优先级',
      reason: reason, completionCriteria: completionCriteria, steps: steps, status: 'todo', source: source,
      canCollaborate: type === 'practice' || type === 'review'
    };
  }

  private static resolveKnowledgePoint(courseName: string, user: UserProfile, index: number): string {
    if (courseName === '数据结构' && user.knowledge.weakness.length > 0) {
      return user.knowledge.weakness[index % user.knowledge.weakness.length];
    }
    if (courseName === '操作系统') {
      return '进程调度';
    }
    return '核心知识点';
  }

  /* ================================================================
   * 第1层：输入层 (Input Layer)
   * 汇集所有输入数据
   * ================================================================ */

  static collectInputData(
    courses: CourseInfo[],
    ddls: HomeworkDDL[],
    user: UserProfile
  ): string {
    const courseCount: number = courses.length;
    const ddlCount: number = ddls.length;
    const urgentDDLCount: number = ddls.filter((d: HomeworkDDL) => d.daysLeft <= 3).length;
    const totalWeakness: number = user.knowledge.weakness.length;
    const highPriority: CourseInfo | null = courses.length > 0 ?
      courses.reduce((prev: CourseInfo, curr: CourseInfo) => prev.exam.daysLeft < curr.exam.daysLeft ? prev : curr) : null;

    let summary: string = `Agent 已感知 ${courseCount} 门课程、${ddlCount} 项作业`;
    if (urgentDDLCount > 0) {
      summary += `，其中 ${urgentDDLCount} 项紧急`;
    }
    if (totalWeakness > 0) {
      summary += `，识别到 ${totalWeakness} 个薄弱知识点`;
    }
    if (highPriority !== null && highPriority.exam.daysLeft <= 7) {
      summary += `。${highPriority.courseName} 考试临近（${highPriority.exam.daysLeft}天）`;
    }
    summary += '。';

    return summary;
  }

  /* ================================================================
   * 第2层：理解层 (Understanding Layer)
   * 识别课程紧迫度、错题知识点、错误类型、学习目标差距
   * ================================================================ */

  static analyzeExamUrgency(courses: CourseInfo[]): Map<string, number> {
    const urgency: Map<string, number> = new Map();
    for (let i: number = 0; i < courses.length; i++) {
      const course: CourseInfo = courses[i];
      let score: number = 0;
      if (course.exam.daysLeft <= 3) {
        score = 90;
      } else if (course.exam.daysLeft <= 7) {
        score = 70;
      } else if (course.exam.daysLeft <= 14) {
        score = 45;
      } else {
        score = 20;
      }
      // 复习状态修正
      if (course.recentStatus.status === '近期复习不足') {
        score += 15;
      } else if (course.recentStatus.status === '近期复习良好') {
        score -= 10;
      }
      urgency.set(course.courseName, Math.min(100, Math.max(0, score)));
    }
    return urgency;
  }

  static understandGoal(user: UserProfile): GoalUnderstanding {
    return {
      targetCourse: user.learningGoal.course,
      targetScore: user.learningGoal.goal,
      currentLevel: user.knowledge.weakness.length > 0 ? '存在薄弱环节' : '基础扎实',
      gap: user.knowledge.weakness.length > 0 ?
        `需要在 ${user.knowledge.weakness.join('、')} 方面加强` :
        '保持当前状态即可达成目标'
    };
  }

  /**
   * 分析单个错题的知识点和错误类型
   * 根据图片ID返回不同的分析结果（模拟AI识别不同题目）
   * 统一围绕"数据结构—二叉树遍历"主线
   */
  static analyzeWrongQuestion(imageUri: string): WrongAnalysisResult {
    // 根据图片URI的hash特征返回不同分析结果，模拟真实AI识别
    // 演示统一围绕"数据结构—二叉树遍历"主线
    const variant: number = imageUri.length % 4;

    switch (variant) {
      case 0:
        return {
          course: '数据结构',
          knowledge: ['二叉树遍历', '递归调用'],
          wrongType: '概念混淆',
          reason: '前序、中序、后序遍历的访问时机混淆，未理解递归调用栈的执行顺序。三种遍历的核心区别在于访问根节点的时机：先序在递归前访问，中序在两次递归之间访问，后序在递归后访问。',
          suggestions: [
            '复习二叉树三种遍历的定义和访问顺序，画出递归调用树',
            '手动推演一棵具体二叉树的中序遍历过程，标注每个节点的访问时机',
            '完成3道同类型练习题巩固理解，对比三种遍历的结果差异'
          ],
          tags: ['二叉树', '遍历', '递归'],
          imageUri: imageUri
        };
      case 1:
        return {
          course: '数据结构',
          knowledge: ['图算法', 'BFS/DFS'],
          wrongType: '知识盲区',
          reason: '对BFS使用队列、DFS使用栈/递归的实现细节记忆模糊。BFS逐层扩展需要FIFO队列，DFS深度优先需要LIFO栈或递归隐式栈。',
          suggestions: [
            '对比BFS和DFS的数据结构使用差异，画图辅助理解',
            '手动模拟BFS和DFS的遍历过程，记录访问顺序',
            '完成图的遍历相关编程练习，用邻接表和邻接矩阵分别实现'
          ],
          tags: ['图算法', 'BFS', 'DFS'],
          imageUri: imageUri
        };
      case 2:
        return {
          course: '数据结构',
          knowledge: ['二叉搜索树', '平衡二叉树'],
          wrongType: '计算错误',
          reason: 'BST的插入和删除操作导致树不平衡时，未正确识别旋转类型。LL、RR、LR、RL四种旋转的适用条件和操作步骤混淆。',
          suggestions: [
            '系统复习AVL树的四种旋转操作及其适用场景',
            '练习手动构建AVL树，每插入一个节点检查平衡因子',
            '对比普通BST和AVL树的查找效率差异'
          ],
          tags: ['BST', 'AVL', '平衡旋转'],
          imageUri: imageUri
        };
      default:
        return {
          course: '数据结构',
          knowledge: ['哈希表', '冲突解决'],
          wrongType: '概念混淆',
          reason: '开放定址法和链地址法的适用场景不清，对装载因子的理解不够深入。哈希表的核心在于哈希函数设计和冲突处理策略的选择。',
          suggestions: [
            '对比开放定址法和链地址法的优缺点',
            '理解装载因子对哈希表性能的影响',
            '动手实现一个简单的哈希表并测试不同装载因子下的性能'
          ],
          tags: ['哈希表', '冲突解决', '装载因子'],
          imageUri: imageUri
        };
    }
  }

  /**
   * 从错题分析结果中提取知识薄弱点汇总
   */
  static summarizeKnowledgeGaps(analyses: WrongAnalysisResult[]): Map<string, string[]> {
    const gaps: Map<string, string[]> = new Map();
    for (let i: number = 0; i < analyses.length; i++) {
      const analysis: WrongAnalysisResult = analyses[i];
      const course: string = analysis.course;
      if (!gaps.has(course)) {
        gaps.set(course, []);
      }
      const existing: string[] = gaps.get(course)!;
      for (let j: number = 0; j < analysis.knowledge.length; j++) {
        if (existing.indexOf(analysis.knowledge[j]) === -1) {
          existing.push(analysis.knowledge[j]);
        }
      }
    }
    return gaps;
  }

  /* ================================================================
   * 第3层：判断层 (Judgment Layer)
   * 判断最优学习任务、知识薄弱点严重程度、搭子匹配可行性
   * ================================================================ */

  static calculatePriorityScore(course: CourseInfo, homeworkDDLs: HomeworkDDL[]): number {
    let score: number = 0;

    // 考试紧迫度
    if (course.exam.daysLeft <= 3) {
      score += 50;
    } else if (course.exam.daysLeft <= 7) {
      score += 35;
    } else if (course.exam.daysLeft <= 14) {
      score += 15;
    }

    // 复习状态
    if (course.recentStatus.status === '近期复习不足') {
      score += 30;
    } else if (course.recentStatus.status === '近期复习正常') {
      score += 15;
    }

    // DDL紧迫度
    const courseDDLs: HomeworkDDL[] = homeworkDDLs.filter(
      (ddl: HomeworkDDL) => ddl.courseName === course.courseName
    );
    for (let index: number = 0; index < courseDDLs.length; index++) {
      const ddl: HomeworkDDL = courseDDLs[index];
      if (ddl.daysLeft <= 2) {
        score += 25;
      } else if (ddl.daysLeft <= 5) {
        score += 15;
      } else if (ddl.daysLeft <= 7) {
        score += 5;
      }
    }

    return score;
  }

  static judgeOptimalTask(
    courses: CourseInfo[],
    ddls: HomeworkDDL[],
    user: UserProfile
  ): TaskPriority[] {
    const tasks: TaskPriority[] = [];

    for (let i: number = 0; i < courses.length; i++) {
      const course: CourseInfo = courses[i];
      const score: number = LocalAgentService.calculatePriorityScore(course, ddls);

      const factors: string[] = [];
      if (course.exam.daysLeft <= 7) {
        factors.push(`考试仅剩${course.exam.daysLeft}天`);
      }
      if (course.recentStatus.status === '近期复习不足') {
        factors.push('近期复习不足');
      }
      const courseDDLs: HomeworkDDL[] = ddls.filter((d: HomeworkDDL) => d.courseName === course.courseName);
      const urgentDDLs: HomeworkDDL[] = courseDDLs.filter((d: HomeworkDDL) => d.daysLeft <= 3);
      if (urgentDDLs.length > 0) {
        factors.push(`${urgentDDLs.length}项作业即将截止`);
      }

      // 匹配薄弱点
      let taskDesc: string = `复习${course.courseName}`;
      for (let j: number = 0; j < user.knowledge.weakness.length; j++) {
        const w: string = user.knowledge.weakness[j];
        if (course.courseName === '数据结构' &&
            (w.indexOf('树') !== -1 || w.indexOf('图') !== -1 || w.indexOf('遍历') !== -1 || w.indexOf('递归') !== -1)) {
          taskDesc = `重点复习${course.courseName}的${w}`;
          break;
        }
        if (course.courseName === '操作系统' &&
            (w.indexOf('调度') !== -1 || w.indexOf('进程') !== -1)) {
          taskDesc = `重点复习${course.courseName}的${w}`;
          break;
        }
      }

      tasks.push({
        courseName: course.courseName,
        task: taskDesc,
        priorityScore: score,
        urgencyFactors: factors,
        suggestedDuration: score >= 80 ? 45 : (score >= 50 ? 30 : 20)
      });
    }

    // 按分数降序排列
    tasks.sort((a: TaskPriority, b: TaskPriority) => b.priorityScore - a.priorityScore);
    return tasks;
  }

  static judgeWeaknesses(
    user: UserProfile,
    analyses: WrongAnalysisResult[]
  ): WeaknessJudgment[] {
    const judgments: WeaknessJudgment[] = [];

    const missCount: Map<string, number> = new Map();
    for (let i: number = 0; i < analyses.length; i++) {
      for (let j: number = 0; j < analyses[i].knowledge.length; j++) {
        const kp: string = analyses[i].knowledge[j];
        missCount.set(kp, (missCount.get(kp) || 0) + 1);
      }
    }

    for (let i: number = 0; i < user.knowledge.weakness.length; i++) {
      const w: string = user.knowledge.weakness[i];
      const count: number = missCount.get(w) || 0;
      let level: string;
      if (count >= 2) {
        level = '严重';
      } else if (count >= 1) {
        level = '一般';
      } else {
        level = '轻微';
      }
      judgments.push({
        knowledgePoint: w,
        weaknessLevel: level,
        missedCount: count,
        relatedExamWeight: count >= 2 ? 35 : (count >= 1 ? 20 : 10)
      });
    }

    return judgments;
  }

  static judgeMatchFeasibility(user: UserProfile, candidates: UserProfile[]): MatchFeasibility {
    if (candidates.length === 0) {
      return {
        canMatch: false,
        availableCandidates: 0,
        bestMatchFactor: '无可用候选人'
      };
    }

    let courseMatchCount: number = 0;
    let knowledgeComplementCount: number = 0;
    for (let i: number = 0; i < candidates.length; i++) {
      const c: UserProfile = candidates[i];
      if (c.learningGoal.course === user.learningGoal.course) {
        courseMatchCount++;
      }
      if (LocalAgentService.hasCommonItem(user.knowledge.strength, c.knowledge.weakness) ||
          LocalAgentService.hasCommonItem(user.knowledge.weakness, c.knowledge.strength)) {
        knowledgeComplementCount++;
      }
    }

    let bestFactor: string;
    if (knowledgeComplementCount > 0) {
      bestFactor = '知识能力互补';
    } else if (courseMatchCount > 0) {
      bestFactor = '课程一致';
    } else {
      bestFactor = '可尝试匹配但匹配度可能较低';
    }

    return {
      canMatch: candidates.length > 0,
      availableCandidates: candidates.length,
      bestMatchFactor: bestFactor
    };
  }

  /* ================================================================
   * 第4层：行动层 (Action Layer)
   * 生成学习建议、错题补强建议、学习标签、搭子匹配结果
   * ================================================================ */

  static generateStudySuggestions(user: UserProfile, course: CourseInfo): StudySuggestion {
    let score: number = 0;

    if (course.exam.daysLeft <= 3) {
      score += 50;
    } else if (course.exam.daysLeft <= 7) {
      score += 35;
    } else if (course.exam.daysLeft <= 14) {
      score += 15;
    }

    if (course.recentStatus.status === '近期复习不足') {
      score += 30;
    } else if (course.recentStatus.status === '近期复习正常') {
      score += 10;
    }

    if (user.knowledge.weakness.length > 0) {
      score += 20;
    }

    // 考虑DDL紧迫度
    const courseDDLs: HomeworkDDL[] = appState.homeworkDDLs.filter(
      (ddl: HomeworkDDL) => ddl.courseName === course.courseName
    );
    const urgentCount: number = courseDDLs.filter((d: HomeworkDDL) => d.daysLeft <= 3).length;
    if (urgentCount > 0) {
      score += urgentCount * 10;
    }

    if (score >= 80) {
      return {
        course: course.courseName,
        task: user.knowledge.weakness.length > 0 ? user.knowledge.weakness[0] : '系统复习',
        reason: `考试临近（仅剩${course.exam.daysLeft}天），需优先补强薄弱知识点${urgentCount > 0 ? `，还有${urgentCount}项作业待完成` : ''}`,
        duration: '45分钟',
        priority: '高',
        priorityScore: Math.min(100, score)
      };
    } else if (score >= 40) {
      return {
        course: course.courseName,
        task: '系统复习重点章节',
        reason: `考试还有${course.exam.daysLeft}天，建议系统梳理重点知识`,
        duration: '30分钟',
        priority: '中',
        priorityScore: score
      };
    }

    return {
      course: course.courseName,
      task: '常规复习',
      reason: '近期复习状态良好，保持节奏即可',
      duration: '20分钟',
      priority: '低',
      priorityScore: score
    };
  }

  static getOverlapScore(userTimes: string[], candidateTimes: string[]): OverlapResult {
    let maxOverlap: number = 0;
    let overlapStart: number = 0;
    let overlapEnd: number = 0;

    for (let userIndex: number = 0; userIndex < userTimes.length; userIndex++) {
      const userRange: TimeRange = LocalAgentService.parseTime(userTimes[userIndex]);

      for (let candidateIndex: number = 0; candidateIndex < candidateTimes.length; candidateIndex++) {
        const candidateRange: TimeRange = LocalAgentService.parseTime(candidateTimes[candidateIndex]);
        const overlap: number = Math.max(
          0,
          Math.min(userRange.end, candidateRange.end) - Math.max(userRange.start, candidateRange.start)
        );

        if (overlap > maxOverlap) {
          maxOverlap = overlap;
          overlapStart = Math.max(userRange.start, candidateRange.start);
          overlapEnd = Math.min(userRange.end, candidateRange.end);
        }
      }
    }

    let score: number = 0;
    if (maxOverlap >= 60) {
      score = 15;
    } else if (maxOverlap >= 30) {
      score = 10;
    } else if (maxOverlap > 0) {
      score = 5;
    }

    if (score === 0) {
      return { score: 0, start: null, end: null, duration: 0 };
    }

    return {
      score: score,
      start: LocalAgentService.formatTime(overlapStart),
      end: LocalAgentService.formatTime(overlapEnd),
      duration: maxOverlap
    };
  }

  static matchPartner(user: UserProfile, candidate: UserProfile): PartnerMatch {
    let score: number = 0;
    const reasons: string[] = [];
    const factors: MatchFactor[] = [];

    // 因子1：课程一致
    if (user.learningGoal.course.length > 0 &&
        user.learningGoal.course === candidate.learningGoal.course) {
      score += 40;
      reasons.push('学习课程一致');
      factors.push({
        label: '课程一致',
        score: '+40',
        match: true,
        detail: `同修${candidate.learningGoal.course}课程`
      });
    } else {
      factors.push({
        label: '课程一致',
        score: '0',
        match: false,
        detail: '课程不同'
      });
    }

    // 因子2：学习目标一致
    if (user.learningGoal.goal.length > 0 &&
        user.learningGoal.goal === candidate.learningGoal.goal) {
      score += 25;
      reasons.push('学习目标一致');
      factors.push({
        label: '学习目标一致',
        score: '+25',
        match: true,
        detail: `均以${candidate.learningGoal.goal}为目标`
      });
    } else {
      factors.push({
        label: '学习目标一致',
        score: '0',
        match: false,
        detail: '学习目标不同'
      });
    }

    // 因子3：知识能力互补
    const canHelpCandidate: boolean = LocalAgentService.hasCommonItem(
      user.knowledge.strength, candidate.knowledge.weakness
    );
    const canHelpUser: boolean = LocalAgentService.hasCommonItem(
      user.knowledge.weakness, candidate.knowledge.strength
    );

    if (canHelpUser && canHelpCandidate) {
      score += 20;
      reasons.push('知识能力互补');
      factors.push({
        label: '知识能力互补',
        score: '+20',
        match: true,
        detail: `你擅长${user.knowledge.strength[0]}，TA擅长${candidate.knowledge.strength[0]}`
      });
    } else if (canHelpUser || canHelpCandidate) {
      score += 10;
      reasons.push('部分知识互补');
      factors.push({
        label: '知识能力互补',
        score: '+10',
        match: true,
        detail: '存在部分互补关系'
      });
    } else {
      factors.push({
        label: '知识能力互补',
        score: '0',
        match: false,
        detail: '知识结构相似，互补空间有限'
      });
    }

    // 因子4：空闲时间匹配
    const overlap: OverlapResult = LocalAgentService.getOverlapScore(
      user.time.freeTime, candidate.time.freeTime
    );

    if (overlap.score > 0) {
      score += overlap.score;
      reasons.push('空闲时间匹配');
      factors.push({
        label: '空闲时间匹配',
        score: `+${overlap.score}`,
        match: true,
        detail: `重合时段 ${overlap.start}-${overlap.end}`
      });
    } else {
      factors.push({
        label: '空闲时间匹配',
        score: '0',
        match: false,
        detail: '暂无重合空闲时间'
      });
    }

    let studyTime: string | null = null;
    if (overlap.start !== null && overlap.end !== null) {
      studyTime = `${overlap.start}-${overlap.end}`;
    }

    return {
      matchName: candidate.basicInfo.name,
      userId: candidate.userId,
      score: score,
      reasons: reasons,
      studyTime: studyTime,
      duration: overlap.duration,
      matchFactors: factors
    };
  }

  static matchBestPartner(user: UserProfile, candidates: UserProfile[]): PartnerMatch | null {
    let bestMatch: PartnerMatch | null = null;
    let bestScore: number = -1;

    for (let index: number = 0; index < candidates.length; index++) {
      const result: PartnerMatch = LocalAgentService.matchPartner(user, candidates[index]);
      if (result.score > bestScore) {
        bestScore = result.score;
        bestMatch = result;
      }
    }

    return bestMatch;
  }

  /* ================================================================
   * 第5层：输出层 (Output Layer)
   * 输出今日学习卡、错题诊断卡、学习搭子卡、协同学习计划、学习复盘
   * ================================================================ */

  static generateDailyLearningCard(
    user: UserProfile,
    courses: CourseInfo[],
    ddls: HomeworkDDL[]
  ): string {
    if (courses.length === 0) {
      return '📅 今日学习卡\n暂无课程数据，请先导入课程表。';
    }
    const highCourse: CourseInfo = courses.reduce((prev: CourseInfo, curr: CourseInfo) =>
      prev.exam.daysLeft < curr.exam.daysLeft ? prev : curr
    );
    const suggestion: StudySuggestion = LocalAgentService.generateStudySuggestions(user, highCourse);
    const urgentCount: number = ddls.filter((d: HomeworkDDL) => d.daysLeft <= 7).length;
    const dataSource: string = appState.isDataImported ? '基于导入数据分析' : '基于演示数据分析';

    return `📅 今日学习卡（${dataSource}）\n` +
      `优先课程：${suggestion.course} | 优先级：${suggestion.priority}\n` +
      `推荐任务：${suggestion.task}\n` +
      `建议时长：${suggestion.duration}\n` +
      `考试倒计时：${highCourse.exam.daysLeft}天 | 紧急DDL：${urgentCount}项\n` +
      `原因：${suggestion.reason}`;
  }

  static generateWrongQuestionDiagnosticCard(
    analyses: WrongAnalysisResult[]
  ): string {
    if (analyses.length === 0) {
      return '📋 错题诊断卡\n暂无错题分析数据，请上传错题图片。';
    }

    let card: string = `📋 错题诊断卡\n已分析 ${analyses.length} 道错题\n`;
    for (let i: number = 0; i < analyses.length; i++) {
      const a: WrongAnalysisResult = analyses[i];
      card += `\n错题${i + 1}：${a.course} — ${a.knowledge.join('、')}\n`;
      card += `  错误类型：${a.wrongType}\n`;
      card += `  标签：${a.tags.join('、')}\n`;
    }
    return card;
  }

  static generateReviewSummary(
    suggestion: StudySuggestion | null,
    partner: PartnerMatch | null,
    wrongAnalysis: WrongAnalysisResult | null
  ): LearningReview {
    const completedTasks: string[] = [];
    const knowledgeReviewed: string[] = [];
    const badges: LearningBadge[] = [];
    const completedPlanTasks: LearningPlanTask[] = appState.weeklyPlan?.tasks.filter(
      (task: LearningPlanTask) => task.status === 'completed'
    ) ?? [];

    for (let taskIndex: number = 0; taskIndex < completedPlanTasks.length; taskIndex++) {
      const completedTask: LearningPlanTask = completedPlanTasks[taskIndex];
      completedTasks.push(completedTask.title);
      if (knowledgeReviewed.indexOf(completedTask.knowledgePoint) === -1) {
        knowledgeReviewed.push(completedTask.knowledgePoint);
      }
    }

    if (completedPlanTasks.length > 0) {
      badges.push({
        name: '计划大师',
        icon: '📋',
        description: '完成计划中的学习任务'
      });
    }

    if (wrongAnalysis !== null && wrongAnalysis.knowledge.length > 0) {
      completedTasks.push(`完成错题分析：${wrongAnalysis.knowledge.join('、')}`);
      for (let index: number = 0; index < wrongAnalysis.knowledge.length; index++) {
        knowledgeReviewed.push(wrongAnalysis.knowledge[index]);
      }
      badges.push({
        name: '错题克星',
        icon: '⚔️',
        description: '完成错题分析并生成标签'
      });
    }

    if (knowledgeReviewed.length >= 2) {
      badges.push({
        name: '知识捕手',
        icon: '📚',
        description: '完成 2 个以上知识点的复习'
      });
    }

    const completedCollaboration: boolean = completedPlanTasks.some(
      (task: LearningPlanTask) => task.source === 'partner_match'
    );
    if (partner !== null && completedCollaboration) {
      badges.push({
        name: '最佳搭档',
        icon: '🤝',
        description: '与搭子完成一次协同学习'
      });
    }

    const totalMinutes: number = appState.getFocusSummary().todayMinutes;
    if (totalMinutes >= 25) {
      badges.push({
        name: '专注达人',
        icon: '🎯',
        description: '累计专注超过 25 分钟'
      });
    }

    // 添加数据导入徽章
    if (appState.isDataImported) {
      badges.push({
        name: '数据就绪',
        icon: '📥',
        description: '已导入课程表或DDL数据，Agent基于真实数据分析'
      });
    }

    const nextSteps: string[] = [];
    if (wrongAnalysis !== null && wrongAnalysis.suggestions.length > 0) {
      nextSteps.push(wrongAnalysis.suggestions[0]);
    }
    if (partner !== null) {
      nextSteps.push(`下次与 ${partner.matchName} 继续互测错题`);
    }
    nextSteps.push('复习今天标注的知识薄弱点');

    // 如果有导入的DDL，提醒下周任务
    const upcomingDDLs: HomeworkDDL[] = appState.homeworkDDLs.filter((d: HomeworkDDL) => d.daysLeft > 0 && d.daysLeft <= 7);
    if (upcomingDDLs.length > 0) {
      nextSteps.push(`本周还有 ${upcomingDDLs.length} 项作业待完成`);
    }

    return {
      totalMinutes: totalMinutes,
      completedTasks: completedTasks,
      knowledgeReviewed: knowledgeReviewed,
      partnerName: partner !== null ? partner.matchName : null,
      badges: badges,
      strengthsGained: [
        '对知识点理解更深入',
        '学习效率有所提升'
      ],
      nextSteps: nextSteps
    };
  }

  static awardBadges(review: LearningReview): LearningBadge[] {
    return review.badges;
  }

  /** 将一次专注结果转成可执行的下一步 */
  static createFocusFeedback(session: FocusSession): AgentFeedback {
    if (session.completionRate < 60 || session.selfAssessment === 'not_completed') {
      return {
        level: 'adjust',
        feedback: '这次没有完成也没关系，先把任务缩小，下一次更容易重新开始。',
        nextSuggestion: `把"${session.task}"拆成一个 15 分钟小步骤，先完成二叉树遍历的一个例题。`
      };
    }
    if (session.completionRate < 90 || session.selfAssessment === 'partial') {
      return {
        level: 'continue',
        feedback: '你已经推进了大半，趁思路还在，把剩下的部分收个尾。',
        nextSuggestion: `再安排 20 分钟，补完"${session.task}"并记录一个仍不确定的知识点。`
      };
    }
    return {
      level: 'advance',
      feedback: '这一轮完成得很扎实，节奏也很稳定。',
      nextSuggestion: '做一道二叉树遍历巩固题，再进入下一个知识点。'
    };
  }

  /** 获取Agent工作流阶段的可视化描述 */
  static getAgentPipelineDescription(): string {
    const stages: string[] = [
      '输入层：感知课程与DDL',
      '理解层：识别考试紧迫度',
      '判断层：优先级排序',
      '行动层：生成学习建议',
      '输出层：生成学习卡片'
    ];

    const completedStages: number = appState.workflowContext.completedStages.length;
    const currentStage: string = appState.workflowContext.currentStage;

    let desc: string = 'Agent 5层工作流：';
    for (let i: number = 0; i < stages.length; i++) {
      const stageName: string = stages[i].split('：')[0];
      if (appState.workflowContext.completedStages.indexOf(
        i === 0 ? 'input' : i === 1 ? 'understanding' : i === 2 ? 'judgment' : i === 3 ? 'action' : 'output'
      ) !== -1) {
        desc += ` ✅${stageName}`;
      } else {
        desc += ` ⏳${stageName}`;
      }
    }
    return desc;
  }

  /* ================================================================
   * 工具函数
   * ================================================================ */

  private static parseTime(timeString: string): TimeRange {
    const timeParts: string[] = timeString.split('-');
    if (timeParts.length !== 2) {
      throw new Error(`时间格式错误：${timeString}`);
    }
    const startParts: string[] = timeParts[0].split(':');
    const endParts: string[] = timeParts[1].split(':');
    if (startParts.length !== 2 || endParts.length !== 2) {
      throw new Error(`时间格式错误：${timeString}`);
    }
    return {
      start: Number(startParts[0]) * 60 + Number(startParts[1]),
      end: Number(endParts[0]) * 60 + Number(endParts[1])
    };
  }

  private static formatTime(minutes: number): string {
    const hour: number = Math.floor(minutes / 60);
    const minute: number = minutes % 60;
    const hourText: string = hour < 10 ? `0${hour}` : hour.toString();
    const minuteText: string = minute < 10 ? `0${minute}` : minute.toString();
    return `${hourText}:${minuteText}`;
  }

  private static hasCommonItem(first: string[], second: string[]): boolean {
    for (let index: number = 0; index < first.length; index++) {
      if (second.includes(first[index])) {
        return true;
      }
    }
    return false;
  }
}
