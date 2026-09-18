param(
    [string]$HdcPath = 'D:\develop\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
    [string]$BundleName = 'com.zhixue.mate',
    [string]$AbilityName = 'EntryAbility'
)

$ErrorActionPreference = 'Stop'
$deviceLayoutPath = '/data/local/tmp/zhixue-navigation-layout.json'
$localLayoutPath = Join-Path ([IO.Path]::GetTempPath()) 'zhixue-navigation-layout.json'

function Get-Layout {
    & $HdcPath shell uitest dumpLayout -p $deviceLayoutPath -b $BundleName | Out-Null
    & $HdcPath file recv $deviceLayoutPath $localLayoutPath | Out-Null
    return Get-Content -LiteralPath $localLayoutPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-AppRoot($Layout) {
    foreach ($candidate in @($Layout.children)) {
        if ($candidate.attributes.bundleName -eq $BundleName) {
            return $candidate
        }
    }
    throw "No visible UI root found for $BundleName."
}

function Find-TextNode($Node, [string]$Text) {
    if ($null -ne $Node.attributes -and $Node.attributes.text -eq $Text -and $Node.attributes.visible -eq 'true') {
        return $Node
    }
    foreach ($child in @($Node.children)) {
        $found = Find-TextNode $child $Text
        if ($null -ne $found) {
            return $found
        }
    }
    return $null
}

function Assert-Page([string]$ExpectedPage) {
    $layout = Get-Layout
    $actualPage = (Get-AppRoot $layout).attributes.pagePath
    if ($actualPage -ne $ExpectedPage) {
        throw "Expected page '$ExpectedPage', got '$actualPage'."
    }
    return $layout
}

function Click-Text([string]$Text) {
    $layout = Get-Layout
    $node = Find-TextNode $layout $Text
    if ($null -eq $node) {
        throw "Visible UI text was not found: $Text"
    }
    $match = [regex]::Match($node.attributes.bounds, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $match.Success) {
        throw "Invalid bounds for '$Text': $($node.attributes.bounds)"
    }
    $left = [int]$match.Groups[1].Value
    $top = [int]$match.Groups[2].Value
    $right = [int]$match.Groups[3].Value
    $bottom = [int]$match.Groups[4].Value
    $x = [int](($left + $right) / 2)
    $y = [int](($top + $bottom) / 2)
    & $HdcPath shell uitest uiInput click $x $y | Out-Null
    Start-Sleep -Milliseconds 700
}

function Scroll-UntilVisibleText([string]$Text, [int]$MaxSwipes = 5) {
    for ($attempt = 0; $attempt -le $MaxSwipes; $attempt++) {
        $layout = Get-Layout
        if ($null -ne (Find-TextNode $layout $Text)) {
            return
        }
        if ($attempt -lt $MaxSwipes) {
            & $HdcPath shell uitest uiInput swipe 1105 1900 1105 600 800 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Expected visible text did not become available: $Text"
}

function Scroll-ToTop([int]$MaxSwipes = 6) {
    for ($attempt = 0; $attempt -lt $MaxSwipes; $attempt++) {
        & $HdcPath shell uitest uiInput swipe 1105 650 1105 1900 500 | Out-Null
        Start-Sleep -Milliseconds 350
    }
}

function Back-ToIndex {
    & $HdcPath shell uitest uiInput keyEvent Back | Out-Null
    Start-Sleep -Milliseconds 700
    $null = Assert-Page 'pages/Index'
}

& $HdcPath shell aa force-stop $BundleName | Out-Null
& $HdcPath shell aa start -a $AbilityName -b $BundleName | Out-Null
Start-Sleep -Seconds 2
$null = Assert-Page 'pages/ChatMain'

Click-Text '工具'
$null = Assert-Page 'pages/Index'

Scroll-UntilVisibleText '查看全部计划 →'
Click-Text '查看全部计划 →'
$null = Assert-Page 'pages/StudyPlan'
Back-ToIndex

Scroll-UntilVisibleText '开始诊断练习'
Click-Text '开始诊断练习'
$null = Assert-Page 'pages/ExercisePractice'
Back-ToIndex

Scroll-UntilVisibleText '查看 Agent 决策过程'
Click-Text '查看 Agent 决策过程'
$null = Assert-Page 'pages/AgentTrace'
Back-ToIndex

Click-Text '课程与作业'
$null = Assert-Page 'pages/CourseImport'
Back-ToIndex

Click-Text '错题复习'
$null = Assert-Page 'pages/WrongQuestion'
Back-ToIndex

Click-Text '我的'
$null = Assert-Page 'pages/LearningHistory'
Back-ToIndex

Scroll-ToTop
Scroll-UntilVisibleText '配置 →'
Click-Text '配置 →'
$null = Assert-Page 'pages/ApiEnvironment'
Back-ToIndex

Scroll-UntilVisibleText '返回对话'
Click-Text '返回对话'
$null = Assert-Page 'pages/ChatMain'

Write-Output 'UI navigation smoke passed: ChatMain -> Index -> StudyPlan/ExercisePractice/AgentTrace/CourseImport/WrongQuestion/LearningHistory/ApiEnvironment -> ChatMain.'
