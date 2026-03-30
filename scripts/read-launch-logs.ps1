param(
    [string]$DeployRoot = "C:/KDE-Port/deploy/apps"
)

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($DeployRoot)
if (-not (Test-Path -LiteralPath $root)) {
    throw "DeployRoot does not exist: $root"
}

$logs = Get-ChildItem -Path $root -Recurse -File -Filter "*.stderr.log" -ErrorAction SilentlyContinue
if ($logs.Count -eq 0) {
    Write-Host "No stderr logs found under $root"
    exit 0
}

$nonEmpty = 0
foreach ($log in $logs | Sort-Object FullName) {
    $size = (Get-Item -LiteralPath $log.FullName).Length
    if ($size -gt 0) {
        $nonEmpty++
        Write-Host "--- $($log.FullName)"
        Get-Content -LiteralPath $log.FullName -TotalCount 40
    }
}

Write-Host ""
Write-Host "Log summary"
Write-Host "  Total stderr logs: $($logs.Count)"
Write-Host "  Non-empty logs:    $nonEmpty"
