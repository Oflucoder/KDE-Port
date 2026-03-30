param(
    [Parameter(Mandatory = $true)]
    [string]$AppExe,

    [string]$Destination,
    [string]$QtRoot = "C:/Qt/6.11.0/msvc2022_64",
    [string]$KdeInstall = "C:/KDE-Port/install",
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Debug",
    [switch]$IncludeTranslations,
    [switch]$NoCompilerRuntime,
    [switch]$ForceOpenSsl,
    [switch]$NoWindeployqt,
    [switch]$AllowNonQtFallback
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

function Get-AppQtFlavor {
    param([string]$ExecutablePath)

    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if (-not $dumpbin) {
        return "Unknown"
    }

    $deps = & dumpbin /DEPENDENTS $ExecutablePath 2>$null
    $depText = ($deps | Out-String).ToLowerInvariant()
    if ($depText -match "qt6cored\.dll") {
        return "Debug"
    }
    if ($depText -match "qt6core\.dll") {
        return "Release"
    }
    return "Unknown"
}

function Test-IsDebugBinary {
    param([string]$BinaryPath)

    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if (-not $dumpbin) {
        return $false
    }

    $deps = & dumpbin /DEPENDENTS $BinaryPath 2>$null
    $depText = ($deps | Out-String).ToLowerInvariant()
    if (
        ($depText -match "qt6cored\.dll") -or
        ($depText -match "qt6guid\.dll") -or
        ($depText -match "msvcp140d\.dll") -or
        ($depText -match "vcruntime140d\.dll") -or
        ($depText -match "ucrtbased\.dll")
    ) {
        return $true
    }
    return $false
}

function Remove-DebugBinaries {
    param([string]$RootPath)

    Get-ChildItem -LiteralPath $RootPath -File -Recurse -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        # Keep non-Qt runtime dependencies even if they are debug-built; removing them can break app startup (0xC0000135).
        if ($_.Name -match '^(Qt6.*d|q.*d)\.dll$') {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

$appExePath = Resolve-RequiredPath -PathValue $AppExe -Name "AppExe"
$qtRootPath = Resolve-RequiredPath -PathValue $QtRoot -Name "QtRoot"
$kdeInstallPath = Resolve-RequiredPath -PathValue $KdeInstall -Name "KdeInstall"

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $appName = [System.IO.Path]::GetFileNameWithoutExtension($appExePath)
    $Destination = "C:/KDE-Port/deploy/$appName-$Config"
}
$destPath = [System.IO.Path]::GetFullPath($Destination)

if (Test-Path -LiteralPath $destPath) {
    Write-Host "Cleaning destination: $destPath"
    Remove-Item -LiteralPath $destPath -Recurse -Force
}
New-Item -ItemType Directory -Path $destPath | Out-Null

Copy-Item -LiteralPath $appExePath -Destination (Join-Path $destPath ([System.IO.Path]::GetFileName($appExePath))) -Force

$qtBin = Join-Path $qtRootPath "bin"
$windeployqt = Join-Path $qtBin "windeployqt.exe"
if ((-not $NoWindeployqt) -and (Test-Path -LiteralPath $windeployqt)) {
    $deployArgs = @("--dir", $destPath)
    if ($NoCompilerRuntime) {
        $deployArgs += "--no-compiler-runtime"
    }
    # Let windeployqt inspect the executable and choose debug/release dependencies.
    # This avoids mismatches when install/bin contains a mixed app set.
    if (-not $IncludeTranslations) {
        $deployArgs += "--no-translations"
    }
    if ($ForceOpenSsl) {
        $deployArgs += "--force-openssl"
    }
    $deployArgs += $appExePath

    Write-Host "Running windeployqt (auto flavor): $windeployqt $($deployArgs -join ' ')"
    $windeployOutput = & $windeployqt @deployArgs 2>&1
    $wdExit = $LASTEXITCODE
    if ($windeployOutput) {
        $windeployOutput | ForEach-Object { Write-Host $_ }
    }

    if ($wdExit -ne 0) {
        $outputText = ($windeployOutput | Out-String)
        $nonQtDetected = $outputText -match "does not seem to be a Qt executable"
        if ($AllowNonQtFallback -and $nonQtDetected) {
            Write-Warning "windeployqt reports non-Qt executable; continuing with fallback deployment for $appExePath"
            $global:LASTEXITCODE = 0
        } else {
            throw "windeployqt failed"
        }
    }
} elseif (-not $NoWindeployqt) {
    throw "windeployqt not found at: $windeployqt"
}

$appExeName = [System.IO.Path]::GetFileName($appExePath)
$appName = [System.IO.Path]::GetFileNameWithoutExtension($appExePath)

$copyBins = @(
    (Join-Path $kdeInstallPath "bin"),
    (Join-Path $kdeInstallPath "lib")
)
foreach ($dir in $copyBins) {
    if (Test-Path -LiteralPath $dir) {
        Write-Host "Copying runtime directory: $dir"
        Get-ChildItem -LiteralPath $dir -File -Filter "*.dll" | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        }
    }
}

# Stage KDE helper executables needed at runtime (not just DLLs).
$runtimeExeNames = @(
    "kioworker.exe",
    "kbuildsycoca6.exe",
    "kquitapp6.exe"
)
$kdeBinPath = Join-Path $kdeInstallPath "bin"
foreach ($exeName in $runtimeExeNames) {
    $srcExe = Join-Path $kdeBinPath $exeName
    if (Test-Path -LiteralPath $srcExe) {
        Copy-Item -LiteralPath $srcExe -Destination (Join-Path $destPath $exeName) -Force
    }
}

# Stage KDE data files (icons, services, MIME metadata, kio worker metadata, etc.).
$kdeDataSrc = Join-Path $kdeInstallPath "bin/data"
$kdeDataDst = Join-Path $destPath "data"
if (Test-Path -LiteralPath $kdeDataSrc) {
    Copy-Item -LiteralPath $kdeDataSrc -Destination $kdeDataDst -Recurse -Force
}

$needsKioShim = $false
$dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
if ($dumpbin) {
    $depScan = & dumpbin /DEPENDENTS $appExePath 2>$null
    $depText = ($depScan | Out-String)
    if ($depText -match "(?im)^\s*KF6KIO\.dll\s*$") {
        $needsKioShim = $true
    }
}

if ($needsKioShim) {
    $kioMonolithic = Join-Path $kdeInstallPath "bin/KF6KIO.dll"
    $kioCore = Join-Path $kdeInstallPath "bin/KF6KIOCore.dll"
    $kioDst = Join-Path $destPath "KF6KIO.dll"

    if (Test-Path -LiteralPath $kioMonolithic) {
        Copy-Item -LiteralPath $kioMonolithic -Destination $kioDst -Force
        Write-Host "Staged KF6KIO.dll from install/bin"
    } elseif (Test-Path -LiteralPath $kioCore) {
        Copy-Item -LiteralPath $kioCore -Destination $kioDst -Force
        Write-Warning "KF6KIO.dll not found in install/bin; using KF6KIOCore.dll compatibility shim"
    }
}

$pluginSrc = Join-Path $kdeInstallPath "lib/plugins"
if (-not (Test-Path -LiteralPath $pluginSrc)) {
    $pluginSrc = Join-Path $kdeInstallPath "plugins"
}
$pluginDst = Join-Path $destPath "plugins"
if (Test-Path -LiteralPath $pluginSrc) {
    Write-Host "Copying plugins: $pluginSrc"
    Copy-Item -LiteralPath $pluginSrc -Destination $pluginDst -Recurse -Force
}

$qmlSrc = Join-Path $kdeInstallPath "lib/qml"
if (-not (Test-Path -LiteralPath $qmlSrc)) {
    $qmlSrc = Join-Path $kdeInstallPath "qml"
}
$qmlDst = Join-Path $destPath "qml"
if (Test-Path -LiteralPath $qmlSrc) {
    Write-Host "Copying qml modules: $qmlSrc"
    Copy-Item -LiteralPath $qmlSrc -Destination $qmlDst -Recurse -Force
}

# qmltooling plugins are developer diagnostics and can trigger extra plugin probing at runtime.
$qmlToolingPath = Join-Path $destPath "qmltooling"
if (Test-Path -LiteralPath $qmlToolingPath) {
    Remove-Item -LiteralPath $qmlToolingPath -Recurse -Force -ErrorAction SilentlyContinue
}

$appFlavor = Get-AppQtFlavor -ExecutablePath $appExePath
if ($Config -eq "Release") {
    # User requested release-only payloads; force release runtime staging.
    $appFlavor = "Release"
}
Write-Host "Detected app Qt flavor: $appFlavor"

if ($appFlavor -eq "Release") {
    # Remove debug Qt artifacts from release app payloads to prevent mixed-runtime probing and load failures.
    Get-ChildItem -LiteralPath $destPath -Recurse -File -Filter "Qt6*d.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $destPath -Recurse -File -Filter "q*d.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

$qtExtraRelease = @(
    "Qt6QuickControls2.dll",
    "Qt6QuickTemplates2.dll",
    "Qt6QuickLayouts.dll",
    "Qt6QuickDialogs2.dll",
    "Qt6QuickDialogs2QuickImpl.dll",
    "Qt6QuickDialogs2Utils.dll"
)
$qtExtraDebug = @(
    "Qt6QuickControls2d.dll",
    "Qt6QuickTemplates2d.dll",
    "Qt6QuickLayoutsd.dll",
    "Qt6QuickDialogs2d.dll",
    "Qt6QuickDialogs2QuickImpld.dll",
    "Qt6QuickDialogs2Utilsd.dll"
)

$qtExtras = @()
if ($appFlavor -eq "Debug") {
    $qtExtras = $qtExtraDebug
} else {
    $qtExtras = $qtExtraRelease
}

foreach ($dllName in $qtExtras) {
    $srcDll = Join-Path $qtBin $dllName
    if (Test-Path -LiteralPath $srcDll) {
        Copy-Item -LiteralPath $srcDll -Destination (Join-Path $destPath $dllName) -Force
    }
}

# Brute-force stage Qt runtime DLLs by flavor for stability in mixed KDE/QML deployments.
Get-ChildItem -LiteralPath $qtBin -File -Filter "Qt6*.dll" | ForEach-Object {
    $name = $_.Name
    if ($appFlavor -eq "Debug") {
        if ($name -notmatch "d\.dll$") {
            return
        }
    } else {
        if ($name -match "d\.dll$") {
            return
        }
    }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destPath $name) -Force
}

$vcRedistPath = Join-Path $destPath "vc_redist.x64.exe"
if (Test-Path -LiteralPath $vcRedistPath) {
    Remove-Item -LiteralPath $vcRedistPath -Force -ErrorAction SilentlyContinue
}

# Stage Windows platform plugin matching selected runtime flavor.
$qtPlatformsSrc = Join-Path $qtRootPath "plugins/platforms"
$appPlatformsDst = Join-Path $destPath "platforms"
if (Test-Path -LiteralPath $qtPlatformsSrc) {
    New-Item -ItemType Directory -Path $appPlatformsDst -Force | Out-Null
    $platformDlls = @("qwindows.dll")
    if ($appFlavor -eq "Debug") {
        $platformDlls += "qwindowsd.dll"
    }
    foreach ($platformDll in $platformDlls) {
        $srcPlatformDll = Join-Path $qtPlatformsSrc $platformDll
        if (Test-Path -LiteralPath $srcPlatformDll) {
            Copy-Item -LiteralPath $srcPlatformDll -Destination (Join-Path $appPlatformsDst $platformDll) -Force
            Write-Host "Staged platform plugin: $platformDll"
        }
    }
}

# Some debug-only UserFeedback DLLs are not installed in install/bin; backfill from build tree only for debug apps.
if (($Config -eq "Debug") -and ($appFlavor -eq "Debug")) {
    $kdeRoot = Split-Path -Parent $kdeInstallPath
    $userFeedbackBuildBin = Join-Path $kdeRoot "build/kuserfeedback/bin"
    if (Test-Path -LiteralPath $userFeedbackBuildBin) {
        foreach ($dllName in @("KF6UserFeedbackCored.dll", "KF6UserFeedbackWidgetsd.dll")) {
            $srcDll = Join-Path $userFeedbackBuildBin $dllName
            if (Test-Path -LiteralPath $srcDll) {
                Copy-Item -LiteralPath $srcDll -Destination (Join-Path $destPath $dllName) -Force
            }
        }
    }
}

if ($Config -eq "Release") {
    # Final safety pass: strip only true debug binaries in release deployments.
    Remove-DebugBinaries -RootPath $destPath
}

# Ensure UserFeedback QML plugin module exists even if generic qml copy was partial/interrupted.
$userFeedbackQmlSrc = Join-Path $kdeInstallPath "lib/qml/org/kde/userfeedback"
$userFeedbackQmlDst = Join-Path $destPath "qml/org/kde/userfeedback"
if (Test-Path -LiteralPath $userFeedbackQmlSrc) {
    New-Item -ItemType Directory -Path $userFeedbackQmlDst -Force | Out-Null
    Copy-Item -Path (Join-Path $userFeedbackQmlSrc "*") -Destination $userFeedbackQmlDst -Recurse -Force
}

if ($Config -eq "Release") {
    # Final final pass after QML copy: strip only true debug binaries.
    Remove-DebugBinaries -RootPath $destPath
}

$launcherPath = Join-Path $destPath ("run_" + $appName + ".bat")
$launcherStart = '"%APPDIR%' + $appExeName + '" %*'
$launcherContent = @(
    "@echo off",
    "setlocal enabledelayedexpansion",
    'set "APPDIR=%~dp0"',
    'set "PATH=%APPDIR%;%APPDIR%bin;%APPDIR%lib;%PATH%"',
    'set "XDG_DATA_DIRS=%APPDIR%data;%XDG_DATA_DIRS%"',
    'set "XDG_CONFIG_DIRS=%APPDIR%data\config;%XDG_CONFIG_DIRS%"',
    'set "XDG_CONFIG_HOME=%APPDIR%config"',
    'set "XDG_CACHE_HOME=%APPDIR%cache"',
    'set "KDEDIRS=%APPDIR%"',
    'set "QT_PLUGIN_PATH=%APPDIR%;%APPDIR%plugins;%APPDIR%plugins\kf6\kio"',
    'set "KF_PLUGIN_PATH=%APPDIR%plugins;%APPDIR%plugins\kf6\kio"',
    'set "QT_QPA_PLATFORM_PLUGIN_PATH=%APPDIR%platforms"',
    'set "QML2_IMPORT_PATH=%APPDIR%qml"',
    'if not exist "%XDG_CONFIG_HOME%" mkdir "%XDG_CONFIG_HOME%"',
    'if not exist "%XDG_CACHE_HOME%" mkdir "%XDG_CACHE_HOME%"',
    'if exist "%APPDIR%kbuildsycoca6.exe" (',
    '  echo Regenerating KDE service cache...',
    '  "%APPDIR%kbuildsycoca6.exe" --noincremental',
    ')',
    $launcherStart
)
Set-Content -LiteralPath $launcherPath -Value $launcherContent -Encoding Ascii
Write-Host "Created launcher: $launcherPath"

$qtConfPath = Join-Path $destPath "qt.conf"
$qtConfContent = @(
    "[Paths]",
    "Prefix=.",
    "Plugins=plugins",
    "Qml2Imports=qml",
    "Imports=qml"
)
Set-Content -LiteralPath $qtConfPath -Value $qtConfContent -Encoding Ascii
Write-Host "Created qt.conf: $qtConfPath"

Write-Host "Deployment complete: $destPath"
$global:LASTEXITCODE = 0
