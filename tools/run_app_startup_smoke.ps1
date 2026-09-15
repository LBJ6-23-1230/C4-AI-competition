param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$BundleName = 'com.zhixue.mate',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $HdcPath -PathType Leaf)) {
    throw "hdc was not found: $HdcPath"
}

$targets = (& $HdcPath list targets | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($targets) -or $targets -match '\[Empty\]') {
    throw 'No HarmonyOS device or emulator is connected.'
}

& $HdcPath shell aa force-stop $BundleName | Out-Null
$startOutput = (& $HdcPath shell aa start -a $AbilityName -b $BundleName | Out-String).Trim()
if ($startOutput -notmatch 'success') {
    throw "Ability start failed: $startOutput"
}

$processId = ''
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $processId = (& $HdcPath shell pidof $BundleName | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($processId)) {
        break
    }
    Start-Sleep -Milliseconds 250
}
if ([string]::IsNullOrWhiteSpace($processId)) {
    throw 'Application process did not stay alive after startup.'
}

Start-Sleep -Seconds 2
$logs = (& $HdcPath shell hilog -x -P $processId | Out-String)
if ($logs -notmatch 'Succeeded in loading the content') {
    throw 'The application process started, but page content loading was not confirmed in hilog.'
}
$fatalPattern = '(?im)(uncaught\s+(exception|error)|unhandledpromiserejection|fatal exception|js[_ ]?crash|signal\s+11|appfreeze)'
if ($logs -match $fatalPattern) {
    throw "Startup error detected in hilog:`n$logs"
}
$processAfterLoad = (& $HdcPath shell pidof $BundleName | Out-String).Trim()
if ($processAfterLoad -ne $processId) {
    throw "Application process changed or exited during startup: before=$processId after=$processAfterLoad"
}

Write-Output "App startup smoke passed: $BundleName/$AbilityName, pid=$processId, content loaded."
