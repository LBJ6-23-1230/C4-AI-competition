# 启动 HarmonyOS 模拟器 + 安装最新 HAP（一键）
#
# 背景（实测结论，2026-09-22）：
#   本机 Windows 10 家庭版本可以跑 DevEco 本地模拟器，**不需要**改 bcdedit、
#   **不需要**重启、**不需要**管理员权限。HvHost/vmcompute 服务已在运行。
#
#   ⚠️ 唯一的坑：**必须让模拟器脱离启动**。
#   若在 PowerShell 里直接 `Emulator.exe -start ...`，启动进程一退出，
#   模拟器也会被一起带走（实测 isRunning 从 true 变 false，只剩崩溃服务进程）。
#   用 `cmd /c start` 让它独立于父 shell 才能稳定驻留。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\start_emulator.ps1
#   powershell -ExecutionPolicy Bypass -File tools\start_emulator.ps1 -Name 'MatePad Pro 13'
#   powershell -ExecutionPolicy Bypass -File tools\start_emulator.ps1 -InstallHap

param(
    [string]$Name = 'Pura 90',
    [switch]$InstallHap,
    [switch]$SkipBuildCheck
)

$ErrorActionPreference = 'Continue'

$emuDir  = 'D:\DevEco\DevEco Studio\tools\emulator'
$emu     = Join-Path $emuDir 'Emulator.exe'
$hdc     = 'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$root    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$signed  = Join-Path $root 'deliverables\知学Mate-signed.hap'

Write-Host '=== 知学 Mate · 模拟器启动器 ===' -ForegroundColor Cyan

foreach ($f in @($emu, $hdc)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[X] 缺少: $f" -ForegroundColor Red
        Write-Host '    请确认 DevEco Studio 安装在 D:\DevEco\DevEco Studio' -ForegroundColor Yellow
        exit 1
    }
}

# ---- 已运行则直接复用 ----
$targets = (& $hdc list targets 2>&1) -join ' '
if ($targets -and $targets -notmatch 'Empty') {
    Write-Host "[=] 已有设备在线: $targets（跳过启动）" -ForegroundColor Green
} else {
    Write-Host "[1] 启动实例: $Name" -ForegroundColor Cyan
    Write-Host '    （脱离父进程启动，否则模拟器会随本脚本退出而关闭）' -ForegroundColor Gray
    cmd /c "start `"HarmonyOS Emulator`" `"$emu`" -start `"$Name`""

    Write-Host '[2] 等待设备就绪（首次启动约 1~3 分钟）...' -ForegroundColor Cyan
    $ready = $false
    for ($i = 1; $i -le 24; $i++) {
        Start-Sleep -Seconds 15
        $t = (& $hdc list targets 2>&1) -join ' '
        $p = Get-Process -Name 'Emulator' -ErrorAction SilentlyContinue |
             Where-Object { $_.WorkingSet64 -gt 100MB }
        $mb = if ($p) { [math]::Round(($p | Measure-Object -Sum WorkingSet64).Sum / 1MB, 0) } else { 0 }
        Write-Host ("    [{0,2}] {1,-24} Emulator {2} MB" -f $i, $(if ($t) { $t } else { '(等待)' }), $mb)
        if ($t -and $t -notmatch 'Empty') { $ready = $true; break }
    }
    if (-not $ready) {
        Write-Host '[X] 超时未就绪。排查方向：' -ForegroundColor Red
        Write-Host '    · 模拟器窗口是否报 Hyper-V / 内存 / 镜像错误' -ForegroundColor Yellow
        Write-Host '    · 官方 FAQ: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-faqs' -ForegroundColor Yellow
        exit 1
    }
    Write-Host '[√] 设备已就绪' -ForegroundColor Green
}

# ---- 设备信息 ----
Write-Host ''
Write-Host '=== 设备 ===' -ForegroundColor Cyan
Write-Host ("  targets       : {0}" -f ((& $hdc list targets 2>&1) -join ' '))
Write-Host ("  API 版本      : {0}" -f ((& $hdc shell param get const.ohos.apiversion 2>&1) -join '').Trim())
Write-Host ("  软件版本      : {0}" -f ((& $hdc shell param get const.product.software.version 2>&1) -join '').Trim())
$udid = ((& $hdc shell 'bm get -u' 2>&1) -join ' ')
if ($udid -match '([0-9A-F]{64})') { Write-Host ("  UDID          : {0}" -f $Matches[1]) }

# ---- 安装 HAP ----
if ($InstallHap) {
    Write-Host ''
    Write-Host '=== 安装签名 HAP ===' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $signed)) {
        Write-Host "[X] 找不到 $signed" -ForegroundColor Red
        Write-Host '    先跑 tools\sign_hap.ps1，或用 DevEco Build Hap(s)' -ForegroundColor Yellow
        exit 1
    }
    $size = [math]::Round((Get-Item -LiteralPath $signed).Length / 1KB, 1)
    Write-Host ("  文件: {0}  ({1} KB)" -f $signed, $size)
    & $hdc install -r "$signed" 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[X] 安装失败' -ForegroundColor Red
        exit 1
    }
    Write-Host '[√] 安装成功' -ForegroundColor Green
    Write-Host ''
    Write-Host '[3] 启动应用' -ForegroundColor Cyan
    & $hdc shell 'aa start -a EntryAbility -b com.zhixue.mate' 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host '=== 常用命令 ===' -ForegroundColor Cyan
Write-Host "  截图      : & '$hdc' shell `"snapshot_display -f /data/local/tmp/s.jpeg`"; & '$hdc' file recv /data/local/tmp/s.jpeg .\screen.jpeg" -ForegroundColor Gray
Write-Host "  看日志    : & '$hdc' shell `"hilog -x | grep -i zhixue`"" -ForegroundColor Gray
Write-Host "  停止      : & '$emu' -stop '$Name'" -ForegroundColor Gray
Write-Host ''
Write-Host '  提示：模拟器内访问本机后端用 http://10.0.2.2:5000（不是 127.0.0.1）' -ForegroundColor Yellow
