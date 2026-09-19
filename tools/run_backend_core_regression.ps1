param(
    [string]$BackendUrl = 'http://127.0.0.1:5000',
    # 复赛要求「主链连跑 ≥10 次」以证明数值不漂移，故默认 10 次。
    # 需要快速冒烟时用 -Iterations 1。
    [int]$Iterations = 10
)

$ErrorActionPreference = 'Stop'
$contractVersion = 'api-contract-v0.3'
$headers = @{ 'X-API-Contract-Version' = $contractVersion }

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

try {
    $health = Invoke-RestMethod -Uri "$BackendUrl/health" -TimeoutSec 3
} catch {
    throw "The v0.3 backend is not reachable at $BackendUrl. Start origin/backend zhixue-agent-server first. $($_.Exception.Message)"
}
Assert-Equal $health.status 'ok' 'Backend health check failed.'

for ($run = 1; $run -le $Iterations; $run++) {
    $null = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/v1/demo/reset" -Headers $headers

    $workflowBody = @{
        goal = '诊断二叉树后序遍历'
        userId = 'demo-user'
        maxSteps = 6
        autoRun = $false
    } | ConvertTo-Json
    $workflow = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/v1/workflows" -Headers $headers `
        -ContentType 'application/json' -Body $workflowBody
    Assert-Equal $workflow.status 'running' "Run $run workflow creation failed."

    $profileV1 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/profile/demo-user" -Headers $headers
    $planV1 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/current?userId=demo-user" -Headers $headers
    $exerciseSet = Invoke-RestMethod -Uri "$BackendUrl/api/v1/exercises/set-demo-binary-tree-001" -Headers $headers
    Assert-Equal $profileV1.mastery[0].masteryScore 42 "Run $run initial mastery mismatch."
    Assert-Equal $planV1.version 1 "Run $run initial plan mismatch."
    Assert-Equal $exerciseSet.exercises.Count 3 "Run $run exercise count mismatch."
    Assert-True (-not ($exerciseSet.exercises[0].PSObject.Properties.Name -contains 'answerKey')) `
        "Run $run leaked answerKey to the client."

    $idempotencyKey = "regression-$run-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $submissionBody = @{
        userId = 'demo-user'
        sessionId = $workflow.sessionId
        idempotencyKey = $idempotencyKey
        answers = @(
            @{ exerciseId = 'exercise-preorder-001'; answer = 'A' }
            @{ exerciseId = 'exercise-inorder-001'; answer = 'B' }
            @{ exerciseId = 'exercise-postorder-001'; answer = 'B' }
        )
    } | ConvertTo-Json -Depth 4
    $submitUri = "$BackendUrl/api/v1/exercises/set-demo-binary-tree-001/submit"
    $assessment = Invoke-RestMethod -Method Post -Uri $submitUri -Headers $headers `
        -ContentType 'application/json' -Body $submissionBody
    $assessmentRetry = Invoke-RestMethod -Method Post -Uri $submitUri -Headers $headers `
        -ContentType 'application/json' -Body $submissionBody
    Assert-Equal $assessment.assessment.score 66.67 "Run $run assessment score mismatch."
    Assert-Equal $assessment.masteryUpdate.newScore 58 "Run $run updated mastery mismatch."
    Assert-Equal ($assessment | ConvertTo-Json -Depth 10 -Compress) `
        ($assessmentRetry | ConvertTo-Json -Depth 10 -Compress) "Run $run idempotency mismatch."

    $runBody = @{ submissionId = $assessment.submissionId } | ConvertTo-Json
    $workflowResult = Invoke-RestMethod -Method Post `
        -Uri "$BackendUrl/api/v1/workflows/$($workflow.sessionId)/run" -Headers $headers `
        -ContentType 'application/json' -Body $runBody
    Assert-Equal $workflowResult.status 'completed' "Run $run workflow did not consume submissionId."

    $profileV2 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/profile/demo-user" -Headers $headers
    $planV2 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/current?userId=demo-user" -Headers $headers
    $planDiff = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/$($planV2.planId)/diff" -Headers $headers
    $status = Invoke-RestMethod -Uri "$BackendUrl/api/v1/workflows/$($workflow.sessionId)" -Headers $headers
    Assert-Equal $profileV2.mastery[0].masteryScore 58 "Run $run final mastery mismatch."
    Assert-Equal $planV2.version 2 "Run $run final plan mismatch."
    Assert-Equal $planDiff.newVersion 2 "Run $run plan diff mismatch."
    Assert-Equal $status.status 'completed' "Run $run workflow status mismatch."

    $proactiveBody = @{
        userId = 'demo-user'
        context = @{ now = [DateTime]::UtcNow.ToString('o'); foreground = $false; focusSessionActive = $false }
    } | ConvertTo-Json -Depth 3
    $proactive = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/v1/agent/proactive" -Headers $headers `
        -ContentType 'application/json' -Body $proactiveBody
    Assert-True ($proactive.factors.Count -gt 0) "Run $run proactive decision has no factors."

    # 注意：Windows PowerShell 5.1 的 Invoke-RestMethod 默认按 ASCII 编码字符串 body，
    # 中文会被替换成 '?'，导致服务端收到乱码后意图识别退化。必须显式转成 UTF-8 字节。
    $chatJson = @{ message = '帮我分析错题' } | ConvertTo-Json
    $chatBody = [System.Text.Encoding]::UTF8.GetBytes($chatJson)
    $chat = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/agent/chat" `
        -ContentType 'application/json; charset=utf-8' -Body $chatBody
    Assert-Equal $chat.intent 'analyze_wrong' "Run $run chat intent mismatch."

    $snapshot = Invoke-RestMethod -Uri "$BackendUrl/api/v1/experiments/snapshot" -Headers $headers
    Assert-True ($snapshot.PSObject.Properties.Name -contains 'snapshotVersion') `
        "Run $run experiment snapshot is missing snapshotVersion."
}

Write-Output "Backend v0.3 regression: $Iterations/$Iterations runs passed (submissionId workflow handoff, idempotency, proactive, chat, snapshot)."
