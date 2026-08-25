[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [switch]$DevelopmentNoProcessControl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$expectedProduct = 'rime-bilingual-weasel-host'
$expectedManifestVersion = 1
$expectedWeaselVersion = '0.17.4'
$expectedOfficialServerSha256 = 'FEF5AF4516092A1CA26E4E307D118583AD3FF5DF547A35FB66CB490FF99EF35B'
$expectedRimeSha256 = '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B'

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
    if ($normalizedPath -eq $normalizedRoot -or -not $normalizedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must resolve strictly inside '$normalizedRoot': '$normalizedPath'."
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

function Get-SupportedWeaselProcesses([string]$ServerPath) {
    $normalized = Get-NormalizedPath $ServerPath
    $rows = @(Get-CimInstance Win32_Process -Filter "Name = 'WeaselServer.exe'" -ErrorAction Stop)
    $matches = @()
    foreach ($row in $rows) {
        $processId = [int]$row.ProcessId
        $executablePath = [string]$row.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executablePath)) { throw "Cannot safely identify WeaselServer.exe PID $processId." }
        $actual = Get-NormalizedPath $executablePath
        if ($actual.Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{ processId = $processId; executablePath = $actual }
        }
    }
    @($matches)
}

function Stop-SupportedWeaselProcesses([string]$ServerPath) {
    $initial = @(Get-SupportedWeaselProcesses $ServerPath)
    if ($initial.Count -eq 0) { return @() }
    Start-Process -FilePath $ServerPath -ArgumentList '/quit' -WorkingDirectory (Split-Path -Parent $ServerPath) | Out-Null
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
            if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) { return @($initial | ForEach-Object { [int]$_.processId }) }
            continue
        }
        foreach ($entry in $remaining) {
            $processId = [int]$entry.processId
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            $actual = Get-NormalizedPath $process.Path
            if (-not $actual.Equals((Get-NormalizedPath $ServerPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing host unpatch: WeaselServer PID $processId changed identity before forced shutdown."
            }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $forceDeadline)
    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -gt 0) { throw 'A verified WeaselServer process is still running.' }
    @($initial | ForEach-Object { [int]$_.processId })
}

function Start-SupportedWeasel([string]$ServerPath) {
    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) {
        Start-Process -FilePath $ServerPath -WorkingDirectory (Split-Path -Parent $ServerPath) | Out-Null
    }
    Start-Sleep -Milliseconds 700
    if (@(Get-SupportedWeaselProcesses $ServerPath).Count -eq 0) { throw "Failed to start WeaselServer at '$ServerPath'." }
}

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-weasel-host-manifest.json') 'Host patch manifest'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "Rime Bilingual Weasel host patch is not installed in '$RimeUserDir'."
    return
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.product -ne $expectedProduct -or
    $manifest.manifestVersion -ne $expectedManifestVersion -or
    [string]$manifest.weaselVersion -ne $expectedWeaselVersion -or
    [string]$manifest.originalSha256 -cne $expectedOfficialServerSha256 -or
    [string]$manifest.rimeSha256 -cne $expectedRimeSha256) {
    throw 'The Weasel host manifest is invalid or unsupported.'
}

$serverPath = Get-NormalizedPath ([string]$manifest.serverPath)
$weaselDirectory = Split-Path -Parent $serverPath
$rimePath = Assert-PathInside $weaselDirectory (Join-Path $weaselDirectory 'rime.dll') 'Weasel rime.dll'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf) -or -not (Test-Path -LiteralPath $rimePath -PathType Leaf)) {
    throw 'The patched Weasel installation is incomplete.'
}
if ((Get-Sha256 $rimePath) -cne $expectedRimeSha256) { throw 'The installed rime.dll no longer matches the pinned ABI.' }
if ((Get-Sha256 $serverPath) -cne [string]$manifest.patchedSha256) { throw 'The patched WeaselServer was modified; refusing automatic restore.' }

$backupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-weasel-host') 'Host patch backup root'
$backupPath = Assert-PathInside $backupRoot (Join-Path $backupRoot 'official-WeaselServer.exe') 'Official WeaselServer backup'
if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or (Get-Sha256 $backupPath) -cne $expectedOfficialServerSha256) {
    throw 'The official WeaselServer backup is missing or invalid.'
}

if (-not $PSCmdlet.ShouldProcess($serverPath, 'Restore the official Weasel 0.17.4 server')) { return }

$rollbackPath = Assert-PathInside $backupRoot (Join-Path $backupRoot ('patched-rollback-' + [guid]::NewGuid().ToString('N') + '.exe')) 'Patched rollback image'
$weaselWasRunning = $false
$restoredOfficial = $false
try {
    if (-not $DevelopmentNoProcessControl) {
        $weaselWasRunning = @(Get-SupportedWeaselProcesses $serverPath).Count -gt 0
        $null = @(Stop-SupportedWeaselProcesses $serverPath)
    }
    Copy-Item -LiteralPath $serverPath -Destination $rollbackPath -Force
    Copy-Item -LiteralPath $backupPath -Destination $serverPath -Force
    $restoredOfficial = $true
    if ((Get-Sha256 $serverPath) -cne $expectedOfficialServerSha256) { throw 'Official WeaselServer verification failed after restore.' }
    if (-not $DevelopmentNoProcessControl -and $weaselWasRunning) { Start-SupportedWeasel $serverPath }
    Remove-Item -LiteralPath $manifestPath -Force
    Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Official Weasel 0.17.4 server restored at '$serverPath'."
}
catch {
    $uninstallError = $_
    $rollbackErrors = @()
    if ($restoredOfficial -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
        try {
            if (-not $DevelopmentNoProcessControl) { $null = @(Stop-SupportedWeaselProcesses $serverPath) }
            Copy-Item -LiteralPath $rollbackPath -Destination $serverPath -Force
            if ((Get-Sha256 $serverPath) -cne [string]$manifest.patchedSha256) { throw 'Patched server hash mismatch after rollback.' }
        }
        catch { $rollbackErrors += "server: $($_.Exception.Message)" }
    }
    if (-not $DevelopmentNoProcessControl -and $weaselWasRunning -and $rollbackErrors.Count -eq 0) {
        try { Start-SupportedWeasel $serverPath }
        catch { $rollbackErrors += "restart: $($_.Exception.Message)" }
    }
    if ($rollbackErrors.Count -eq 0) { throw $uninstallError }
    throw ("Host patch uninstall failed: {0} Rollback was incomplete. Errors: {1}" -f $uninstallError.Exception.Message, ($rollbackErrors -join '; '))
}
