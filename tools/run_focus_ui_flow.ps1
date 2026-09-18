param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$BundleName = 'com.zhixue.mate',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
$deviceLayoutPath = '/data/local/tmp/zhixue-focus-layout.json'
$localLayoutPath = Join-Path ([IO.Path]::GetTempPath()) 'zhixue-focus-layout.json'

function Get-Layout {
    & $HdcPath shell uitest dumpLayout -p $deviceLayoutPath -b $BundleName | Out-Null
    & $HdcPath file recv $deviceLayoutPath $localLayoutPath | Out-Null
    return Get-Content -LiteralPath $localLayoutPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-AppRoot($Layout) {
    foreach ($candidate in @($Layout.children)) {
        if ($candidate.attributes.bundleName -eq $BundleName) { return $candidate }
    }
    throw "No visible UI root found for $BundleName."
}

function Find-TextNodes($Node, [string]$Text) {
    if ($null -ne $Node.attributes -and $Node.attributes.text -eq $Text -and $Node.attributes.visible -eq 'true') {
        $Node
    }
    foreach ($child in @($Node.children)) { Find-TextNodes $child $Text }
}

function Find-TextNodesContaining($Node, [string]$Text) {
    if ($null -ne $Node.attributes -and $Node.attributes.text -like "*$Text*" -and $Node.attributes.visible -eq 'true') {
        $Node
    }
    foreach ($child in @($Node.children)) { Find-TextNodesContaining $child $Text }
}

function Assert-Page([string]$ExpectedPage) {
    $actualPage = (Get-AppRoot (Get-Layout)).attributes.pagePath
    if ($actualPage -ne $ExpectedPage) { throw "Expected page '$ExpectedPage', got '$actualPage'." }
}

function Assert-VisibleText([string]$Text) {
    if (@(Find-TextNodes (Get-Layout) $Text).Count -eq 0) { throw "Expected visible text was not found: $Text" }
}

function Click-Text([string]$Text) {
    $nodes = @(Find-TextNodes (Get-Layout) $Text)
    if ($nodes.Count -eq 0) { throw "Visible UI text was not found: $Text" }
    $match = [regex]::Match($nodes[0].attributes.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $match.Success) { throw "Invalid bounds for '$Text': $($nodes[0].attributes.bounds)" }
    $x = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
    $y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
    & $HdcPath shell uitest uiInput click $x $y | Out-Null
    Start-Sleep -Milliseconds 600
}

function Scroll-UntilVisibleText([string]$Text, [int]$MaxSwipes = 6) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        if (@(Find-TextNodes (Get-Layout) $Text).Count -gt 0) { return }
        if ($attempt -lt $MaxSwipes) {
            & $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Expected text did not become visible after scrolling: $Text"
}

function Scroll-UntilVisibleTextContains([string]$Text, [int]$MaxSwipes = 6) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        if (@(Find-TextNodesContaining (Get-Layout) $Text).Count -gt 0) { return }
        if ($attempt -lt $MaxSwipes) {
            & $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Expected partial text did not become visible after scrolling: $Text"
}

& $HdcPath shell aa force-stop $BundleName | Out-Null
& $HdcPath shell aa start -a $AbilityName -b $BundleName | Out-Null
Start-Sleep -Seconds 2
Assert-Page 'pages/ChatMain'
Click-Text '工具'
Assert-Page 'pages/Index'
Scroll-UntilVisibleText '配置 →'
Click-Text '配置 →'
Assert-Page 'pages/ApiEnvironment'
$environmentLayout = Get-Layout
if (@(Find-TextNodes $environmentLayout '使用离线 Fixture').Count -gt 0) {
    Click-Text '使用离线 Fixture'
}
Assert-VisibleText '当前模式：Fixture 离线演示'
Click-Text '← 返回'
Assert-Page 'pages/Index'
Scroll-UntilVisibleText '查看全部计划 →'
Click-Text '查看全部计划 →'
Assert-Page 'pages/StudyPlan'

Scroll-UntilVisibleText '开始任务'
Click-Text '开始任务'
Assert-Page 'pages/FocusSetup'
Assert-VisibleText '现在，就做这一件事'
Scroll-UntilVisibleText '开始专注'
Click-Text '开始专注'
Assert-Page 'pages/FocusTimer'
Assert-VisibleText '普通'
Scroll-UntilVisibleText '提前退出'
Click-Text '提前退出'
Assert-VisibleText '提前退出吗？'
Click-Text '保存为未完成'
Assert-Page 'pages/FocusResult'
Assert-VisibleText '未完成'
Scroll-UntilVisibleText '保存这次记录'
Click-Text '保存这次记录'
Assert-VisibleText '已保存'
Scroll-UntilVisibleText '返回聊天页'
Click-Text '返回聊天页'
Assert-Page 'pages/ChatMain'
Assert-VisibleText '查看更新计划'
Click-Text '查看更新计划'
Assert-Page 'pages/StudyPlan'
Assert-VisibleText 'Agent 学习计划'

Write-Output 'Focus UI flow passed: Agent plan -> start normal focus -> save incomplete -> result save -> authoritative-plan handoff.'
