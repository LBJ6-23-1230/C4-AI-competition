param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$repositoryRootFull = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')

function Assert-InRepository([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repositoryRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to process a path outside the repository: $fullPath"
    }
    return $fullPath
}

$targets = [System.Collections.Generic.List[string]]::new()

foreach ($relativePath in @(
    '.pytest-tmp',
    'integration\__pycache__',
    'server\zhixue-agent-server\__pycache__',
    'server\zhixue-agent-server\tests\.pytest-tmp',
    'server\zhixue-agent-server\tests\__pycache__'
)) {
    $candidate = Join-Path $repositoryRoot $relativePath
    if (Test-Path -LiteralPath $candidate) {
        $targets.Add((Assert-InRepository $candidate))
    }
}

$serverRoot = Join-Path $repositoryRoot 'server\zhixue-agent-server'
$virtualEnvironmentRoot = [IO.Path]::GetFullPath((Join-Path $serverRoot '.venv')).TrimEnd('\')
Get-ChildItem -LiteralPath $serverRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object {
        -not $_.FullName.StartsWith($virtualEnvironmentRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        ($_.Name -eq '__pycache__' -or
         $_.Name -eq '.pytest_cache' -or
         $_.Name -like 'pytest-cache-files-*')
    } |
    ForEach-Object {
        $fullPath = Assert-InRepository $_.FullName
        if (-not $targets.Contains($fullPath)) {
            $targets.Add($fullPath)
        }
    }

if ($targets.Count -eq 0) {
    Write-Host 'Workspace is clean: no test temporary directories or Python caches found.'
    exit 0
}

Write-Host "Found $($targets.Count) regenerable directories:"
foreach ($target in $targets | Sort-Object) {
    Write-Host "  $target"
}

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Preview only; nothing was deleted. To clean these paths, run:'
    Write-Host '  powershell -ExecutionPolicy Bypass -File tools/clean_workspace.ps1 -Apply'
    exit 0
}

$removed = 0
$failed = 0
foreach ($target in $targets | Sort-Object { $_.Length } -Descending) {
    try {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        Write-Host "Removed: $target"
        $removed++
    }
    catch {
        Write-Warning "Could not remove $target : $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ''
Write-Host "Done: removed $removed directories; $failed failed."
if ($failed -gt 0) {
    exit 1
}
