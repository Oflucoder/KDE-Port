param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$AppExe,

    [string]$BuildDir,
    [string]$Destination,
    [string]$InstallPrefix = "C:/KDE-Port/install",
    [string]$ToolchainFile = "C:/KDE-Port/toolchain/kde-windows.cmake",
    [string]$QtRoot = "C:/Qt/6.11.0/msvc2022_64",
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Config = "Release",
    [int]$Jobs = 0,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildScript = Join-Path $scriptRoot "kde-build.ps1"
$deployScript = Join-Path $scriptRoot "kde-deploy.ps1"

$buildArgs = @{
    SourceDir = $SourceDir
    InstallPrefix = $InstallPrefix
    ToolchainFile = $ToolchainFile
    Config = $Config
}
if (-not [string]::IsNullOrWhiteSpace($BuildDir)) { $buildArgs.BuildDir = $BuildDir }
if ($Jobs -gt 0) { $buildArgs.Jobs = $Jobs }
if ($Clean) { $buildArgs.Clean = $true }

& $buildScript @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "Build stage failed"
}

$deployArgs = @{
    AppExe = $AppExe
    QtRoot = $QtRoot
    KdeInstall = $InstallPrefix
}
if (-not [string]::IsNullOrWhiteSpace($Destination)) { $deployArgs.Destination = $Destination }
if ($Config -eq "Release") {
    $deployArgs.Config = "Release"
} else {
    $deployArgs.Config = "Debug"
}

& $deployScript @deployArgs
if ($LASTEXITCODE -ne 0) {
    throw "Deploy stage failed"
}

Write-Host "Build + deploy completed successfully"
