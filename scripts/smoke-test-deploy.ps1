param(
    [Parameter(Mandatory = $true)]
    [string]$DeployRoot,

    [int]$StartTimeoutSeconds = 8,
    [switch]$LaunchApps,
    [switch]$VerboseQt,
    [switch]$CollectEventLog,
    [switch]$ContinueOnError
)

$ErrorActionPreference = "Stop"

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

function Get-RequiredQtCoreDlls {
    param([string]$QtFlavor)

    if ($QtFlavor -eq "Debug") {
        return @("Qt6Cored.dll", "Qt6Guid.dll", "Qt6Networkd.dll", "Qt6Widgetsd.dll")
    }
    return @("Qt6Core.dll", "Qt6Gui.dll", "Qt6Network.dll", "Qt6Widgets.dll")
}

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

$deployRootPath = Resolve-RequiredPath -PathValue $DeployRoot -Name "DeployRoot"
$dirs = Get-ChildItem -LiteralPath $deployRootPath -Directory | Sort-Object Name

if ($dirs.Count -eq 0) {
    Write-Host "No deployed app directories found in $deployRootPath"
    exit 0
}

$failed = New-Object System.Collections.Generic.List[string]
$passed = New-Object System.Collections.Generic.List[string]

foreach ($dir in $dirs) {
    $exeCandidates = Get-ChildItem -LiteralPath $dir.FullName -Filter "*.exe" -File | Sort-Object Name
    if ($exeCandidates.Count -eq 0) {
        $name = "$($dir.Name): no executable"
        if ($ContinueOnError) {
            Write-Warning $name
            $failed.Add($name) | Out-Null
            continue
        }
        throw $name
    }

    $preferredExe = Join-Path $dir.FullName ($dir.Name + ".exe")
    if (Test-Path -LiteralPath $preferredExe) {
        $exe = $preferredExe
    } else {
        $exe = $exeCandidates[0].FullName
    }
    $exeName = [System.IO.Path]::GetFileName($exe)

    if (-not $LaunchApps) {
        Write-Host "Auditing $exe"
        try {
            $runBat = Join-Path $dir.FullName ("run_" + [System.IO.Path]::GetFileNameWithoutExtension($exe) + ".bat")
            if (-not (Test-Path -LiteralPath $runBat)) {
                throw "missing launcher: $runBat"
            }

            $qtFlavor = Get-AppQtFlavor -ExecutablePath $exe
            $auditDlls = Get-RequiredQtCoreDlls -QtFlavor $qtFlavor
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($dll in $auditDlls) {
                $dllPath = Join-Path $dir.FullName $dll
                if (-not (Test-Path -LiteralPath $dllPath)) {
                    $missing.Add($dll) | Out-Null
                }
            }

            if ($missing.Count -gt 0) {
                throw ("missing core runtime DLLs: " + ($missing -join ", "))
            }

            $passed.Add($exeName) | Out-Null
            continue
        } catch {
            $msg = "${exeName}: $($_.Exception.Message)"
            Write-Warning $msg
            $failed.Add($msg) | Out-Null
            if (-not $ContinueOnError) {
                throw
            }
            continue
        }
    }

    Write-Host "Launching $exe"

    try {
        $logDir = Join-Path $dir.FullName "logs"
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $stdoutLog = Join-Path $logDir ($exeName + "." + $stamp + ".stdout.log")
        $stderrLog = Join-Path $logDir ($exeName + "." + $stamp + ".stderr.log")
        $metaLog = Join-Path $logDir ($exeName + "." + $stamp + ".meta.txt")
        $eventLog = Join-Path $logDir ($exeName + "." + $stamp + ".eventlog.txt")
        $runBat = Join-Path $dir.FullName ("run_" + [System.IO.Path]::GetFileNameWithoutExtension($exe) + ".bat")

        $oldPath = $env:PATH
        $oldQtPluginPath = $env:QT_PLUGIN_PATH
        $oldQtQpaPath = $env:QT_QPA_PLATFORM_PLUGIN_PATH
        $oldQml2ImportPath = $env:QML2_IMPORT_PATH
        $oldQtDebugPlugins = $env:QT_DEBUG_PLUGINS
        $oldQtLogRules = $env:QT_LOGGING_RULES
        $oldQtForceStderr = $env:QT_FORCE_STDERR_LOGGING
        $oldQtMessagePattern = $env:QT_MESSAGE_PATTERN

        $launchStart = Get-Date

        $env:PATH = $dir.FullName + ";" + (Join-Path $dir.FullName "bin") + ";" + (Join-Path $dir.FullName "lib") + ";" + $oldPath
        $env:QT_PLUGIN_PATH = Join-Path $dir.FullName "plugins"
        $env:QT_QPA_PLATFORM_PLUGIN_PATH = Join-Path $dir.FullName "platforms"
        $env:QML2_IMPORT_PATH = Join-Path $dir.FullName "qml"
        if ($VerboseQt) {
            $env:QT_DEBUG_PLUGINS = "1"
            $env:QT_LOGGING_RULES = "qt.qpa.*=true;qt.plugin.*=true"
            $env:QT_FORCE_STDERR_LOGGING = "1"
            $env:QT_MESSAGE_PATTERN = "[%{time hh:mm:ss.zzz}] %{type} %{category}: %{message}"
        } else {
            $env:QT_DEBUG_PLUGINS = $null
            $env:QT_LOGGING_RULES = $null
            $env:QT_FORCE_STDERR_LOGGING = $null
            $env:QT_MESSAGE_PATTERN = $null
        }

        if (Test-Path -LiteralPath $runBat) {
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $runBat) -WorkingDirectory $dir.FullName -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        } else {
            $proc = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        }
        $started = $proc.WaitForExit($StartTimeoutSeconds * 1000)
        $wasKilled = $false
        if (-not $started -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force
            $wasKilled = $true
        }

        $launchEnd = Get-Date
        $exitCode = $null
        if ($proc.HasExited) {
            $exitCode = $proc.ExitCode
        }

        @(
            "exe=$exe",
            "runBat=$runBat",
            "start=$($launchStart.ToString('o'))",
            "end=$($launchEnd.ToString('o'))",
            "elapsedSeconds=$([Math]::Round((New-TimeSpan -Start $launchStart -End $launchEnd).TotalSeconds, 3))",
            "hasExited=$($proc.HasExited)",
            "exitCode=$exitCode",
            "killedOnTimeout=$wasKilled",
            "stdout=$stdoutLog",
            "stderr=$stderrLog"
        ) | Set-Content -LiteralPath $metaLog -Encoding Ascii

        if ($CollectEventLog) {
            $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $launchStart.AddSeconds(-1) } -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Message -like "*$exeName*" -or
                    $_.Message -like "*Faulting application name*"
                } |
                Select-Object -First 20

            if ($events -and $events.Count -gt 0) {
                $events | ForEach-Object {
                    "[$($_.TimeCreated.ToString('o'))] Id=$($_.Id) Provider=$($_.ProviderName)" | Add-Content -LiteralPath $eventLog -Encoding Ascii
                    $_.Message | Add-Content -LiteralPath $eventLog -Encoding Ascii
                    "" | Add-Content -LiteralPath $eventLog -Encoding Ascii
                }
            }
        }

        $env:PATH = $oldPath
        $env:QT_PLUGIN_PATH = $oldQtPluginPath
        $env:QT_QPA_PLATFORM_PLUGIN_PATH = $oldQtQpaPath
        $env:QML2_IMPORT_PATH = $oldQml2ImportPath
        $env:QT_DEBUG_PLUGINS = $oldQtDebugPlugins
        $env:QT_LOGGING_RULES = $oldQtLogRules
        $env:QT_FORCE_STDERR_LOGGING = $oldQtForceStderr
        $env:QT_MESSAGE_PATTERN = $oldQtMessagePattern

        if ($proc.HasExited -and $exitCode -ne 0) {
            $msg = "${exeName}: exited with code $exitCode (see $metaLog)"
            Write-Warning $msg
            $failed.Add($msg) | Out-Null
            if (-not $ContinueOnError) {
                throw $msg
            }
            continue
        }

        $passed.Add($exeName) | Out-Null
    } catch {
        $env:PATH = $oldPath
        $env:QT_PLUGIN_PATH = $oldQtPluginPath
        $env:QT_QPA_PLATFORM_PLUGIN_PATH = $oldQtQpaPath
        $env:QML2_IMPORT_PATH = $oldQml2ImportPath
        $env:QT_DEBUG_PLUGINS = $oldQtDebugPlugins
        $env:QT_LOGGING_RULES = $oldQtLogRules
        $env:QT_FORCE_STDERR_LOGGING = $oldQtForceStderr
        $env:QT_MESSAGE_PATTERN = $oldQtMessagePattern
        $msg = "${exeName}: $($_.Exception.Message)"
        Write-Warning $msg
        $failed.Add($msg) | Out-Null
        if (-not $ContinueOnError) {
            throw
        }
    }
}

Write-Host ""
if ($LaunchApps) {
    Write-Host "Launch smoke test summary"
} else {
    Write-Host "Dependency audit summary"
}
Write-Host "  Passed: $($passed.Count)"
Write-Host "  Failed: $($failed.Count)"

if ($failed.Count -gt 0) {
    Write-Host "Failed tests:"
    foreach ($item in $failed) {
        Write-Host "  - $item"
    }
    exit 2
}

exit 0
