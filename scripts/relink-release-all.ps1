param(
    [string]$BuildRoot = "C:/KDE-Port/build",
    [string]$InstallPrefix = "C:/KDE-Port/install",
    [string]$ToolchainFile = "C:/KDE-Port/toolchain/kde-windows.cmake",
    [string]$QtRoot = "C:/Qt/6.11.0/msvc2022_64",
    [string[]]$Modules,
    [int]$Jobs = 0,
    [switch]$ContinueOnError
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

function Get-SourceDirFromCache {
    param([string]$BuildDir)
    $cache = Join-Path $BuildDir "CMakeCache.txt"
    if (-not (Test-Path -LiteralPath $cache)) {
        return $null
    }
    $line = Select-String -Path $cache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=' | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return ($line.Line -replace '^CMAKE_HOME_DIRECTORY:INTERNAL=', '')
}

$buildRootPath = Resolve-RequiredPath -PathValue $BuildRoot -Name "BuildRoot"
$installPrefixPath = Resolve-RequiredPath -PathValue $InstallPrefix -Name "InstallPrefix"
$toolchainFilePath = Resolve-RequiredPath -PathValue $ToolchainFile -Name "ToolchainFile"
$qtRootPath = Resolve-RequiredPath -PathValue $QtRoot -Name "QtRoot"

if (-not $Modules -or $Modules.Count -eq 0) {
    $Modules = Get-ChildItem -LiteralPath $buildRootPath -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'CMakeCache.txt') } |
        Select-Object -ExpandProperty Name |
        Sort-Object
}

$failed = New-Object System.Collections.Generic.List[string]
$done = New-Object System.Collections.Generic.List[string]

foreach ($module in $Modules) {
    $buildDir = Join-Path $buildRootPath $module
    if (-not (Test-Path -LiteralPath (Join-Path $buildDir 'CMakeCache.txt'))) {
        Write-Warning "Skipping ${module}: missing CMakeCache.txt"
        continue
    }

    $sourceDir = Get-SourceDirFromCache -BuildDir $buildDir
    if ([string]::IsNullOrWhiteSpace($sourceDir) -or -not (Test-Path -LiteralPath $sourceDir)) {
        Write-Warning "Skipping ${module}: cannot resolve source directory"
        continue
    }

    Write-Host "[Release Relink] $module"

    try {
        $configureArgs = @(
            '-S', $sourceDir,
            '-B', $buildDir,
            '-G', 'Ninja',
            "-DCMAKE_TOOLCHAIN_FILE=$toolchainFilePath",
            "-DCMAKE_INSTALL_PREFIX=$installPrefixPath",
            "-DCMAKE_PREFIX_PATH=$qtRootPath;$installPrefixPath",
            '-DCMAKE_BUILD_TYPE=Release',
            '-DBUILD_TESTING=OFF',
            '-DBUILD_TESTS=OFF',
            '-DBUILD_DOC=OFF'
        )

        & cmake @configureArgs
        if ($LASTEXITCODE -ne 0) {
            throw "configure failed"
        }

        $buildArgs = @('--build', $buildDir, '--config', 'Release', '--target', 'install')
        if ($Jobs -gt 0) {
            $buildArgs += @('--parallel', "$Jobs")
        }

        & cmake @buildArgs
        if ($LASTEXITCODE -ne 0) {
            throw "build/install failed"
        }

        $done.Add($module) | Out-Null
    } catch {
        Write-Warning "Module failed: $module ($($_.Exception.Message))"
        $failed.Add($module) | Out-Null
        if (-not $ContinueOnError) {
            throw
        }
    }
}

Write-Host ""
Write-Host "Release relink summary"
Write-Host "  Succeeded: $($done.Count)"
Write-Host "  Failed:    $($failed.Count)"
if ($failed.Count -gt 0) {
    Write-Host "Failed modules:"
    foreach ($m in $failed) {
        Write-Host "  - $m"
    }
    exit 2
}
exit 0
