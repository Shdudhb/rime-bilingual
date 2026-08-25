[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$ProjectRoot,
    [string]$WeaselDirectory = 'C:\Program Files\Rime\weasel-0.17.4',
    [string]$PatchedWeaselServerPath,
    [switch]$DevelopmentNoProcessControl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $ProjectRoot = Split-Path -Parent $scriptDirectory
}

$manifestVersion = 1
$product = 'rime-bilingual-weasel-host'
$weaselVersion = '0.17.4'
$expectedRimeSha256 = '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B'
$expectedOfficialServerSha256 = 'FEF5AF4516092A1CA26E4E307D118583AD3FF5DF547A35FB66CB490FF99EF35B'
$expectedPatchedServerSha256 = '2FBC1F0914FA2CF2D13245874FCF64B9826B972C4B0B93EC3A53D9AAD224E77D'

function Get-NormalizedPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) { return $root }
    $fullPath.TrimEnd('\', '/')
}

function Assert-PathInside([string]$Root, [string]$Path, [string]$Label) {
    $normalizedRoot = Get-NormalizedPath $Root
    $normalizedPath = Get-NormalizedPath $Path
    $prefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if ($normalizedPath -eq $normalizedRoot -or
        -not $normalizedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must resolve strictly inside '$normalizedRoot': '$normalizedPath'."
    }
    $currentPath = $normalizedRoot
    $relativePart = $normalizedPath.Substring($prefix.Length)
    foreach ($segment in $relativePart.Split(@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        if ((Test-Path -LiteralPath $currentPath) -and
            ((Get-Item -LiteralPath $currentPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$Label traverses a symbolic link or junction at '$currentPath'."
        }
    }
    $normalizedPath
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

function Get-PEMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Not a valid PE image: '$Path'."
    }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($pe -lt 0 -or $pe + 24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) {
        throw "Not a valid PE image: '$Path'."
    }
    [BitConverter]::ToUInt16($bytes, $pe + 4)
}

function Get-SupportedWeaselProcesses([string]$ServerPath) {
    $normalized = Get-NormalizedPath $ServerPath
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name = 'WeaselServer.exe'" -ErrorAction Stop)
    }
    catch {
        throw "Cannot safely enumerate WeaselServer processes: $($_.Exception.Message)"
    }
    $matches = @()
    foreach ($row in $rows) {
        $processId = [int]$row.ProcessId
        $executablePath = [string]$row.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            throw "Cannot safely identify WeaselServer.exe PID $processId."
        }
        try { $actual = Get-NormalizedPath $executablePath }
        catch { throw "Cannot normalize executable path for WeaselServer.exe PID ${processId}: $($_.Exception.Message)" }
        if ($actual.Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{ processId = $processId; executablePath = $actual }
        }
    }
    @($matches)
}

function Stop-SupportedWeaselProcesses([string]$ServerPath) {
    $initial = @(Get-SupportedWeaselProcesses $ServerPath)
    if ($initial.Count -eq 0) { return @() }

    $workingDirectory = Split-Path -Parent $ServerPath
    Start-Process -FilePath $ServerPath -ArgumentList '/quit' -WorkingDirectory $workingDirectory | Out-Null

    $graceDeadline = (Get-Date).AddSeconds(2)
    do {
        Start-Sleep -Milliseconds 100
        if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) { break }
    } while ((Get-Date) -lt $graceDeadline)

    $forceDeadline = (Get-Date).AddSeconds(8)
    do {
        $remaining = @(Get-SupportedWeaselProcesses $ServerPath)
        if ($remaining.Count -eq 0) {
            Start-Sleep -Milliseconds 500
            if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) {
                return @($initial | ForEach-Object { [int]$_.processId })
            }
            continue
        }
        foreach ($entry in $remaining) {
            $processId = [int]$entry.processId
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            try { $actual = Get-NormalizedPath $process.Path }
            catch { throw "Cannot re-verify WeaselServer PID ${processId}: $($_.Exception.Message)" }
            if (-not $actual.Equals((Get-NormalizedPath $ServerPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing host patch: WeaselServer PID $processId changed identity before forced shutdown."
            }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $forceDeadline)

    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -gt 0) {
        throw 'A verified WeaselServer process is still running after graceful and forced shutdown.'
    }
    @($initial | ForEach-Object { [int]$_.processId })
}

function Start-SupportedWeasel([string]$ServerPath) {
    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) {
        Start-Process -FilePath $ServerPath -WorkingDirectory (Split-Path -Parent $ServerPath) | Out-Null
    }
    Start-Sleep -Milliseconds 700
    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) {
        throw "Failed to start supported WeaselServer at '$ServerPath'."
    }
}

function Invoke-WeaselDeploy([string]$DeployerPath) {
    $process = Start-Process -FilePath $DeployerPath -ArgumentList '/deploy' -WorkingDirectory (Split-Path -Parent $DeployerPath) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Weasel deploy failed with exit code $($process.ExitCode)."
    }
}

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$ProjectRoot = Get-NormalizedPath $ProjectRoot
$WeaselDirectory = Get-NormalizedPath $WeaselDirectory
if ($RimeUserDir -eq [IO.Path]::GetPathRoot($RimeUserDir)) { throw 'RimeUserDir must not be a filesystem root.' }
if ($WeaselDirectory -eq [IO.Path]::GetPathRoot($WeaselDirectory)) { throw 'WeaselDirectory must not be a filesystem root.' }

$serverPath = Assert-PathInside $WeaselDirectory (Join-Path $WeaselDirectory 'WeaselServer.exe') 'Weasel server'
$deployerPath = Assert-PathInside $WeaselDirectory (Join-Path $WeaselDirectory 'WeaselDeployer.exe') 'Weasel deployer'
$rimePath = Assert-PathInside $WeaselDirectory (Join-Path $WeaselDirectory 'rime.dll') 'Weasel rime.dll'
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-weasel-host-manifest.json') 'Host patch manifest'
$backupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-weasel-host') 'Host patch backup root'
$backupPath = Assert-PathInside $backupRoot (Join-Path $backupRoot 'official-WeaselServer.exe') 'Official WeaselServer backup'

if (-not $PatchedWeaselServerPath) {
    $PatchedWeaselServerPath = Join-Path $ProjectRoot 'weasel\build\WeaselServer.exe'
}
$PatchedWeaselServerPath = Get-NormalizedPath $PatchedWeaselServerPath

foreach ($required in @($serverPath, $deployerPath, $rimePath, $PatchedWeaselServerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file is missing: '$required'." }
}
if ((Get-Sha256 $rimePath) -cne $expectedRimeSha256) {
    throw "Unsupported rime.dll build at '$rimePath'; SHA-256 mismatch."
}
if ((Get-PEMachine $serverPath) -ne 0x8664 -or (Get-PEMachine $PatchedWeaselServerPath) -ne 0x8664) {
    throw 'Both official and patched WeaselServer images must be x64.'
}
$patchedSha256 = Get-Sha256 $PatchedWeaselServerPath
if ($patchedSha256 -ceq $expectedOfficialServerSha256) {
    throw 'Patched WeaselServer artifact is identical to the official server.'
}
if (-not $DevelopmentNoProcessControl -and $patchedSha256 -cne $expectedPatchedServerSha256) {
    throw "Unsupported patched WeaselServer artifact; expected SHA-256 $expectedPatchedServerSha256 but found $patchedSha256."
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($existing.product -ne $product -or
        $existing.manifestVersion -ne $manifestVersion -or
        [string]$existing.weaselVersion -ne $weaselVersion -or
        (Get-NormalizedPath ([string]$existing.serverPath)) -ne $serverPath -or
        [string]$existing.originalSha256 -cne $expectedOfficialServerSha256) {
        throw 'Existing Weasel host manifest is invalid or unsupported.'
    }
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or (Get-Sha256 $backupPath) -cne $expectedOfficialServerSha256) {
        throw 'Existing Weasel host backup is missing or invalid.'
    }
    $liveSha = Get-Sha256 $serverPath
    if ($liveSha -cne [string]$existing.patchedSha256) {
        throw 'Existing patched WeaselServer was modified or is missing.'
    }
    Write-Host "Rime Bilingual Weasel host patch is already installed at '$serverPath'."
    return
}

$liveOfficialSha = Get-Sha256 $serverPath
if ($liveOfficialSha -cne $expectedOfficialServerSha256) {
    throw "Refusing host patch: live WeaselServer is not the pinned official 0.17.4 build (SHA-256 $liveOfficialSha)."
}

if (-not $PSCmdlet.ShouldProcess($serverPath, 'Install Rime Bilingual Weasel 0.17.4 host refresh patch')) { return }

$backupCreated = $false
$manifestTemp = $null
$weaselWasRunning = $false
$serverMutated = $false
try {
    if (-not $DevelopmentNoProcessControl) {
        $weaselWasRunning = @(Get-SupportedWeaselProcesses $serverPath).Count -gt 0
        $null = @(Stop-SupportedWeaselProcesses $serverPath)
    }

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        if ((Get-Sha256 $backupPath) -cne $expectedOfficialServerSha256) {
            throw 'A pre-existing official WeaselServer backup has the wrong hash.'
        }
    }
    else {
        Copy-Item -LiteralPath $serverPath -Destination $backupPath -Force
        $backupCreated = $true
    }

    Copy-Item -LiteralPath $PatchedWeaselServerPath -Destination $serverPath -Force
    $serverMutated = $true
    if ((Get-Sha256 $serverPath) -cne $patchedSha256) {
        throw 'Patched WeaselServer verification failed after replacement.'
    }

    if (-not $DevelopmentNoProcessControl) {
        Invoke-WeaselDeploy $deployerPath
        Start-SupportedWeasel $serverPath
    }

    $manifest = [pscustomobject]@{
        manifestVersion = $manifestVersion
        product = $product
        weaselVersion = $weaselVersion
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        serverPath = $serverPath
        rimePath = $rimePath
        rimeSha256 = $expectedRimeSha256
        originalSha256 = $expectedOfficialServerSha256
        patchedSha256 = $patchedSha256
        backupRelativePath = '.rime-bilingual-weasel-host\official-WeaselServer.exe'
    }
    $manifestTemp = $manifestPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $RimeUserDir -Force | Out-Null
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
    Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
    Write-Host "Rime Bilingual Weasel host patch installed at '$serverPath'."
}
catch {
    $installError = $_
    $rollbackErrors = @()
    if ($serverMutated) {
        try {
            if (-not $DevelopmentNoProcessControl) { $null = @(Stop-SupportedWeaselProcesses $serverPath) }
            Copy-Item -LiteralPath $backupPath -Destination $serverPath -Force
            if ((Get-Sha256 $serverPath) -cne $expectedOfficialServerSha256) { throw 'Official server hash mismatch after rollback.' }
        }
        catch { $rollbackErrors += "server: $($_.Exception.Message)" }
    }
    if ($manifestTemp) { Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    if ($backupCreated -and $rollbackErrors.Count -eq 0) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $DevelopmentNoProcessControl -and $weaselWasRunning -and $rollbackErrors.Count -eq 0) {
        try { Start-SupportedWeasel $serverPath }
        catch { $rollbackErrors += "restart: $($_.Exception.Message)" }
    }
    if ($rollbackErrors.Count -eq 0) { throw $installError }
    throw ("Host patch install failed: {0} Rollback was incomplete. Errors: {1}" -f $installError.Exception.Message, ($rollbackErrors -join '; '))
}
