[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$WeaselDirectory = 'C:\Program Files\Rime\weasel-0.17.4',
    [string]$DeployerPath,
    [ValidateSet('installed', 'uninstalled')]
    [string]$ExpectedBilingualState = 'installed'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $DeployerPath) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $DeployerPath = Join-Path $projectRoot 'deployer\target\release\RimeBilingualDeploy.exe'
}

$expectedRimeSha256 = '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B'
$officialWeaselSha256 = 'FEF5AF4516092A1CA26E4E307D118583AD3FF5DF547A35FB66CB490FF99EF35B'
$patchedWeaselSha256 = '2FBC1F0914FA2CF2D13245874FCF64B9826B972C4B0B93EC3A53D9AAD224E77D'

function Get-NormalizedPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Get-Sha256([string]$Path) {
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        ([BitConverter]::ToString($bytes)).Replace('-', '')
    }
    finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Assert-PathInside([string]$Root, [string]$Path, [string]$Label) {
    $normalizedRoot = Get-NormalizedPath $Root
    $normalizedPath = Get-NormalizedPath $Path
    $prefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if ($normalizedPath -eq $normalizedRoot -or
        -not $normalizedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must resolve strictly inside '$normalizedRoot': '$normalizedPath'."
    }
    $normalizedPath
}

function Get-ExactWeaselProcesses([string]$ServerPath) {
    $serverPath = Get-NormalizedPath $ServerPath
    $matches = @()
    foreach ($row in @(Get-CimInstance Win32_Process -Filter "Name = 'WeaselServer.exe'" -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace([string]$row.ExecutablePath)) {
            throw "Cannot safely identify WeaselServer.exe PID $([int]$row.ProcessId)."
        }
        $actual = Get-NormalizedPath ([string]$row.ExecutablePath)
        if ($actual.Equals($serverPath, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{
                ProcessId = [int]$row.ProcessId
                ExecutablePath = $actual
            }
        }
    }
    @($matches)
}

function Stop-ExactWeasel([string]$ServerPath) {
    $initial = @(Get-ExactWeaselProcesses $ServerPath)
    if ($initial.Count -eq 0) { return $false }

    # Follow Weasel's documented shutdown path first, but do not wait for the
    # /quit process itself because 0.17.4 can turn it into a replacement server.
    Start-Process -FilePath $ServerPath -ArgumentList '/quit' -WorkingDirectory (Split-Path -Parent $ServerPath) | Out-Null
    $graceDeadline = (Get-Date).AddSeconds(2)
    do {
        Start-Sleep -Milliseconds 100
        if (@(Get-ExactWeaselProcesses $ServerPath).Count -eq 0) { break }
    } while ((Get-Date) -lt $graceDeadline)

    $forceDeadline = (Get-Date).AddSeconds(8)
    do {
        $remaining = @(Get-ExactWeaselProcesses $ServerPath)
        if ($remaining.Count -eq 0) {
            Start-Sleep -Milliseconds 500
            if (@(Get-ExactWeaselProcesses $ServerPath).Count -eq 0) { return $true }
            continue
        }
        foreach ($entry in $remaining) {
            $process = Get-Process -Id ([int]$entry.ProcessId) -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            $actual = Get-NormalizedPath $process.Path
            if (-not $actual.Equals((Get-NormalizedPath $ServerPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to stop PID $($entry.ProcessId): executable identity changed."
            }
            Stop-Process -Id ([int]$entry.ProcessId) -Force -ErrorAction Stop
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $forceDeadline)

    throw 'Unable to stop the exact supported WeaselServer process set.'
}

function Start-ExactWeasel([string]$ServerPath) {
    Start-Process -FilePath $ServerPath -WorkingDirectory (Split-Path -Parent $ServerPath) | Out-Null
    Start-Sleep -Milliseconds 700
    if (@(Get-ExactWeaselProcesses $ServerPath).Count -eq 0) {
        throw "WeaselServer did not restart from '$ServerPath'."
    }
}

function Test-CompiledState([string]$SchemaPath, [string]$State) {
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { return $false }
    $text = Get-Content -LiteralPath $SchemaPath -Raw
    $hasFilter = $text -match 'lua_filter@\*rime_bilingual'
    $hasProcessor = $text -match 'lua_processor@\*rime_bilingual_async'
    $hasConfig = $text -match '(?m)^rime_bilingual:'
    if ($State -eq 'installed') { return $hasFilter -and $hasProcessor -and $hasConfig }
    return -not $hasFilter -and -not $hasProcessor -and -not $hasConfig
}

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$WeaselDirectory = Get-NormalizedPath $WeaselDirectory
$DeployerPath = Get-NormalizedPath $DeployerPath
$serverPath = Get-NormalizedPath (Join-Path $WeaselDirectory 'WeaselServer.exe')
$rimePath = Get-NormalizedPath (Join-Path $WeaselDirectory 'rime.dll')
$sharedDataDir = Get-NormalizedPath (Join-Path $WeaselDirectory 'data')
$schemaSource = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'rime_ice.schema.yaml') 'Rime Ice schema source'
$buildPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'build') 'Rime build directory'
$compiledSchema = Assert-PathInside $RimeUserDir (Join-Path $buildPath 'rime_ice.schema.yaml') 'Compiled Rime Ice schema'

foreach ($required in @($serverPath, $rimePath, $schemaSource, $DeployerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file is missing: '$required'." }
}
if (-not (Test-Path -LiteralPath $sharedDataDir -PathType Container)) { throw "Weasel shared data is missing: '$sharedDataDir'." }

if ((Get-Sha256 $rimePath) -cne $expectedRimeSha256) { throw 'Unsupported rime.dll SHA-256.' }
$serverHash = Get-Sha256 $serverPath
if ($serverHash -cne $officialWeaselSha256 -and $serverHash -cne $patchedWeaselSha256) {
    throw "Unsupported WeaselServer.exe SHA-256: $serverHash"
}

$operation = "Headless deploy rime_ice.schema.yaml and verify bilingual state '$ExpectedBilingualState'"
if (-not $PSCmdlet.ShouldProcess($RimeUserDir, $operation)) { return }

$rollbackRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ('.rime-bilingual-deploy-rollback-' + [guid]::NewGuid().ToString('N'))) 'Deploy rollback root'
$buildExisted = Test-Path -LiteralPath $buildPath -PathType Container
$weaselWasRunning = $false
$committed = $false

try {
    $weaselWasRunning = Stop-ExactWeasel $serverPath
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    if ($buildExisted) {
        Copy-Item -LiteralPath $buildPath -Destination (Join-Path $rollbackRoot 'build') -Recurse -Force
    }

    & $DeployerPath --rime-dll $rimePath --shared-data-dir $sharedDataDir --user-data-dir $RimeUserDir
    if ($LASTEXITCODE -ne 0) { throw "Headless deployer failed with exit code $LASTEXITCODE." }
    if (-not (Test-CompiledState $compiledSchema $ExpectedBilingualState)) {
        throw "Compiled schema does not match expected bilingual state '$ExpectedBilingualState'."
    }

    if ($weaselWasRunning) { Start-ExactWeasel $serverPath }
    $committed = $true
}
catch {
    $deploymentError = $_
    $rollbackErrors = @()
    try {
        if (Test-Path -LiteralPath $buildPath) { Remove-Item -LiteralPath $buildPath -Recurse -Force }
        if ($buildExisted) {
            Copy-Item -LiteralPath (Join-Path $rollbackRoot 'build') -Destination $buildPath -Recurse -Force
        }
    }
    catch { $rollbackErrors += "build restore: $($_.Exception.Message)" }
    if ($weaselWasRunning -and @(Get-ExactWeaselProcesses $serverPath).Count -eq 0) {
        try { Start-ExactWeasel $serverPath }
        catch { $rollbackErrors += "Weasel restart: $($_.Exception.Message)" }
    }
    if ($rollbackErrors.Count -eq 0) {
        Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw $deploymentError
    }
    throw ("Headless deploy failed: {0} Rollback was incomplete at '{1}': {2}" -f $deploymentError.Exception.Message, $rollbackRoot, ($rollbackErrors -join '; '))
}

if ($committed) {
    Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Headless Rime deploy succeeded; bilingual state is '$ExpectedBilingualState'."
}
