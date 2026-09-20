param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$TestHapPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'entry\build\default\outputs\ohosTest\entry-ohosTest-unsigned.hap'),
    [string]$BundleName = 'com.zhixue.mate',
    [string]$TestModule = 'entry_test',
    [int]$ExpectedTests = 44,
    [int]$MaxAttempts = 4
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HdcPath -PathType Leaf)) {
    throw "HDC not found: $HdcPath"
}
if (-not (Test-Path -LiteralPath $TestHapPath -PathType Leaf)) {
    throw "Test HAP not found: $TestHapPath"
}

$targets = & $HdcPath list targets -v 2>&1 | Out-String
if ($targets -notmatch '\bConnected\b') {
    throw "No connected HarmonyOS target was found.`n$targets"
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    if ($attempt -gt 1) {
        Start-Sleep -Seconds 5
    }

    $installOutput = & $HdcPath install -r $TestHapPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $installOutput -notmatch 'install bundle successfully') {
        throw "Failed to install test HAP.`n$installOutput"
    }

    # The emulator occasionally recycles TestAbility immediately after reinstall.
    # Waiting before launch keeps the complete Hypium report deterministic.
    Start-Sleep -Seconds 5
    $testOutput = & $HdcPath shell aa test -b $BundleName -m $TestModule `
        -s unittest OpenHarmonyTestRunner -s timeout 180000 2>&1 | Out-String

    $summary = [regex]::Match(
        $testOutput,
        'Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+), Ignore: (\d+)'
    )
    if (-not $summary.Success) {
        Write-Warning "Attempt $attempt did not return a complete test report; retrying."
        continue
    }

    $testsRun = [int]$summary.Groups[1].Value
    $failures = [int]$summary.Groups[2].Value
    $errors = [int]$summary.Groups[3].Value
    $passes = [int]$summary.Groups[4].Value
    $ignored = [int]$summary.Groups[5].Value

    Write-Output "Tests run: $testsRun; Pass: $passes; Failure: $failures; Error: $errors; Ignore: $ignored"
    if ($testsRun -ne $ExpectedTests -or $passes -ne $ExpectedTests -or
        $failures -ne 0 -or $errors -ne 0 -or $ignored -ne 0) {
        Write-Output $testOutput
        exit 1
    }
    exit 0
}

throw "The HarmonyOS test runner did not return a complete report after $MaxAttempts attempts."
