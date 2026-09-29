const fs = require('node:fs/promises');
const path = require('node:path');
const { FileBlob, SpreadsheetFile, Workbook } = require('@oai/artifact-tool');

const outputDir = path.resolve('02-演示视频', '测试素材', '搭子匹配');
const fontFamily = 'Arial';

const accountA = [
  ['课程名称', '作业标题', '截止日期', '优先级', '预计时间（分钟）', '距准备日天数'],
  ['数据结构', '二叉树遍历实验报告', new Date('2026-10-01T00:00:00+08:00'), '高', 90, null],
  ['离散数学', '图论习题集', new Date('2026-10-03T00:00:00+08:00'), '中', 60, null],
  ['计算机网络', 'TCP拥塞控制实验', new Date('2026-10-06T00:00:00+08:00'), '中', 75, null],
];

const accountB = [
  ['课程名称', '作业标题', '截止日期', '优先级', '预计时间（分钟）', '距准备日天数'],
  ['数据结构', '图算法专题互测', new Date('2026-10-01T00:00:00+08:00'), '高', 75, null],
  ['离散数学', '组合数学讲解稿', new Date('2026-10-03T00:00:00+08:00'), '中', 60, null],
  ['操作系统', '进程调度实验', new Date('2026-10-06T00:00:00+08:00'), '中', 90, null],
];

function styleDdlSheet(sheet, title, rows, tabColor) {
  sheet.showGridLines = false;
  sheet.tabColor = tabColor;
  sheet.getRange('A2:F5').values = rows;
  sheet.getRange('A1:F1').values = [[title, '', '', '', '', '']];
  sheet.getRange('A1:F1').format.font = { name: fontFamily, size: 14, bold: true, color: '#172033' };
  sheet.getRange('A1:F1').format.rowHeight = 28;
  sheet.getRange('A2:F2').format = {
    fill: '#1D4ED8',
    font: { name: fontFamily, size: 10, bold: true, color: '#FFFFFF' },
    horizontalAlignment: 'center',
    verticalAlignment: 'center',
    borders: { preset: 'inside', style: 'thin', color: '#FFFFFF' },
  };
  sheet.getRange('A3:F5').format.font = { name: fontFamily, size: 10, color: '#172033' };
  sheet.getRange('A3:F5').format.verticalAlignment = 'center';
  sheet.getRange('A3:F5').format.borders = { preset: 'inside', style: 'thin', color: '#DCE6F4' };
  sheet.getRange('C3:C5').setNumberFormat('yyyy-mm-dd');
  sheet.getRange('E3:F5').format.numberFormat = '0';
  sheet.getRange('F3').formulas = [['=C3-DATE(2026,9,29)']];
  sheet.getRange('F3:F5').fillDown();
  sheet.getRange('D3:D5').conditionalFormats.add('containsText', {
    text: '高', format: { fill: '#FEE2E2', font: { bold: true, color: '#B91C1C' } },
  });
  sheet.getRange('D3:D5').conditionalFormats.add('containsText', {
    text: '中', format: { fill: '#FEF3C7', font: { color: '#92400E' } },
  });
  sheet.getRange('A2:F5').format.rowHeight = 24;
  sheet.getRange('A:A').format.columnWidth = 16;
  sheet.getRange('B:B').format.columnWidth = 28;
  sheet.getRange('C:C').format.columnWidth = 16;
  sheet.getRange('D:D').format.columnWidth = 12;
  sheet.getRange('E:E').format.columnWidth = 18;
  sheet.getRange('F:F').format.columnWidth = 16;
  sheet.freezePanes.freezeRows(2);
  sheet.tables.add('A2:F5', true, `${sheet.name.replace(/[^A-Za-z0-9]/g, '') || 'DDL'}Table`);
}

async function main() {
  const workbook = Workbook.create();
  const guide = workbook.worksheets.add('使用说明');
  const sheetA = workbook.worksheets.add('账号A_DDL');
  const sheetB = workbook.worksheets.add('账号B_DDL');

  guide.showGridLines = false;
  guide.tabColor = '#64748B';
  guide.getRange('A1:B8').values = [
    ['知学 Mate 搭子匹配测试数据', ''],
    ['', ''],
    ['准备日期', new Date('2026-09-29T00:00:00+08:00')],
    ['共同主攻课程', '数据结构'],
    ['共同学习目标', '数据结构期末80+'],
    ['共同空闲时段', '19:30-21:30'],
    ['账号 A 互补方向', '强：递归理解；弱：图算法'],
    ['账号 B 互补方向', '强：图算法；弱：递归理解'],
  ];
  guide.getRange('A1:B1').format.font = { name: fontFamily, size: 14, bold: true, color: '#172033' };
  guide.getRange('A3:A8').format = { fill: '#E8F0FE', font: { name: fontFamily, size: 10, bold: true, color: '#1E3A8A' } };
  guide.getRange('B3:B8').format.font = { name: fontFamily, size: 10, color: '#172033' };
  guide.getRange('B3').setNumberFormat('yyyy-mm-dd');
  guide.getRange('A1:B8').format.verticalAlignment = 'center';
  guide.getRange('A:A').format.columnWidth = 24;
  guide.getRange('B:B').format.columnWidth = 38;
  guide.getRange('A3:B8').format.rowHeight = 24;

  styleDdlSheet(sheetA, '账号 A · 林晓宇 DDL', accountA, '#2563EB');
  styleDdlSheet(sheetB, '账号 B · 周沐晴 DDL', accountB, '#0891B2');

  workbook.recalculate();
  const inspection = await workbook.inspect({
    kind: 'sheet,region,formula',
    maxChars: 5000,
    tableMaxRows: 8,
    tableMaxCols: 8,
  });
  console.log(inspection.ndjson || inspection);

  await fs.mkdir(outputDir, { recursive: true });
  const workbookPath = path.join(outputDir, '搭子匹配测试数据总表.xlsx');
  const xlsx = await SpreadsheetFile.exportXlsx(workbook);
  await xlsx.save(workbookPath);
  for (const sheetName of ['账号A_DDL', '账号B_DDL']) {
    const imported = await SpreadsheetFile.importXlsx(await FileBlob.load(workbookPath));
    const preview = await imported.render({ sheetName, autoCrop: 'all', scale: 1, format: 'png' });
    const fileName = sheetName === '账号A_DDL' ? 'DDL总表预览_账号A.png' : 'DDL总表预览_账号B.png';
    await fs.writeFile(path.join(outputDir, fileName), new Uint8Array(await preview.arrayBuffer()));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
