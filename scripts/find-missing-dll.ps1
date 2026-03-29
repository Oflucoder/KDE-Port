param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [string]$AppFolder = (Split-Path $ExePath -Parent),

    [string[]]$ExtraSearchPaths = @(
        "C:/Qt/6.11.0/msvc2022_64/bin",
        "C:/KDE-Port/install/bin",
        "C:/KDE-Port/install/lib"
    ),

    [switch]$IncludeApiSets
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingPath {
    param([string]$PathValue, [string]$Name)
    $full = [System.IO.Path]::GetFullPath($PathValue)
    if (-not (Test-Path -LiteralPath $full)) {
        throw "$Name does not exist: $full"
    }
    return $full
}

function Get-Dependents {
    param([string]$BinaryPath)

    $output = cmd /c "dumpbin /dependents `"$BinaryPath`" 2>&1"
    $inDeps = $false
    $deps = New-Object System.Collections.Generic.List[string]
    foreach ($line in $output) {
        if ($line -match "^\s*Image has the following dependencies:\s*$") {
            $inDeps = $true
            continue
        }
        if (-not $inDeps) {
            continue
        }
        if ($line -match "^\s*Summary\s*$") {
            break
        }
        if ($line -match "^\s*([A-Za-z0-9._-]+\.dll)\s*$") {
            $deps.Add($Matches[1]) | Out-Null
        }
    }
    return $deps
}

$exePathFull = Resolve-ExistingPath -PathValue $ExePath -Name "ExePath"
$appPathFull = Resolve-ExistingPath -PathValue $AppFolder -Name "AppFolder"

$searchRoots = New-Object System.Collections.Generic.List[string]
$searchRoots.Add($appPathFull) | Out-Null
$searchRoots.Add((Join-Path $env:WINDIR "System32")) | Out-Null
foreach ($extra in $ExtraSearchPaths) {
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        $p = [System.IO.Path]::GetFullPath($extra)
        if (Test-Path -LiteralPath $p) {
            $searchRoots.Add($p) | Out-Null
        }
    }
}

$visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$missing = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Resolve-DependencyPath {
    param([string]$DllName)

    foreach ($root in $searchRoots) {
        $candidate = Join-Path $root $DllName
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Walk-Binary {
    param(
        [string]$BinaryPath,
        [string]$ImportedBy
    )

    $leaf = [System.IO.Path]::GetFileName($BinaryPath)
    if (-not $visited.Add($leaf)) {
        return
    }

    foreach ($dep in (Get-Dependents -BinaryPath $BinaryPath)) {
        if ((-not $IncludeApiSets) -and $dep.StartsWith("api-ms-win-", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $resolved = Resolve-DependencyPath -DllName $dep
        if ($null -eq $resolved) {
            if (-not $missing.ContainsKey($dep)) {
                $missing[$dep] = $leaf
            }
            continue
        }

        if ($resolved.StartsWith($appPathFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Walk-Binary -BinaryPath $resolved -ImportedBy $leaf
        }
    }
}

Write-Host "Scanning dependencies for $([System.IO.Path]::GetFileName($exePathFull))"
Walk-Binary -BinaryPath $exePathFull -ImportedBy "(root)"

if ($missing.Count -eq 0) {
    Write-Host "No missing DLLs found"
    exit 0
}

Write-Host "Missing DLLs found:"
$missing.GetEnumerator() |
    Sort-Object -Property Key |
    ForEach-Object {
        Write-Host "  - $($_.Key) (imported by: $($_.Value))"
    }
exit 2
