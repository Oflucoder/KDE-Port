param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [string]$BuildDir,
    [string]$InstallPrefix = "C:/KDE-Port/install",
    [string]$ToolchainFile = "C:/KDE-Port/toolchain/kde-windows.cmake",
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Config = "Release",
    [int]$Jobs = 0,
    [switch]$Clean,
    [switch]$NoInstall
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredPath {
    param([string]$PathValue, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "$Name cannot be empty"
    }
    $resolved = [System.IO.Path]::GetFullPath($PathValue)
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "$Name does not exist: $resolved"
    }
    return $resolved
}

$source = Resolve-RequiredPath -PathValue $SourceDir -Name "SourceDir"
$toolchain = Resolve-RequiredPath -PathValue $ToolchainFile -Name "ToolchainFile"

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $leaf = Split-Path -Leaf $source
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = "project"
    }
    $BuildDir = "C:/KDE-Port/build/$leaf"
}

$build = [System.IO.Path]::GetFullPath($BuildDir)
if ($Clean -and (Test-Path -LiteralPath $build)) {
    Write-Host "Cleaning build directory: $build"
    Remove-Item -LiteralPath $build -Recurse -Force
}
if (-not (Test-Path -LiteralPath $build)) {
    New-Item -ItemType Directory -Path $build | Out-Null
}

$configureArgs = @(
    "-S", $source,
    "-B", $build,
    "-G", "Ninja",
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix",
    "-DCMAKE_BUILD_TYPE=$Config"
)

Write-Host "Configuring: cmake $($configureArgs -join ' ')"
& cmake @configureArgs
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure failed"
}

$buildArgs = @("--build", $build, "--config", $Config)
if ($Jobs -gt 0) {
    $buildArgs += @("--parallel", "$Jobs")
}

Write-Host "Building: cmake $($buildArgs -join ' ')"
& cmake @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "Build failed"
}

if (-not $NoInstall) {
    $installArgs = @("--install", $build, "--config", $Config)
    Write-Host "Installing: cmake $($installArgs -join ' ')"
    & cmake @installArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Install failed"
    }
}

Write-Host "Build completed successfully for: $source"
