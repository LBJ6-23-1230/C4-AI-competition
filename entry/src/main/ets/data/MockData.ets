import {
  CourseInfo,
  UserProfile,
  WrongQuestionRecord,
  AIAnalysis,
  WrongQuestionInput,
  WrongQuestionSuggestion,
  KnowledgeResult,
  HomeworkDDL,
  LearningReview,
  LearningBadge
} from '../models/AgentModels';
import { ApiDefaults } from '../api/ApiDefaults';

/* ========== 当前用户 ========== */
export const mockCurrentUser: UserProfile = {
  userId: ApiDefaults.DEMO_USER_ID,
  basicInfo: {
    name: '小明',
    grade: '大二',
    major: '计算机科学与技术'
  },
  learningGoal: {
    course: '数据结构',
    goal: '期末80+'
  },
  time: {
    freeTime: ['20:00-22:00']
  },
  knowledge: {
    weakness: ['二叉树遍历', '递归理解', '进程调度'],
    strength: ['图算法', '排序算法']
  }
};

/* ========== 课程列表（3门） ========== */
export const mockCourse: CourseInfo = {
  courseId: 'c001',
  courseName: '数据结构',
  exam: { date: '2026-07-20', daysLeft: 5 },
  priority: '高',
  recentStatus: { studyHours: 2, status: '近期复习不足' }
};

export const mockCoursesList: CourseInfo[] = [
  {
    courseId: 'c001',
    courseName: '数据结构',
    exam: { date: '2026-07-20', daysLeft: 5 },
    priority: '高',
    recentStatus: { studyHours: 2, status: '近期复习不足' }
  },
  {
    courseId: 'c002',
    courseName: '操作系统',
    exam: { date: '2026-07-28', daysLeft: 13 },
    priority: '中',
    recentStatus: { studyHours: 5, status: '近期复习正常' }
  },
  {
    courseId: 'c003',
    courseName: '高等数学',
    exam: { date: '2026-08-05', daysLeft: 21 },
    priority: '低',
    recentStatus: { studyHours: 8, status: '近期复习良好' }
  }
];

/* ========== 候选人（3人，更丰富的匹配场景） ========== */
export const mockCandidates: UserProfile[] = [
  {
    userId: 'u002',
    basicInfo: {
      name: '小红',
      grade: '大二',
      major: '计算机科学与技术'
    },
    learningGoal: {
      course: '数据结构',
      goal: '期末80+'
    },
    time: {
      freeTime: ['21:00-23:00']
    },
    knowledge: {
      weakness: ['图算法'],
      strength: ['递归理解', '二叉树遍历']
    }
  },
  {
    userId: 'u003',
    basicInfo: {
      name: '小刚',
      grade: '大二',
      major: '计算机科学与技术'
    },
    learningGoal: {
      course: '数据结构',
      goal: '期末80+'
    },
    time: {
      freeTime: ['19:00-20:00']
    },
    knowledge: {
      weakness: ['递归理解'],
      strength: ['二叉树遍历']
    }
  },
  {
    userId: 'u004',
    basicInfo: {
      name: '小丽',
      grade: '大三',
      major: '软件工程'
    },
    learningGoal: {
      course: '操作系统',
      goal: '期末85+'
    },
    time: {
      freeTime: ['20:00-22:00']
    },
    knowledge: {
      weakness: ['进程调度', '内存管理'],
      strength: ['文件系统', '死锁分析']
    }
  }
];

/* ========== 错题记录辅助数据 ========== */

const knowledgeResult1: KnowledgeResult = { name: '二叉树遍历', confidence: 0.92 };
const knowledgeResult2: KnowledgeResult = { name: '进程调度算法', confidence: 0.88 };
const knowledgeResult3: KnowledgeResult = { name: '多元函数微分', confidence: 0.85 };

const wrongSuggestion1: WrongQuestionSuggestion = {
  studyTag: '二叉树遍历',
  task: '复习二叉树的前序、中序、后序遍历方法，理解每种遍历的访问顺序和应用场景。'
};
const wrongSuggestion2: WrongQuestionSuggestion = {
  studyTag: '进程调度',
  task: '重新理解进程调度中到达时间、服务时间、完成时间的关系，用甘特图辅助计算。'
};
const wrongSuggestion3: WrongQuestionSuggestion = {
  studyTag: '多元函数微分',
  task: '做多元函数微分时先明确自变量和中间变量，画变量依赖关系图辅助理解链式法则。'
};

/* ========== 错题记录（3道，覆盖不同课程） ========== */
export const mockWrongQuestion: WrongQuestionRecord = {
  questionId: 'q001',
  userId: 'u001',
  input: {
    image: 'img001',
    myAnswer: 'A',
    correctAnswer: 'C'
  } as WrongQuestionInput,
  AIAnalysis: {
    course: '数据结构',
    knowledge: [knowledgeResult1],
    wrongType: '概念混淆',
    reason: '未理解中序遍历访问顺序',
    Tag: ['二叉树薄弱'],
    suggestion: [wrongSuggestion1]
  } as AIAnalysis
};

export const mockWrongQuestions: WrongQuestionRecord[] = [
  mockWrongQuestion,
  {
    questionId: 'q002',
    userId: 'u001',
    input: {
      image: 'img002',
      myAnswer: 'B',
      correctAnswer: 'D'
    } as WrongQuestionInput,
    AIAnalysis: {
      course: '操作系统',
      knowledge: [knowledgeResult2],
      wrongType: '计算错误',
      reason: '优先级调度算法中等待时间计算遗漏了到达时间因素',
      Tag: ['进程调度', '优先级'],
      suggestion: [wrongSuggestion2]
    } as AIAnalysis
  } as WrongQuestionRecord,
  {
    questionId: 'q003',
    userId: 'u001',
    input: {
      image: 'img003',
      myAnswer: 'C',
      correctAnswer: 'A'
    } as WrongQuestionInput,
    AIAnalysis: {
      course: '高等数学',
      knowledge: [knowledgeResult3],
      wrongType: '审题不清',
      reason: '未注意到题目中隐含的复合函数关系，遗漏了中间变量',
      Tag: ['多元微分', '链式法则'],
      suggestion: [wrongSuggestion3]
    } as AIAnalysis
  } as WrongQuestionRecord
];

/* ========== 作业DDL（5项） ========== */
export const mockHomeworkDDLs: HomeworkDDL[] = [
  {
    id: 'hw001',
    courseName: '数据结构',
    title: '二叉树遍历实验报告',
    dueDate: '2026-07-15',
    daysLeft: 2,
    priority: '高',
    estimatedMinutes: 45
  },
  {
    id: 'hw002',
    courseName: '数据结构',
    title: '图算法课后习题 3-5 题',
    dueDate: '2026-07-17',
    daysLeft: 4,
    priority: '高',
    estimatedMinutes: 30
  },
  {
    id: 'hw003',
    courseName: '操作系统',
    title: '进程调度算法分析',
    dueDate: '2026-07-20',
    daysLeft: 7,
    priority: '中',
    estimatedMinutes: 60
  },
  {
    id: 'hw004',
    courseName: '高等数学',
    title: '多元函数微分习题集',
    dueDate: '2026-07-25',
    daysLeft: 12,
    priority: '低',
    estimatedMinutes: 90
  },
  {
    id: 'hw005',
    courseName: '操作系统',
    title: '内存管理实验预习',
    dueDate: '2026-07-16',
    daysLeft: 3,
    priority: '高',
    estimatedMinutes: 30
  }
];

/* ========== 徽章（6种） ========== */
export const mockBadges: LearningBadge[] = [
  { name: '专注达人', icon: '🎯', description: '连续学习超过 25 分钟' },
  { name: '知识捕手', icon: '📚', description: '完成 2 个以上知识点的复习' },
  { name: '最佳搭档', icon: '🤝', description: '与搭子完成一次协同学习' },
  { name: '错题克星', icon: '⚔️', description: '完成错题分析并生成标签' },
  { name: '计划大师', icon: '📋', description: '按计划完成所有学习任务' },
  { name: '早起鸟', icon: '🌅', description: '在早上 8 点前完成学习' }
];

/* ========== 学习复盘样例 ========== */
export const mockLearningReview: LearningReview = {
  totalMinutes: 30,
  completedTasks: [
    '复习二叉树的前序、中序、后序遍历',
    '完成 2 道二叉树遍历练习题',
    '与搭子互讲核心概念'
  ],
  knowledgeReviewed: ['二叉树遍历', '递归理解', '图算法基础'],
  partnerName: '小红',
  badges: [
    { name: '专注达人', icon: '🎯', description: '连续学习超过 25 分钟' },
    { name: '知识捕手', icon: '📚', description: '完成 2 个以上知识点的复习' },
    { name: '最佳搭档', icon: '🤝', description: '与搭子完成一次协同学习' }
  ],
  strengthsGained: [
    '对中序遍历的递归过程理解更清晰',
    '能够手推二叉树三种遍历结果'
  ],
  nextSteps: [
    '明天复习图算法的 BFS/DFS',
    '完成图算法课后习题',
    '再次与搭子进行错题互测'
  ]
};
