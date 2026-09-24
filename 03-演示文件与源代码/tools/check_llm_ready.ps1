# 知学 Mate · 演示前 LLM 自检（30 秒）
#
# 为什么需要：DashScope 的免费额度**按模型分别计算**，且会在无通知的情况下耗尽。
# 一旦录制演示视频时才发现识图失效，损失的是不可重来的时间。
# 本脚本按演示真实用到的模型各打一次调用，全部通过才建议开录。
#
# 用法（在仓库根目录或任意位置均可）：
#     powershell -ExecutionPolicy Bypass -File tools\check_llm_ready.ps1

$ErrorActionPreference = 'Stop'

# 取脚本自身目录：$PSScriptRoot 在部分调用方式下为空，故做多路回退
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$root = Split-Path -Parent $here

$envFile = Join-Path $root 'server\zhixue-agent-server\.env'
$python = $null

# 找一个可用解释器（优先工程 venv，其次 PATH）
$parent = Split-Path -Parent $root
$candidates = @()
if ($parent) {
    $candidates += (Join-Path $parent '.venv-lt\Scripts\python.exe')
    $candidates += (Join-Path $parent '.venv\Scripts\python.exe')
}
$candidates += (Join-Path $root '.venv\Scripts\python.exe')

foreach ($cand in $candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $python = $cand; break }
}
if (-not $python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source }
}
if (-not $python) {
    Write-Host '[X] 找不到 Python 解释器' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Host "[X] 未找到 .env：$envFile" -ForegroundColor Red
    Write-Host '    请先 Copy-Item server\zhixue-agent-server\.env.example .env 并填入 DASHSCOPE_API_KEY' -ForegroundColor Yellow
    exit 1
}

Write-Host '=== 知学 Mate · 演示前 LLM 自检 ===' -ForegroundColor Cyan
Write-Host "  解释器 : $python"
Write-Host "  .env   : $envFile"
Write-Host ''

$script = Join-Path $PSScriptRoot 'check_llm_ready.py'
if (-not (Test-Path -LiteralPath $script)) {
    Write-Host "[X] 缺少 $script" -ForegroundColor Red
    exit 1
}

& $python $script
$code = $LASTEXITCODE

Write-Host ''
if ($code -eq 0) {
    Write-Host '>>> 自检通过，可以开始录制 / 答辩演示。' -ForegroundColor Green
} else {
    Write-Host '>>> 自检未通过，先处理上面的问题再录。' -ForegroundColor Red
    Write-Host '    常见原因与处理：' -ForegroundColor Yellow
    Write-Host '      AllocationQuota.FreeTierOnly -> 该模型免费额度耗尽，换模型或充值' -ForegroundColor Yellow
    Write-Host '      InvalidApiKey                -> Key 失效/写错' -ForegroundColor Yellow
    Write-Host '      Arrearage                    -> 账户欠费' -ForegroundColor Yellow
    Write-Host '      Throttling                   -> 触发限流，等一会儿再试' -ForegroundColor Yellow
}
exit $code
