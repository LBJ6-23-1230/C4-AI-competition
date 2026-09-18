import {
  CourseInfo,
  HomeworkDDL
} from '../models/AgentModels';

/**
 * JSON 导入的原始课程行
 */
interface RawCourseRow {
  courseName: string;
  examDate: string;
  priority: string;
  studyHours: number;
  status: string;
}

/**
 * JSON 导入的原始 DDL 行
 */
interface RawDDLRow {
  courseName: string;
  title: string;
  dueDate: string;
  priority: string;
  estimatedMinutes: number;
}

/**
 * JSON 导入的数据容器
 */
interface ImportDataContainer {
  courses: RawCourseRow[];
  ddls: RawDDLRow[];
  courseList: RawCourseRow[];
  ddlList: RawDDLRow[];
  homework: RawDDLRow[];
}

/**
 * CSV 行字段索引映射
 */
interface CSVFieldMap {
  courseName: number;
  examDate: number;
  priority: number;
  studyHours: number;
  status: number;
  title: number;
  dueDate: number;
  estimatedMinutes: number;
}

/**
 * JSON 模板容器 - 课程表
 */
interface CourseTemplateContainer {
  courses: RawCourseRow[];
}

/**
 * JSON 模板容器 - DDL
 */
interface DDLTemplateContainer {
  ddls: RawDDLRow[];
}

/**
 * FileParserService — 文件解析服务
 *
 * 支持从 CSV / JSON 文件中导入课程表和作业 DDL 数据，
 * 将外部数据转换为 App 内部的 CourseInfo 和 HomeworkDDL 模型。
 */
export class FileParserService {

  /* ================================================================
   * JSON 解析
   * ================================================================ */

  static parseCoursesFromJSON(jsonText: string): CourseInfo[] {
    const parsed: Object = JSON.parse(jsonText);
    const courses: CourseInfo[] = [];

    // 支持两种格式：{ courses: [...] } 或直接数组
    let rawList: RawCourseRow[];
    if (Array.isArray(parsed)) {
      rawList = parsed as RawCourseRow[];
    } else {
      const container: ImportDataContainer = parsed as ImportDataContainer;
      rawList = container.courses ?? container.courseList ?? [];
    }

    if (!Array.isArray(rawList)) {
      throw new Error('未找到有效的课程数组，请检查 JSON 格式');
    }

    for (let i: number = 0; i < rawList.length; i++) {
      const item: RawCourseRow = rawList[i];
      if (item.courseName === undefined || item.courseName === null) {
        continue;
      }

      const examDate: string = item.examDate ?? '未设置';
      const daysLeft: number = FileParserService.calcDaysLeft(examDate);

      const course: CourseInfo = {
        courseId: `imported-${Date.now()}-${i}`,
        courseName: String(item.courseName),
        exam: {
          date: examDate,
          daysLeft: daysLeft
        },
        priority: item.priority ?? FileParserService.guessPriority(daysLeft),
        recentStatus: {
          studyHours: Number(item.studyHours) || 0,
          status: item.status ?? FileParserService.guessStatus(Number(item.studyHours) || 0)
        }
      };
      courses.push(course);
    }

    return courses;
  }

  static parseDDLsFromJSON(jsonText: string): HomeworkDDL[] {
    const parsed: Object = JSON.parse(jsonText);
    const ddls: HomeworkDDL[] = [];

    let rawList: RawDDLRow[];
    if (Array.isArray(parsed)) {
      rawList = parsed as RawDDLRow[];
    } else {
      const container: ImportDataContainer = parsed as ImportDataContainer;
      rawList = container.ddls ?? container.ddlList ?? container.homework ?? [];
    }

    if (!Array.isArray(rawList)) {
      throw new Error('未找到有效的 DDL 数组，请检查 JSON 格式');
    }

    for (let i: number = 0; i < rawList.length; i++) {
      const item: RawDDLRow = rawList[i];
      if (item.title === undefined && item.courseName === undefined) {
        continue;
      }

      const dueDate: string = item.dueDate ?? '未设置';
      const daysLeft: number = FileParserService.calcDaysLeft(dueDate);

      const ddl: HomeworkDDL = {
        id: `ddl-imported-${Date.now()}-${i}`,
        courseName: String(item.courseName ?? '未分类'),
        title: String(item.title ?? '未命名任务'),
        dueDate: dueDate,
        daysLeft: daysLeft,
        priority: item.priority ?? FileParserService.guessPriority(daysLeft),
        estimatedMinutes: Number(item.estimatedMinutes) || 30
      };
      ddls.push(ddl);
    }

    return ddls;
  }

  /* ================================================================
   * CSV 解析
   * ================================================================ */

  static parseCoursesFromCSV(csvText: string): CourseInfo[] {
    const lines: string[] = csvText.trim().split('\n');
    if (lines.length < 2) {
      throw new Error('CSV 文件至少需要包含表头和一行数据');
    }

    const header: string[] = FileParserService.parseCSVLine(lines[0]);
    const idxMap: CSVFieldMap = {
      courseName: -1, examDate: -1, priority: -1, studyHours: -1, status: -1,
      title: -1, dueDate: -1, estimatedMinutes: -1
    };

    for (let i: number = 0; i < header.length; i++) {
      const key: string = header[i].trim();
      if (key === 'courseName' || key === '课程名称' || key === '课程') idxMap.courseName = i;
      if (key === 'examDate' || key === '考试日期' || key === '考试时间') idxMap.examDate = i;
      if (key === 'priority' || key === '优先级') idxMap.priority = i;
      if (key === 'studyHours' || key === '学习时长' || key === '每周学时') idxMap.studyHours = i;
      if (key === 'status' || key === '复习状态') idxMap.status = i;
    }

    if (idxMap.courseName === -1) {
      throw new Error('CSV 表头缺少"courseName"或"课程名称"列');
    }

    const courses: CourseInfo[] = [];
    for (let i: number = 1; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) continue;

      const cols: string[] = FileParserService.parseCSVLine(line);
      const courseName: string = cols[idxMap.courseName]?.trim() ?? '';
      if (courseName.length === 0) continue;

      const examDate: string = idxMap.examDate !== -1 ? (cols[idxMap.examDate]?.trim() ?? '未设置') : '未设置';
      const daysLeft: number = FileParserService.calcDaysLeft(examDate);
      const priority: string = idxMap.priority !== -1 ? (cols[idxMap.priority]?.trim() ?? FileParserService.guessPriority(daysLeft)) : FileParserService.guessPriority(daysLeft);
      const studyHours: number = idxMap.studyHours !== -1 ? (Number(cols[idxMap.studyHours]) || 0) : 0;
      const status: string = idxMap.status !== -1 ? (cols[idxMap.status]?.trim() ?? FileParserService.guessStatus(studyHours)) : FileParserService.guessStatus(studyHours);

      const course: CourseInfo = {
        courseId: `csv-import-${Date.now()}-${i}`,
        courseName: courseName,
        exam: { date: examDate, daysLeft: daysLeft },
        priority: priority,
        recentStatus: { studyHours: studyHours, status: status }
      };
      courses.push(course);
    }

    if (courses.length === 0) {
      throw new Error('CSV 中未解析到任何有效课程数据');
    }

    return courses;
  }

  static parseDDLsFromCSV(csvText: string): HomeworkDDL[] {
    const lines: string[] = csvText.trim().split('\n');
    if (lines.length < 2) {
      throw new Error('CSV 文件至少需要包含表头和一行数据');
    }

    const header: string[] = FileParserService.parseCSVLine(lines[0]);
    const idxMap: CSVFieldMap = {
      courseName: -1, examDate: -1, priority: -1, studyHours: -1, status: -1,
      title: -1, dueDate: -1, estimatedMinutes: -1
    };

    for (let i: number = 0; i < header.length; i++) {
      const key: string = header[i].trim();
      if (key === 'courseName' || key === '课程名称' || key === '课程') idxMap.courseName = i;
      if (key === 'title' || key === '作业标题' || key === '作业名称' || key === '任务') idxMap.title = i;
      if (key === 'dueDate' || key === '截止日期' || key === '截止时间') idxMap.dueDate = i;
      if (key === 'priority' || key === '优先级') idxMap.priority = i;
      if (key === 'estimatedMinutes' || key === '预计时长' || key === '预计分钟') idxMap.estimatedMinutes = i;
    }

    const ddls: HomeworkDDL[] = [];
    for (let i: number = 1; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) continue;

      const cols: string[] = FileParserService.parseCSVLine(line);
      const courseName: string = idxMap.courseName !== -1 ? (cols[idxMap.courseName]?.trim() ?? '未分类') : '未分类';
      const title: string = idxMap.title !== -1 ? (cols[idxMap.title]?.trim() ?? '未命名任务') : '未命名任务';

      if (title.length === 0 && courseName === '未分类') continue;

      const dueDate: string = idxMap.dueDate !== -1 ? (cols[idxMap.dueDate]?.trim() ?? '未设置') : '未设置';
      const daysLeft: number = FileParserService.calcDaysLeft(dueDate);
      const priority: string = idxMap.priority !== -1 ? (cols[idxMap.priority]?.trim() ?? FileParserService.guessPriority(daysLeft)) : FileParserService.guessPriority(daysLeft);
      const estimatedMinutes: number = idxMap.estimatedMinutes !== -1 ? (Number(cols[idxMap.estimatedMinutes]) || 30) : 30;

      const ddl: HomeworkDDL = {
        id: `ddl-csv-${Date.now()}-${i}`,
        courseName: courseName,
        title: title,
        dueDate: dueDate,
        daysLeft: daysLeft,
        priority: priority,
        estimatedMinutes: estimatedMinutes
      };
      ddls.push(ddl);
    }

    return ddls;
  }

  /* ================================================================
   * 自动检测格式并解析
   * ================================================================ */

  static autoParseCourses(content: string): CourseInfo[] {
    const trimmed: string = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return FileParserService.parseCoursesFromJSON(trimmed);
    }
    return FileParserService.parseCoursesFromCSV(trimmed);
  }

  static autoParseDDLs(content: string): HomeworkDDL[] {
    const trimmed: string = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return FileParserService.parseDDLsFromJSON(trimmed);
    }
    return FileParserService.parseDDLsFromCSV(trimmed);
  }

  /* ================================================================
   * 模板生成
   * ================================================================ */

  static generateCourseJSONTemplate(): string {
    const course1: RawCourseRow = {
      courseName: '数据结构',
      examDate: '2026-07-20',
      priority: '高',
      studyHours: 2,
      status: '近期复习不足'
    };
    const course2: RawCourseRow = {
      courseName: '操作系统',
      examDate: '2026-07-28',
      priority: '中',
      studyHours: 5,
      status: '近期复习正常'
    };
    const courseList: RawCourseRow[] = [course1, course2];
    const template: CourseTemplateContainer = {
      courses: courseList
    };
    return JSON.stringify(template, null, 2);
  }

  static generateCourseCSVTemplate(): string {
    return '课程名称,考试日期,优先级,学习时长,复习状态\n数据结构,2026-07-20,高,2,近期复习不足\n操作系统,2026-07-28,中,5,近期复习正常';
  }

  static generateDDLJSONTemplate(): string {
    const ddl1: RawDDLRow = {
      courseName: '数据结构',
      title: '二叉树遍历实验报告',
      dueDate: '2026-07-15',
      priority: '高',
      estimatedMinutes: 45
    };
    const ddl2: RawDDLRow = {
      courseName: '操作系统',
      title: '进程调度算法分析',
      dueDate: '2026-07-20',
      priority: '中',
      estimatedMinutes: 60
    };
    const ddlList: RawDDLRow[] = [ddl1, ddl2];
    const template: DDLTemplateContainer = {
      ddls: ddlList
    };
    return JSON.stringify(template, null, 2);
  }

  static generateDDLCSVTemplate(): string {
    return '课程名称,作业标题,截止日期,优先级,预计时长\n数据结构,二叉树遍历实验报告,2026-07-15,高,45\n操作系统,进程调度算法分析,2026-07-20,中,60';
  }

  /* ================================================================
   * 工具函数
   * ================================================================ */

  private static calcDaysLeft(dateStr: string): number {
    if (dateStr === '未设置') return 30;
    const target: number = new Date(dateStr).getTime();
    const now: number = new Date().getTime();
    const diff: number = target - now;
    return Math.max(0, Math.ceil(diff / (1000 * 60 * 60 * 24)));
  }

  private static guessPriority(daysLeft: number): string {
    if (daysLeft <= 3) return '高';
    if (daysLeft <= 10) return '中';
    return '低';
  }

  private static guessStatus(studyHours: number): string {
    if (studyHours <= 1) return '近期复习不足';
    if (studyHours <= 4) return '近期复习正常';
    return '近期复习良好';
  }

  private static parseCSVLine(line: string): string[] {
    const result: string[] = [];
    let current: string = '';
    let inQuotes: boolean = false;

    for (let i: number = 0; i < line.length; i++) {
      const ch: string = line[i];
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === ',' && !inQuotes) {
        result.push(current.trim());
        current = '';
      } else {
        current += ch;
      }
    }
    result.push(current.trim());
    return result;
  }

  /**
   * 将 ArrayBuffer 转换为 UTF-8 字符串
   * 替代 TextDecoder（部分 ArkTS 环境不支持）
   */
  static arrayBufferToString(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let result: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }
}
