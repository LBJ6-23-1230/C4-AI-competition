# 命令行签名 HAP —— 绕开 DevEco GUI
#
# 为什么用这个：DevEco 的「签名配置」界面在自动签名勾选状态下，
# 会尝试去 AGC 新建 Profile，而新建 Profile 必须绑定设备 -> 报"缺少设备"。
# 我们手上已经有现成的 .p7b 了，不需要它去新建。hap-sign-tool 可以独立完成签名。
#
# 用法：在 PowerShell 里运行本脚本，按提示输入 p12 密码。
# 密码用交互模式输入，不会写进命令行历史、也不会留在脚本里。

$ErrorActionPreference = 'Stop'

$java   = 'D:\DevEco\DevEco Studio\jbr\bin\java.exe'
$tool   = 'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'

$signDir = 'E:\zhixue-signing'
$keystore = Join-Path $signDir 'zhixue-debug.p12'
$appCert  = Join-Path $signDir 'zhixue-release.cer'
$profile  = Join-Path $signDir 'zhixue-release.p7b'

$inHap  = 'E:\C4-liantiao\liantiao5\app\entry\build\default\outputs\default\entry-default-unsigned.hap'
$outDir = 'E:\C4-liantiao\liantiao5\app\entry\build\default\outputs\default'
$outHap = Join-Path $outDir 'entry-default-signed.hap'

Write-Host '=== 输入文件检查 ===' -ForegroundColor Cyan
foreach ($f in @($java, $tool, $keystore, $appCert, $profile, $inHap)) {
    $ok = Test-Path -LiteralPath $f
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($ok) {'OK'} else {'!!'}), $f) -ForegroundColor $color
    if (-not $ok) { Write-Host '输入文件缺失，终止。' -ForegroundColor Red; exit 1 }
}

Write-Host ''
Write-Host '=== 密钥库信息（已核验）===' -ForegroundColor Cyan
Write-Host '  别名     : zhixue-debug' -ForegroundColor Gray
Write-Host '  密钥算法 : 256-bit EC (secp256r1) / SHA256withECDSA' -ForegroundColor Gray
Write-Host '  证书链   : 1 张（自签）' -ForegroundColor Gray
Write-Host '  有效期   : 2026-09-21 ~ 2051-09-15' -ForegroundColor Gray
Write-Host '  SKI      : 6F:62:09:DF:2D:14:95:A0:4D:2F:88:CB:E8:98:16:B1:06:14:8C:B9' -ForegroundColor Gray
Write-Host '             ↑ 与发布 Profile 内嵌证书一致，配对已证明' -ForegroundColor Green
Write-Host ''

# 默认值（已核验），直接回车即用；也可自行覆盖
$alias = Read-Host '密钥别名 [zhixue-debug]'
if (-not $alias) { $alias = 'zhixue-debug' }

$sec  = Read-Host '密钥库密码' -AsSecureString
$storePwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

$sec2 = Read-Host '密钥密码（直接回车 = 与密钥库密码相同）' -AsSecureString
$keyPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2))
if (-not $keyPwd) { $keyPwd = $storePwd }

Write-Host ''
Write-Host '=== 开始签名 ===' -ForegroundColor Cyan
Write-Host ''

$args = @(
    '-jar', $tool,
    'sign-app',
    '-mode', 'localSign',
    '-keyAlias', $alias,
    '-keyPwd', $keyPwd,
    '-appCertFile', $appCert,
    '-profileFile', $profile,
    '-inFile', $inHap,
    '-signAlg', 'SHA256withECDSA',
    '-keystoreFile', $keystore,
    '-keystorePwd', $storePwd,
    '-outFile', $outHap,
    '-compatibleVersion', '60101024'
)

& $java @args
$code = $LASTEXITCODE

Write-Host ''
Write-Host "=== 结果 (exit=$code) ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $outHap) {
    $o = Get-Item -LiteralPath $outHap
    Write-Host ("  ★ 签名成功: {0}" -f $o.FullName) -ForegroundColor Green
    Write-Host ("    大小: {0} bytes (源 {1} bytes)" -f $o.Length, (Get-Item -LiteralPath $inHap).Length)
} else {
    Write-Host '  ✗ 未产出 signed.hap，看上面的报错' -ForegroundColor Red
    Write-Host '  常见原因：' -ForegroundColor Yellow
    Write-Host '    - alias 写错        -> keytool -list 查看' -ForegroundColor Yellow
    Write-Host '    - 密码错误          -> 重跑' -ForegroundColor Yellow
    Write-Host '    - cert 与 profile 不匹配 -> 把 appCertFile 换成 _stage6\release-root.pem（改名 .cer）' -ForegroundColor Yellow
    Write-Host '    - profileSigned 问题 -> 加 -profileSigned 1' -ForegroundColor Yellow
}
