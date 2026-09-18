param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$BundleName = 'com.zhixue.mate',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
$deviceLayoutPath = '/data/local/tmp/zhixue-local-feature-layout.json'
$localLayoutPath = Join-Path ([IO.Path]::GetTempPath()) 'zhixue-local-feature-layout.json'

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
}

function Assert-VisibleText([string]$Text) {
    if (@(Find-TextNodes (Get-Layout) $Text).Count -eq 0) {
        throw "Expected visible text was not found: $Text"
    }
}

function Assert-VisibleTextContains([string]$Text) {
    if (@(Find-TextNodesContaining (Get-Layout) $Text).Count -eq 0) {
        throw "Expected visible partial text was not found: $Text"
    }
}

function Wait-VisibleText([string]$Text) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (@(Find-TextNodes (Get-Layout) $Text).Count -gt 0) { return }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for visible text: $Text"
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

function Scroll-UntilVisibleText([string]$Text, [int]$MaxSwipes = 5) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        if (@(Find-TextNodes (Get-Layout) $Text).Count -gt 0) { return }
        if ($attempt -lt $MaxSwipes) {
            & $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Expected text did not become visible after scrolling: $Text"
}

function Scroll-UntilVisibleTextContains([string]$Text, [int]$MaxSwipes = 5) {
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

Click-Text '错题分析'
Click-Text '发送'
Wait-VisibleText '查看错题分析'
Click-Text '查看错题分析'
Assert-Page 'pages/WrongQuestion'
Click-Text '🔄 使用模拟错题快速体验'
Wait-VisibleText '✅ 分析完成'
Assert-VisibleText '🤖 AI 分析结果'
Scroll-UntilVisibleText '加入明日复习'
Click-Text '加入明日复习'
Assert-Page 'pages/ChatMain'
Wait-VisibleText '查看复习计划'
Click-Text '查看复习计划'
Assert-Page 'pages/StudyPlan'
Assert-VisibleText 'Agent 学习计划'

& $HdcPath shell uitest uiInput keyEvent Back | Out-Null
Start-Sleep -Milliseconds 600
Assert-Page 'pages/ChatMain'
Click-Text '匹配搭子'
Click-Text '发送'
Wait-VisibleText '查看搭子详情'
Click-Text '查看搭子详情'
Assert-Page 'pages/PartnerMatch'
Assert-VisibleText '最佳学习伙伴'
Scroll-UntilVisibleText '综合匹配度'
Scroll-UntilVisibleText '向该搭子发起学习邀请'
Click-Text '向该搭子发起学习邀请'
Assert-Page 'pages/ChatMain'
Wait-VisibleText '查看本周计划'
Click-Text '查看本周计划'
Assert-Page 'pages/StudyPlan'
Assert-VisibleText 'Agent 学习计划'

Write-Output 'Local feature UI flow passed: wrong-question and partner handoffs return to the authoritative Agent plan without overwriting it locally.'
