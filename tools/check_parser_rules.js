/**
 * 闸门：课程表 / 作业 DDL 解析规则。
 *
 * 为什么是 .js 而不是 .py：被测逻辑在 ArkTS 里（`FileParserService.ets`），
 * 用 JS 转写最贴近原实现。DevEco 自带 node，无需装任何依赖：
 *
 *     & "D:\DevEco\DevEco Studio\tools\node\node.exe" tools\check_parser_rules.js
 *
 * ⚠️ 诚实说明这个闸门的边界
 * ------------------------
 * 下面的解析函数是**按 .ets 里的实现转写**的，不是直接调用 .ets 代码 ——
 * 所以存在"两边改了一边、闸门却还是绿的"的漂移风险。
 *
 * 为了把这个风险压住，文件末尾有一道**交叉校验**：把 .ets 里所有别名表
 * （`COURSE_NAME_ALIASES` 等）读出来，与闸门里的副本**逐字比较**。
 * 别名是最常被增补、也最容易漏同步的东西，漏了会立刻报 FAIL。
 * 其余逻辑的漂移仍需靠人工 review —— 这条限制不藏着。
 *
 * 退出码 0 = 全部通过。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PARSER = path.join(ROOT, 'app', 'entry', 'src', 'main', 'ets', 'services', 'FileParserService.ets');

/* ================================================================
 * 一、被测逻辑（转写自 FileParserService.ets）
 * ================================================================ */

const COURSE_NAME_ALIASES = ['coursename', 'course', 'name', '课程名称', '课程名', '课程', '科目', '名称', '学科'];
const EXAM_DATE_ALIASES = ['examdate', 'exam', 'date', '考试日期', '考试时间', '考试', '日期'];
const PRIORITY_ALIASES = ['priority', '优先级', '重要程度', '重要度', '紧急程度'];
const STUDY_HOURS_ALIASES = ['studyhours', 'hours', '学习时长', '每周学时', '学时', '时长', '学习时间', '复习时长'];
const STATUS_ALIASES = ['status', '复习状态', '状态', '进度', '复习进度'];
const TITLE_ALIASES = ['title', 'name', 'homework', '作业标题', '标题', '作业名称', '作业', '任务', '任务名称', '内容'];
const DUE_DATE_ALIASES = ['duedate', 'due', 'deadline', 'ddl', '截止日期', '截止时间', '截止', '到期', '到期日'];
const ESTIMATED_MINUTES_ALIASES = ['estimatedminutes', 'minutes', '预计时长', '预计时间', '预计用时', '预计分钟', '预计', '分钟'];

const JSON_COURSE_NAME_KEYS = ['courseName', 'coursename', 'course_name', 'course', 'name', '课程名称', '课程名', '科目', '名称'];
const JSON_EXAM_DATE_KEYS = ['examDate', 'examdate', 'exam_date', 'exam', 'examTime', 'date', '考试日期', '考试时间', '日期'];
const JSON_PRIORITY_KEYS = ['priority', 'level', '优先级', '重要程度'];
const JSON_STUDY_HOURS_KEYS = ['studyHours', 'studyhours', 'study_hours', 'hours', 'weeklyHours', '学习时长', '每周学时', '学时'];
const JSON_STATUS_KEYS = ['status', 'reviewStatus', '复习状态', '状态'];
const JSON_TITLE_KEYS = ['title', 'homework', 'homeworkTitle', 'task', 'name', '作业标题', '标题', '作业名称', '任务', '内容'];
const JSON_DUE_DATE_KEYS = ['dueDate', 'duedate', 'due_date', 'due', 'deadline', 'ddl', '截止日期', '截止时间', '到期'];
const JSON_EST_MINUTES_KEYS = ['estimatedMinutes', 'estimatedminutes', 'estimated_minutes', 'minutes', 'duration', '预计时长', '预计时间', '预计分钟', '分钟'];

function headerMatches(aliases, cell) { return aliases.indexOf(cell.trim().toLowerCase()) >= 0; }

function buildDate(year, month, day) {
  if (year < 1970 || year > 9999) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  const probe = new Date(year, month - 1, day);
  if (probe.getFullYear() !== year || probe.getMonth() !== month - 1 || probe.getDate() !== day) return null;
  const mm = month < 10 ? `0${month}` : `${month}`;
  const dd = day < 10 ? `0${day}` : `${day}`;
  return `${year}-${mm}-${dd}`;
}

function normalizeDate(raw) {
  const text = raw.trim();
  if (text.length === 0) return null;
  const full = text.match(/^(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$/);
  if (full !== null) return buildDate(Number(full[1]), Number(full[2]), Number(full[3]));
  const monthDay = text.match(/^(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$/);
  if (monthDay !== null) {
    const month = Number(monthDay[1]);
    const day = Number(monthDay[2]);
    const today = new Date();
    const year = today.getFullYear();
    let built = buildDate(year, month, day);
    if (built === null) return null;
    const probe = new Date(year, month - 1, day);
    const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    if (probe.getTime() < startOfToday.getTime()) built = buildDate(year + 1, month, day);
    return built;
  }
  return null;
}

function parseDate(raw, rowLabel, fieldLabel) {
  const text = raw.trim();
  if (text.length === 0 || text === '未设置' || text === '-' || text === '—' || text === '/' || text === '无') return '未设置';
  const n = normalizeDate(text);
  if (n === null) throw new Error(`第 ${rowLabel} 行的${fieldLabel}认不出来：「${text}」。`);
  return n;
}

function detectDelimiter(line) {
  const candidates = [',', '\t', '，', ';'];
  let best = ',', bestCount = 0;
  for (let c = 0; c < candidates.length; c++) {
    let count = 0, inQuotes = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') inQuotes = !inQuotes;
      else if (ch === candidates[c] && !inQuotes) count++;
    }
    if (count > bestCount) { bestCount = count; best = candidates[c]; }
  }
  return best;
}

function splitRow(line, delimiter) {
  const result = []; let current = ''; let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') inQuotes = !inQuotes;
    else if (ch === delimiter && !inQuotes) { result.push(current.trim()); current = ''; }
    else current += ch;
  }
  result.push(current.trim());
  return result;
}

function firstDataLine(lines) {
  for (let i = 0; i < lines.length; i++) if (lines[i].trim().length > 0) return i;
  return -1;
}
function looksLikeDataRow(row) {
  return row.length >= 2 && row[0].trim().length > 0 && normalizeDate(row[1]) !== null;
}
function guessPriority(d) { return d <= 3 ? '高' : d <= 10 ? '中' : '低'; }
function guessStatus(h) { return h <= 1 ? '近期复习不足' : h <= 4 ? '近期复习正常' : '近期复习良好'; }

function parseCoursesFromCSV(csvText) {
  const lines = csvText.replace(/\r/g, '').split('\n');
  const headerIndex = firstDataLine(lines);
  if (headerIndex === -1) throw new Error('CSV 内容为空');
  const delimiter = detectDelimiter(lines[headerIndex]);
  const header = splitRow(lines[headerIndex], delimiter);
  const idx = { courseName: -1, examDate: -1, priority: -1, studyHours: -1, status: -1 };
  for (let i = 0; i < header.length; i++) {
    const cell = header[i];
    if (idx.courseName === -1 && headerMatches(COURSE_NAME_ALIASES, cell)) idx.courseName = i;
    if (idx.examDate === -1 && headerMatches(EXAM_DATE_ALIASES, cell)) idx.examDate = i;
    if (idx.priority === -1 && headerMatches(PRIORITY_ALIASES, cell)) idx.priority = i;
    if (idx.studyHours === -1 && headerMatches(STUDY_HOURS_ALIASES, cell)) idx.studyHours = i;
    if (idx.status === -1 && headerMatches(STATUS_ALIASES, cell)) idx.status = i;
  }
  let startRow = headerIndex + 1;
  if (idx.courseName === -1) {
    if (!looksLikeDataRow(header)) throw new Error('CSV 表头缺少课程名称列。');
    idx.courseName = 0;
    idx.examDate = header.length > 1 ? 1 : -1;
    idx.priority = header.length > 2 ? 2 : -1;
    idx.studyHours = header.length > 3 ? 3 : -1;
    idx.status = header.length > 4 ? 4 : -1;
    startRow = headerIndex;
  }
  const out = [];
  for (let i = startRow; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) continue;
    const cols = splitRow(line, delimiter);
    const courseName = (cols[idx.courseName] ?? '').trim();
    if (courseName.length === 0) continue;
    const examDate = parseDate(idx.examDate !== -1 ? (cols[idx.examDate] ?? '') : '', `${i + 1}`, '考试日期');
    const daysLeft = calcDaysLeft(examDate);
    const priority = idx.priority !== -1 && (cols[idx.priority] ?? '').trim().length > 0
      ? cols[idx.priority].trim() : guessPriority(daysLeft);
    const studyHours = idx.studyHours !== -1 ? (Number(cols[idx.studyHours]) || 0) : 0;
    const status = idx.status !== -1 && (cols[idx.status] ?? '').trim().length > 0
      ? cols[idx.status].trim() : guessStatus(studyHours);
    out.push({ courseName, examDate, daysLeft, priority, studyHours, status });
  }
  if (out.length === 0) throw new Error('CSV 中未解析到任何有效课程数据');
  return out;
}

function parseDDLsFromCSV(csvText) {
  const lines = csvText.replace(/\r/g, '').split('\n');
  const headerIndex = firstDataLine(lines);
  if (headerIndex === -1) throw new Error('CSV 内容为空');
  const delimiter = detectDelimiter(lines[headerIndex]);
  const header = splitRow(lines[headerIndex], delimiter);
  const idx = { courseName: -1, title: -1, dueDate: -1, priority: -1, estimatedMinutes: -1 };
  for (let i = 0; i < header.length; i++) {
    const cell = header[i];
    if (idx.courseName === -1 && headerMatches(COURSE_NAME_ALIASES, cell)) idx.courseName = i;
    if (idx.title === -1 && headerMatches(TITLE_ALIASES, cell)) idx.title = i;
    if (idx.dueDate === -1 && headerMatches(DUE_DATE_ALIASES, cell)) idx.dueDate = i;
    if (idx.priority === -1 && headerMatches(PRIORITY_ALIASES, cell)) idx.priority = i;
    if (idx.estimatedMinutes === -1 && headerMatches(ESTIMATED_MINUTES_ALIASES, cell)) idx.estimatedMinutes = i;
  }
  let startRow = headerIndex + 1;
  if (idx.title === -1 && idx.dueDate === -1) {
    if (!looksLikeDataRow(header)) throw new Error('CSV 表头缺少作业标题列或截止日期列。');
    idx.courseName = 0;
    idx.title = header.length > 1 ? 1 : -1;
    idx.dueDate = header.length > 2 ? 2 : -1;
    idx.priority = header.length > 3 ? 3 : -1;
    idx.estimatedMinutes = header.length > 4 ? 4 : -1;
    startRow = headerIndex;
  }
  const out = [];
  for (let i = startRow; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) continue;
    const cols = splitRow(line, delimiter);
    const rawCourse = idx.courseName !== -1 ? (cols[idx.courseName] ?? '').trim() : '';
    const courseName = rawCourse.length > 0 ? rawCourse : '未分类';
    const title = idx.title !== -1 ? (cols[idx.title] ?? '').trim() : '';
    if (title.length === 0 && courseName === '未分类') continue;
    const dueDate = parseDate(idx.dueDate !== -1 ? (cols[idx.dueDate] ?? '') : '', `${i + 1}`, '截止日期');
    const daysLeft = calcDaysLeft(dueDate);
    const priority = idx.priority !== -1 && (cols[idx.priority] ?? '').trim().length > 0
      ? cols[idx.priority].trim() : guessPriority(daysLeft);
    const estimatedMinutes = idx.estimatedMinutes !== -1 ? (Number(cols[idx.estimatedMinutes]) || 30) : 30;
    out.push({ courseName, title: title.length > 0 ? title : '未命名任务', dueDate, daysLeft, priority, estimatedMinutes });
  }
  if (out.length === 0) throw new Error('CSV 中未解析到任何有效作业数据');
  return out;
}

function calcDaysLeft(dateStr) {
  if (dateStr === '未设置') return 30;
  const p = dateStr.split('-');
  if (p.length !== 3) return 30;
  const t = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])).getTime();
  if (Number.isNaN(t)) return 30;
  return Math.max(0, Math.ceil((t - Date.now()) / 86400000));
}

/* ================================================================
 * 二、断言框架
 * ================================================================ */
let passed = 0;
const failures = [];
function check(label, ok, detail) {
  if (ok) { passed++; console.log('  PASS ' + label + (detail ? '   ' + detail : '')); }
  else { failures.push(label); console.log('  FAIL ' + label + (detail ? '   ' + detail : '')); }
}
function eq(label, actual, expected) {
  check(label, JSON.stringify(actual) === JSON.stringify(expected),
    JSON.stringify(actual) === JSON.stringify(expected) ? '' : '实际=' + JSON.stringify(actual));
}
function expectThrow(label, fn) {
  try { fn(); check(label, false, '本应报错但没有'); }
  catch (e) { check(label, true, e.message.slice(0, 50)); }
}

/* ================================================================
 * 三、断言
 * ================================================================ */
console.log('='.repeat(84));
console.log('  闸门：课程表 / 作业 DDL 解析规则');
console.log('='.repeat(84));
console.log('  被测: ' + path.relative(ROOT, PARSER));
console.log();

console.log('① 日期：支持多种写法（原实现只认 new Date() 能吃的）');
eq('2026-10-15', normalizeDate('2026-10-15'), '2026-10-15');
eq('2026/10/15', normalizeDate('2026/10/15'), '2026-10-15');
eq('2026.10.15', normalizeDate('2026.10.15'), '2026-10-15');
eq('2026年10月15日', normalizeDate('2026年10月15日'), '2026-10-15');
eq('2026年10月15', normalizeDate('2026年10月15'), '2026-10-15');
eq('含空格 2026 - 10 - 15', normalizeDate('2026 - 10 - 15'), '2026-10-15');
check('10月15日 → 补年份', normalizeDate('10月15日') !== null, normalizeDate('10月15日'));
check('已过去的月日 → 补下一年',
  normalizeDate('1月5日') > new Date().getFullYear() + '-01-04', normalizeDate('1月5日'));

console.log();
console.log('② 无效日期必须判为无效（原实现静默变 NaN，优先级悄悄算成"低"）');
eq('2026-02-30 不存在', normalizeDate('2026-02-30'), null);
eq('13月1日', normalizeDate('13月1日'), null);
eq('下周三', normalizeDate('下周三'), null);
eq('空串', normalizeDate(''), null);
eq('未设置 → 未设置', parseDate('未设置', '1', '考试日期'), '未设置');
eq('空值 → 未设置', parseDate('', '1', '考试日期'), '未设置');
expectThrow('「待定」→ 抛错而非 NaN', () => parseDate('待定', '3', '考试日期'));

console.log();
console.log('③ 表头别名（原实现每字段只认 2–3 个精确词）');
eq('科目/考试时间/重要程度/学时/状态', (() => {
  const r = parseCoursesFromCSV('科目,考试时间,重要程度,学时,状态\n数据结构,2026年10月15日,高,2,近期复习不足');
  return [r[0].courseName, r[0].examDate, r[0].priority, r[0].studyHours, r[0].status];
})(), ['数据结构', '2026-10-15', '高', 2, '近期复习不足']);
eq('大小写与空格不敏感', (() => {
  const r = parseCoursesFromCSV(' CourseName , ExamDate \n数据结构,2026-10-15');
  return [r[0].courseName, r[0].examDate];
})(), ['数据结构', '2026-10-15']);

console.log();
console.log('④ 分隔符自动识别（教务系统 / Excel 复制出来的常是制表符）');
eq('制表符', (() => {
  const r = parseCoursesFromCSV('课程名称\t考试日期\t优先级\n数据结构\t2026-10-15\t高');
  return [r[0].courseName, r[0].examDate, r[0].priority];
})(), ['数据结构', '2026-10-15', '高']);
eq('中文逗号', (() => {
  const r = parseCoursesFromCSV('课程名称，考试日期，优先级\n数据结构，2026-10-15，高');
  return [r[0].courseName, r[0].priority];
})(), ['数据结构', '高']);

console.log();
console.log('⑤ 无表头兜底，但认不出的表头不许瞎猜');
eq('纯数据两列', (() => {
  const r = parseCoursesFromCSV('数据结构,2026-10-15\n操作系统,2026-10-22');
  return r.map(x => x.courseName + '/' + x.examDate);
})(), ['数据结构/2026-10-15', '操作系统/2026-10-22']);
expectThrow('表头认不出且不像数据 → 如实报错', () => parseCoursesFromCSV('a,b,c\n1,2,3'));

console.log();
console.log('⑥ 原格式回归（改之前能用的，改之后必须还能用）');
eq('文档标准 CSV', (() => {
  const r = parseCoursesFromCSV('课程名称,考试日期,优先级,学习时长,复习状态\n数据结构,2026-10-15,高,2,近期复习不足');
  return [r[0].courseName, r[0].examDate, r[0].priority, r[0].studyHours, r[0].status];
})(), ['数据结构', '2026-10-15', '高', 2, '近期复习不足']);
eq('英文键名表头', (() => {
  const r = parseCoursesFromCSV('courseName,examDate\n数据结构,2026-10-15');
  return r[0].courseName;
})(), '数据结构');
eq('引号内含逗号', parseCoursesFromCSV('课程名称,考试日期\n"图算法（第 6 章, 含附加题）",2026-09-29')[0].courseName,
  '图算法（第 6 章, 含附加题）');
eq('CRLF 换行', (() => {
  const r = parseCoursesFromCSV('课程名称,考试日期\r\n数据结构,2026-10-15\r\n');
  return [r.length, r[0].courseName];
})(), [1, '数据结构']);
eq('缺列回落推断值', (() => {
  const r = parseCoursesFromCSV('课程名称\n数据结构');
  return [r[0].examDate, r[0].daysLeft];
})(), ['未设置', 30]);
eq('DDL：标准 CSV', (() => {
  const r = parseDDLsFromCSV('课程名称,作业标题,截止日期,优先级,预计时长\n数据结构,二叉树遍历实验报告,2026-09-26,高,45');
  return [r[0].courseName, r[0].title, r[0].dueDate, r[0].priority, r[0].estimatedMinutes];
})(), ['数据结构', '二叉树遍历实验报告', '2026-09-26', '高', 45]);
eq('DDL：中文日期', parseDDLsFromCSV('作业标题,截止日期\n实验报告,2026年9月26日')[0].dueDate, '2026-09-26');

console.log();
console.log('⑦ 中文日期能算出正确的剩余天数（原实现是 NaN）');
check('与 ISO 写法结果一致',
  calcDaysLeft(normalizeDate('2026年10月15日')) === calcDaysLeft(normalizeDate('2026-10-15'))
  && calcDaysLeft(normalizeDate('2026-10-15')) > 0,
  '剩余 ' + calcDaysLeft(normalizeDate('2026-10-15')) + ' 天');

console.log();
console.log('⑧ 交叉校验：闸门里的别名表必须与 .ets 逐字一致（防漂移）');
(function () {
  if (!fs.existsSync(PARSER)) {
    check('找到 FileParserService.ets', false, PARSER);
    return;
  }
  const src = fs.readFileSync(PARSER, 'utf8');
  const pairs = [
    ['COURSE_NAME_ALIASES', COURSE_NAME_ALIASES],
    ['EXAM_DATE_ALIASES', EXAM_DATE_ALIASES],
    ['PRIORITY_ALIASES', PRIORITY_ALIASES],
    ['STUDY_HOURS_ALIASES', STUDY_HOURS_ALIASES],
    ['STATUS_ALIASES', STATUS_ALIASES],
    ['TITLE_ALIASES', TITLE_ALIASES],
    ['DUE_DATE_ALIASES', DUE_DATE_ALIASES],
    ['ESTIMATED_MINUTES_ALIASES', ESTIMATED_MINUTES_ALIASES],
    ['JSON_COURSE_NAME_KEYS', JSON_COURSE_NAME_KEYS],
    ['JSON_EXAM_DATE_KEYS', JSON_EXAM_DATE_KEYS],
    ['JSON_PRIORITY_KEYS', JSON_PRIORITY_KEYS],
    ['JSON_STUDY_HOURS_KEYS', JSON_STUDY_HOURS_KEYS],
    ['JSON_STATUS_KEYS', JSON_STATUS_KEYS],
    ['JSON_TITLE_KEYS', JSON_TITLE_KEYS],
    ['JSON_DUE_DATE_KEYS', JSON_DUE_DATE_KEYS],
    ['JSON_EST_MINUTES_KEYS', JSON_EST_MINUTES_KEYS]
  ];
  for (const [name, mirror] of pairs) {
    const m = src.match(new RegExp('const\\s+' + name + '\\s*(?::\\s*string\\[\\])?\\s*=\\s*\\[([\\s\\S]*?)\\]'));
    if (m === null) { check(name + ' 在 .ets 中找得到', false); continue; }
    const actual = (m[1].match(/'[^']*'/g) || []).map(s => s.slice(1, -1));
    eq(name + ' 与 .ets 一致', mirror, actual);
  }
})();

console.log();
console.log('='.repeat(84));
if (failures.length > 0) {
  console.log(`结论：FAIL（${failures.length} 项不满足）`);
  for (const f of failures) console.log('  - ' + f);
  process.exit(1);
}
console.log(`结论：PASS —— ${passed} 项全部通过（含与 .ets 的别名表交叉校验）`);
process.exit(0);
