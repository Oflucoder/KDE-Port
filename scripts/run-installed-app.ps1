param(
    [Parameter(Mandatory = $true)]
    [string]$AppName,
    [string]$InstallRoot = "C:/KDE-Port/install",
    [string]$QtRoot = "C:/Qt/6.11.0/msvc2022_64"
)

$ErrorActionPreference = "Stop"

$installRootPath = [System.IO.Path]::GetFullPath($InstallRoot)
$qtRootPath = [System.IO.Path]::GetFullPath($QtRoot)
$appExe = Join-Path $installRootPath ("bin/" + $AppName)
if (-not ($appExe.ToLower().EndsWith('.exe'))) {
    $appExe += '.exe'
}

if (-not (Test-Path -LiteralPath $appExe)) {
    throw "Executable not found: $appExe"
}

$env:PATH = (Join-Path $installRootPath "bin") + ";" + (Join-Path $installRootPath "lib") + ";" + (Join-Path $qtRootPath "bin") + ";" + $env:PATH
$env:QT_PLUGIN_PATH = (Join-Path $installRootPath "lib/plugins")
$env:QML2_IMPORT_PATH = (Join-Path $installRootPath "lib/qml")

Write-Host "Launching with KDE/Qt runtime path configured: $appExe"
Start-Process -FilePath $appExe
