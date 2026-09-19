# 知学 Mate · 后端一键启动脚本
#
# 用法（在 liantiao1 根目录执行）：
#   powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1
#   powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1 -Port 5001
#   powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1 -Check
#
# 脚本会：① 找到可用的 Python 3.12 解释器  ② 检查依赖  ③ 提示 .env 状态  ④ 启动服务

[CmdletBinding()]
param(
    [int]$Port = 5000,
    [switch]$Check,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ServerDir = Join-Path $RepoRoot 'server\zhixue-agent-server'

if (-not (Test-Path $ServerDir)) {
    Write-Host "找不到后端目录：$ServerDir" -ForegroundColor Red
    exit 1
}

function Resolve-Python312 {
    $preferred = New-Object System.Collections.ArrayList
    [void]$preferred.Add('E:\C4联调\.venv-lt\Scripts\python.exe')
    [void]$preferred.Add((Join-Path $RepoRoot '.venv\Scripts\python.exe'))
    [void]$preferred.Add((Join-Path $RepoRoot '.venv-lt\Scripts\python.exe'))
    foreach ($candidate in $preferred) {
        if (Test-Path $candidate) { return $candidate }
    }

    $launcher = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($launcher) {
        $listed = & py --list 2>$null
        $tag = $listed | Select-String -Pattern '3\.12' | Select-Object -First 1
        if ($tag) {
            $name = ($tag.Line -split '\s+')[0].Trim()
            if ($name) {
                $exe = & py $name -c "import sys; print(sys.executable)" 2>$null
                if ($exe -and (Test-Path $exe)) { return $exe }
            }
        }
    }

    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $version = (& $cmd.Source --version 2>&1) -join ''
            if ($version -match '3\.(1[2-9]|[2-9][0-9])') { return $cmd.Source }
        }
    }
    return $null
}

Write-Host ''
Write-Host '========================================================================' -ForegroundColor Cyan
Write-Host '  知学 Mate · 统一后端启动' -ForegroundColor Cyan
Write-Host '========================================================================' -ForegroundColor Cyan

$python = Resolve-Python312
if (-not $python) {
    Write-Host '  x 未找到 Python 3.12+ 解释器。' -ForegroundColor Red
    Write-Host '    本工程使用 str | Path 语法，Python 3.8 无法运行。请先执行：' -ForegroundColor Yellow
    Write-Host '      uv venv E:\C4联调\.venv-lt --python 3.12' -ForegroundColor Yellow
    Write-Host '      uv pip install --python E:\C4联调\.venv-lt\Scripts\python.exe flask flask-cors openai python-dotenv pytest' -ForegroundColor Yellow
    exit 1
}

$pythonVersion = (& $python --version 2>&1) -join ''
Write-Host "  Python   : $python" -ForegroundColor Green
Write-Host "             $pythonVersion"

if (-not $SkipInstall) {
    $missing = New-Object System.Collections.ArrayList
    foreach ($module in @('flask', 'flask_cors', 'openai', 'dotenv')) {
        & $python -c "import $module" 2>$null
        if ($LASTEXITCODE -ne 0) { [void]$missing.Add($module) }
    }

    if ($missing.Count -gt 0) {
        $missingList = $missing -join ', '
        Write-Host ('  缺少依赖：' + $missingList + ' -> 正在安装…') -ForegroundColor Yellow
        & $python -m pip install -r (Join-Path $ServerDir 'requirements.txt')
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  x 依赖安装失败，请手动安装 requirements.txt。' -ForegroundColor Red
            exit 1
        }
    }
    else {
        Write-Host '  依赖     : 已就绪' -ForegroundColor Green
    }
}

$envFile = Join-Path $ServerDir '.env'
$hasEnvFile = Test-Path $envFile
$hasKey = $false
if ($hasEnvFile) {
    $envText = Get-Content $envFile -Raw
    $hasKey = $envText -match 'DASHSCOPE_API_KEY\s*=\s*sk-\S'
}

if ($hasKey) {
    Write-Host '  LLM      : 已配置 Key（聊天层走真实大模型）' -ForegroundColor Green
}
elseif ($hasEnvFile) {
    Write-Host '  LLM      : .env 存在但 Key 仍是占位值 -> 聊天层降级为确定性规则' -ForegroundColor Yellow
}
else {
    Write-Host '  LLM      : 未创建 .env -> 聊天层降级为确定性规则（不会伪装成 LLM 输出）' -ForegroundColor Yellow
    Write-Host "             如需真实 AI：Copy-Item '$ServerDir\.env.example' '$envFile'" -ForegroundColor DarkGray
}

Write-Host "  端口     : $Port"
Write-Host '========================================================================' -ForegroundColor Cyan
Write-Host ''

Push-Location $ServerDir
try {
    if ($Check) {
        & $python run.py --port $Port --check
    }
    else {
        & $python run.py --port $Port
    }
}
finally {
    Pop-Location
}
