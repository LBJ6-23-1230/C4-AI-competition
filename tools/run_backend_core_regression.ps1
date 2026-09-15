param(
    [string]$BackendUrl = 'http://127.0.0.1:5000',
    [int]$Iterations = 10
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendRoot = Join-Path $projectRoot 'backend'
$headers = @{ 'X-API-Contract-Version' = 'api-contract-v0.2' }
$ownedProcess = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Wait-Backend([string]$Url) {
    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        try {
            return Invoke-RestMethod -Uri "$Url/" -TimeoutSec 1
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Backend did not become ready at $Url."
}

try {
    try {
        $root = Invoke-RestMethod -Uri "$BackendUrl/" -TimeoutSec 1
    } catch {
        $ownedProcess = Start-Process -FilePath 'python' -ArgumentList 'app.py' -WorkingDirectory $backendRoot -WindowStyle Hidden -PassThru
        $root = Wait-Backend $BackendUrl
    }
    Assert-Equal $root.contractVersion 'api-contract-v0.2' 'Backend contract version mismatch.'

    for ($run = 1; $run -le $Iterations; $run++) {
        $null = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/v1/demo/reset" -Headers $headers
        $workflow = Invoke-RestMethod -Method Post -Uri "$BackendUrl/api/v1/workflows" -Headers $headers `
            -ContentType 'application/json' -Body '{"goal":"诊断二叉树后序遍历","userId":"demo-user","maxSteps":5}'
        Assert-Equal $workflow.sessionId 'session-demo-001' "Run $run workflow session mismatch."

        $profileV1 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/profile/demo-user" -Headers $headers
        $planV1 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/current" -Headers $headers
        $exerciseSet = Invoke-RestMethod -Uri "$BackendUrl/api/v1/exercises/set-demo-binary-tree-001" -Headers $headers
        Assert-Equal $profileV1.mastery[0].masteryScore 42 "Run $run initial mastery mismatch."
        Assert-Equal $planV1.version 1 "Run $run initial plan mismatch."
        Assert-Equal $exerciseSet.exercises.Count 3 "Run $run exercise count mismatch."

        $submission = @{
            idempotencyKey = "regression-$run"
            answers = @(
                @{ exerciseId = 'exercise-preorder-001'; answer = 'A' }
                @{ exerciseId = 'exercise-inorder-001'; answer = 'B' }
                @{ exerciseId = 'exercise-postorder-001'; answer = 'B' }
            )
        } | ConvertTo-Json -Depth 4
        $assessment = Invoke-RestMethod -Method Post `
            -Uri "$BackendUrl/api/v1/exercises/set-demo-binary-tree-001/submit" `
            -Headers $headers -ContentType 'application/json' -Body $submission
        $assessmentRetry = Invoke-RestMethod -Method Post `
            -Uri "$BackendUrl/api/v1/exercises/set-demo-binary-tree-001/submit" `
            -Headers $headers -ContentType 'application/json' -Body $submission
        Assert-Equal $assessment.masteryUpdate.newScore 58 "Run $run updated mastery mismatch."
        Assert-Equal ($assessment | ConvertTo-Json -Depth 10 -Compress) `
            ($assessmentRetry | ConvertTo-Json -Depth 10 -Compress) "Run $run idempotency mismatch."

        $profileV2 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/profile/demo-user" -Headers $headers
        $planV2 = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/current" -Headers $headers
        $planDiff = Invoke-RestMethod -Uri "$BackendUrl/api/v1/plans/plan-demo-001/diff" -Headers $headers
        $trace = Invoke-RestMethod -Uri "$BackendUrl/api/v1/traces/trace-demo-001" -Headers $headers
        $status = Invoke-RestMethod -Uri "$BackendUrl/api/v1/workflows/session-demo-001" -Headers $headers
        Assert-Equal $profileV2.mastery[0].masteryScore 58 "Run $run final mastery mismatch."
        Assert-Equal $planV2.version 2 "Run $run final plan mismatch."
        Assert-Equal $planDiff.newVersion 2 "Run $run plan diff mismatch."
        Assert-Equal $trace.events.Count 5 "Run $run trace mismatch."
        Assert-Equal $status.status 'completed' "Run $run workflow status mismatch."
    }

    Write-Output "Backend core regression: $Iterations/$Iterations runs passed (42 -> 58 -> Plan V2, idempotency, diff, trace)."
} finally {
    if ($null -ne $ownedProcess -and -not $ownedProcess.HasExited) {
        Stop-Process -Id $ownedProcess.Id -Force
    }
}
