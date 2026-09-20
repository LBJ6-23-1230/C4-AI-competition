param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$BundleName = 'com.zhixue.mate',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
$deviceLayoutPath = '/data/local/tmp/zhixue-fixture-layout.json'
$localLayoutPath = Join-Path ([IO.Path]::GetTempPath()) 'zhixue-fixture-layout.json'

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
    foreach ($child in @($Node.children)) {
        Find-TextNodes $child $Text
    }
}

function Find-TextNodesContaining($Node, [string]$Text) {
    if ($null -ne $Node.attributes -and $Node.attributes.text -like "*$Text*" -and $Node.attributes.visible -eq 'true') {
        $Node
    }
    foreach ($child in @($Node.children)) {
        Find-TextNodesContaining $child $Text
    }
}

function Assert-Page([string]$ExpectedPage) {
    $layout = Get-Layout
    $actualPage = (Get-AppRoot $layout).attributes.pagePath
    if ($actualPage -ne $ExpectedPage) {
        throw "Expected page '$ExpectedPage', got '$actualPage'."
    }
    return $layout
}

function Assert-VisibleText([string]$Text) {
    $layout = Get-Layout
    $nodes = @(Find-TextNodes $layout $Text)
    if ($nodes.Count -eq 0) {
        throw "Expected visible text was not found: $Text"
    }
}

function Wait-VisibleText([string]$Text) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $layout = Get-Layout
        if (@(Find-TextNodes $layout $Text).Count -gt 0) { return }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for visible text: $Text"
}

function Click-Text([string]$Text, [int]$Occurrence = 0) {
    $layout = Get-Layout
    $nodes = @(Find-TextNodes $layout $Text)
    if ($nodes.Count -le $Occurrence) {
        throw "Visible UI text occurrence was not found: $Text #$Occurrence"
    }
    $node = $nodes[$Occurrence]
    $match = [regex]::Match($node.attributes.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $match.Success) { throw "Invalid bounds for '$Text': $($node.attributes.bounds)" }
    $x = [int](([int]$match.Groups[1].Value + [int]$match.Groups[3].Value) / 2)
    $y = [int](([int]$match.Groups[2].Value + [int]$match.Groups[4].Value) / 2)
    & $HdcPath shell uitest uiInput click $x $y | Out-Null
    Start-Sleep -Milliseconds 500
}

function Scroll-UntilVisibleText([string]$Text, [int]$MaxSwipes = 5) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        $layout = Get-Layout
        if (@(Find-TextNodes $layout $Text).Count -gt 0) { return }
        if ($attempt -lt $MaxSwipes) {
            & $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Expected text did not become visible after scrolling: $Text"
}

function Scroll-UntilVisibleTextContains([string]$Text, [int]$MaxSwipes = 5) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        $layout = Get-Layout
        if (@(Find-TextNodesContaining $layout $Text).Count -gt 0) { return }
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
$null = Assert-Page 'pages/ChatMain'

Click-Text '工具'
$null = Assert-Page 'pages/Index'
Click-Text '配置 →'
$null = Assert-Page 'pages/ApiEnvironment'

$environmentLayout = Get-Layout
if (@(Find-TextNodes $environmentLayout '使用真 Agent 后端（5000）').Count -gt 0) {
    Click-Text '使用真 Agent 后端（5000）'
}
$environmentLayout = Get-Layout
if (@(Find-TextNodes $environmentLayout '使用离线 Fixture').Count -gt 0) {
    Click-Text '使用离线 Fixture'
}
Assert-VisibleText '当前模式：Fixture 离线演示'

& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 500
$null = Assert-Page 'pages/Index'
Scroll-UntilVisibleText '返回对话'
Click-Text '返回对话'
$null = Assert-Page 'pages/ChatMain'

Click-Text '薄弱诊断'
Click-Text '发送'
Wait-VisibleText '查看薄弱诊断'
Click-Text '查看薄弱诊断'
$null = Assert-Page 'pages/StudyTags'
Assert-VisibleText '知识画像 V1'
Assert-VisibleText '42 / 100'

Click-Text '开始诊断练习'
$null = Assert-Page 'pages/ExercisePractice'
Click-Text 'A. 根-左-右'
Click-Text 'B. 左-根-右'
& $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
Start-Sleep -Milliseconds 700
Click-Text 'B. 左-根-右' 1
Click-Text '提交诊断'
Wait-VisibleText '诊断结果已生成'

Assert-VisibleText '67%'
Assert-VisibleText '42 → 58'
Assert-VisibleText 'Plan V1 → V2'
Assert-VisibleText '诊断结果已生成'

Scroll-UntilVisibleText '查看 Agent 决策过程'
Click-Text '查看 Agent 决策过程'
$null = Assert-Page 'pages/AgentTrace'
Wait-VisibleText 'Agent 的决策过程'
Assert-VisibleText '学习秘书'
Assert-VisibleText '薄弱点诊断'
Scroll-UntilVisibleText '计划调整'
Assert-VisibleText '计划调整'
Scroll-UntilVisibleTextContains '状态版本 5 ·'

& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 500
$null = Assert-Page 'pages/ExercisePractice'
Scroll-UntilVisibleText '查看更新后的知识画像'
Click-Text '查看更新后的知识画像'
$null = Assert-Page 'pages/StudyTags'
Wait-VisibleText '知识画像 V2'
Assert-VisibleText '58 / 100'
Scroll-UntilVisibleText '关联学习证据 1 条'
Scroll-UntilVisibleText '42 → 58 · 来源：学习评估'

& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 500
$null = Assert-Page 'pages/ExercisePractice'
Scroll-UntilVisibleText '查看 Agent 决策过程'
Click-Text '查看 Agent 决策过程'
$null = Assert-Page 'pages/AgentTrace'
Wait-VisibleText 'Agent 的决策过程'
Scroll-UntilVisibleText '重置演示数据'
Click-Text '重置演示数据'
Wait-VisibleText '演示已重置：再次进入知识画像时将从掌握度 42 开始。'
Scroll-UntilVisibleText '查看重置后的知识画像'
Click-Text '查看重置后的知识画像'
$null = Assert-Page 'pages/StudyTags'
Wait-VisibleText '知识画像 V1'
Assert-VisibleText '42 / 100'
Scroll-UntilVisibleText '关联学习证据 0 条'

& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 500
$null = Assert-Page 'pages/AgentTrace'
& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 700
$null = Assert-Page 'pages/ExercisePractice'
Wait-VisibleText '以下哪项是给定二叉树的前序遍历结果？'

Write-Output 'Fixture UI flow passed: Profile V1 42 -> 3 answers -> 67% -> mastery 58 -> Plan V2 -> 5-step Agent Trace -> Profile V2 evidence -> demo reset -> Profile V1 and fresh exercise.'
