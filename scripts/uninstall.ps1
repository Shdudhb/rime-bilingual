[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$LocalDataRoot = (Join-Path $env:LOCALAPPDATA 'RimeBilingual'),
    [switch]$PurgeCache,
    [switch]$PurgeAIAssets
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-NormalizedPath([string]$Path) {
    [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-PathInside([string]$Root, [string]$Path, [string]$Label) {
    $normalizedRoot = Get-NormalizedPath $Root
    $normalizedPath = Get-NormalizedPath $Path
    $prefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($normalizedPath -eq $normalizedRoot -or
        -not $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must resolve strictly inside '$normalizedRoot': '$normalizedPath'."
    }
    $currentPath = $normalizedRoot
    $relativePart = $normalizedPath.Substring($prefix.Length)
    foreach ($segment in $relativePart.Split(@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        if ((Test-Path -LiteralPath $currentPath) -and
            ((Get-Item -LiteralPath $currentPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "$Label traverses a symbolic link or junction at '$currentPath'."
        }
    }
    $normalizedPath
}

function Get-ManagedHelperProcesses([string]$HelperPath) {
    $normalizedHelperPath = Get-NormalizedPath $HelperPath
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name = 'RimeTranslateHelper.exe'" -ErrorAction Stop)
    }
    catch {
        throw "Cannot safely enumerate running RimeTranslateHelper processes before uninstall: $($_.Exception.Message)"
    }

    $matches = @()
    foreach ($row in $rows) {
        $processId = [int]$row.ProcessId
        $executablePath = [string]$row.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            throw "Cannot safely identify running RimeTranslateHelper.exe PID $processId before uninstall."
        }
        try { $actualPath = Get-NormalizedPath $executablePath }
        catch { throw "Cannot normalize executable path for RimeTranslateHelper.exe PID ${processId}: $($_.Exception.Message)" }
        if ($actualPath.Equals($normalizedHelperPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{ processId = $processId; executablePath = $actualPath }
        }
    }
    @($matches)
}

function Stop-ManagedHelperProcesses([string]$HelperPath) {
    foreach ($entry in @(Get-ManagedHelperProcesses $HelperPath)) {
        $processId = [int]$entry.processId
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try { $actualPath = Get-NormalizedPath $process.Path }
        catch { throw "Refusing uninstall: cannot re-verify managed Helper PID ${processId}: $($_.Exception.Message)" }
        if (-not $actualPath.Equals((Get-NormalizedPath $HelperPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing uninstall: Helper PID $processId changed identity before it could be stopped."
        }
        Stop-Process -Id $processId -ErrorAction Stop
        try { Wait-Process -Id $processId -Timeout 10 -ErrorAction SilentlyContinue } catch { }
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            throw "Refusing uninstall: managed Helper PID $processId did not stop within 10 seconds."
        }
    }
    $remaining = @(Get-ManagedHelperProcesses $HelperPath)
    if ($remaining.Count -gt 0) {
        throw "Refusing uninstall: the managed Helper restarted before payload mutation."
    }
}

function Get-SupportedWeaselProcesses([string]$WeaselServerPath) {
    $normalizedServerPath = Get-NormalizedPath $WeaselServerPath
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name = 'WeaselServer.exe'" -ErrorAction Stop)
    }
    catch {
        throw "Cannot safely enumerate WeaselServer processes before uninstall: $($_.Exception.Message)"
    }

    $matches = @()
    foreach ($row in $rows) {
        $processId = [int]$row.ProcessId
        $executablePath = [string]$row.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            throw "Cannot safely identify running WeaselServer.exe PID $processId before uninstall."
        }
        try { $actualPath = Get-NormalizedPath $executablePath }
        catch { throw "Cannot normalize executable path for WeaselServer.exe PID ${processId}: $($_.Exception.Message)" }
        if ($actualPath.Equals($normalizedServerPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{ processId = $processId; executablePath = $actualPath }
        }
    }
    @($matches)
}

function Get-WeaselBridgeOwners([string]$WeaselServerPath, [string]$BridgePath) {
    $normalizedBridgePath = Get-NormalizedPath $BridgePath
    $owners = @()
    foreach ($entry in @(Get-SupportedWeaselProcesses $WeaselServerPath)) {
        $processId = [int]$entry.processId
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            $loaded = @($process.Modules | ForEach-Object { Get-NormalizedPath $_.FileName })
        }
        catch {
            throw "Cannot safely inspect loaded modules for WeaselServer PID ${processId}: $($_.Exception.Message)"
        }
        if ($loaded | Where-Object { $_.Equals($normalizedBridgePath, [System.StringComparison]::OrdinalIgnoreCase) }) {
            $owners += $entry
        }
    }
    @($owners)
}

function Stop-SupportedWeaselProcesses([string]$WeaselServerPath, [string]$BridgePath) {
    $owners = @(Get-WeaselBridgeOwners $WeaselServerPath $BridgePath)
    if ($owners.Count -eq 0) { return @() }

    # Use Weasel's own shutdown command rather than Stop-Process. On Windows,
    # killing the process directly can cause the IME infrastructure to launch a
    # replacement WeaselServer immediately, which maps the managed bridge again.
    # The official Weasel installer/uninstaller uses `WeaselServer.exe /quit`.
    $workingDirectory = Split-Path -Parent $WeaselServerPath
    $quit = Start-Process -FilePath $WeaselServerPath -ArgumentList '/quit' -WorkingDirectory $workingDirectory -PassThru

    # Do not wait on the /quit child itself. On some Weasel 0.17.4 systems the
    # /quit invocation can turn into the replacement server and stay alive. What
    # matters for safe deletion is that no verified WeaselServer still maps the
    # managed bridge.
    $graceDeadline = (Get-Date).AddSeconds(2)
    do {
        Start-Sleep -Milliseconds 100
        if (@(Get-WeaselBridgeOwners $WeaselServerPath $BridgePath).Count -eq 0) { break }
    } while ((Get-Date) -lt $graceDeadline)

    # If graceful shutdown did not fully release the bridge, terminate only
    # exact-path Weasel processes that still own this installation's bridge.
    # This includes the /quit child if it became the new server.
    $forceDeadline = (Get-Date).AddSeconds(8)
    do {
        $remainingOwners = @(Get-WeaselBridgeOwners $WeaselServerPath $BridgePath)
        if ($remainingOwners.Count -eq 0) {
            Start-Sleep -Milliseconds 500
            if (@(Get-WeaselBridgeOwners $WeaselServerPath $BridgePath).Count -eq 0) {
                return @($owners | ForEach-Object { [int]$_.processId })
            }
            continue
        }

        foreach ($entry in $remainingOwners) {
            $processId = [int]$entry.processId
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            try { $actualPath = Get-NormalizedPath $process.Path }
            catch { throw "Refusing uninstall: cannot re-verify WeaselServer PID ${processId}: $($_.Exception.Message)" }
            if (-not $actualPath.Equals((Get-NormalizedPath $WeaselServerPath), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing uninstall: WeaselServer PID $processId changed identity before forced shutdown."
            }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $forceDeadline)

    $remainingOwners = @(Get-WeaselBridgeOwners $WeaselServerPath $BridgePath)
    if ($remainingOwners.Count -gt 0) {
        throw 'Refusing uninstall: a verified WeaselServer still has the managed bridge loaded after graceful and forced shutdown.'
    }
    return @($owners | ForEach-Object { [int]$_.processId })
}

function Start-SupportedWeasel([string]$WeaselServerPath) {
    $workingDirectory = Split-Path -Parent $WeaselServerPath
    Start-Process -FilePath $WeaselServerPath -WorkingDirectory $workingDirectory | Out-Null
    Start-Sleep -Milliseconds 500
    if (@(Get-SupportedWeaselProcesses $WeaselServerPath).Count -eq 0) {
        throw "Failed to restart supported WeaselServer at '$WeaselServerPath'."
    }
}

function Deploy-And-StartSupportedWeasel([string]$WeaselDeployerPath, [string]$WeaselServerPath) {
    $workingDirectory = Split-Path -Parent $WeaselDeployerPath
    # WeaselDeployer /deploy calls Client.Connect() before deployment. If the
    # server is fully stopped, the upstream named-pipe client can wait forever.
    # Start the exact supported server first; the deployer then puts it into
    # maintenance mode and resumes it after the workspace update.
    Start-SupportedWeasel $WeaselServerPath
    $deployer = Start-Process -FilePath $WeaselDeployerPath -ArgumentList '/deploy' -WorkingDirectory $workingDirectory -PassThru
    $timedOut = $false
    try { Wait-Process -Id $deployer.Id -Timeout 120 -ErrorAction Stop }
    catch {
        if ($null -ne (Get-Process -Id $deployer.Id -ErrorAction SilentlyContinue)) {
            $timedOut = $true
            Stop-Process -Id $deployer.Id -Force -ErrorAction SilentlyContinue
            try { Wait-Process -Id $deployer.Id -Timeout 5 -ErrorAction SilentlyContinue } catch { }
        }
    }
    if ($timedOut) { throw 'Weasel redeploy timed out after 120 seconds.' }
    $deployer.Refresh()
    if ($deployer.ExitCode -ne 0) {
        throw "Weasel redeploy failed with exit code $($deployer.ExitCode)."
    }
    Start-SupportedWeasel $WeaselServerPath
}

function Test-ManagedDestinationReplaceable([object[]]$Entries, [string]$RetryMessage) {
    foreach ($entry in $Entries) {
        if (-not $entry.existed) { continue }
        $probePath = $entry.destinationPath + '.rbil-uninstall-probe-' + [guid]::NewGuid().ToString('N')
        $moved = $false
        try {
            Move-Item -LiteralPath $entry.destinationPath -Destination $probePath -ErrorAction Stop
            $moved = $true
            Move-Item -LiteralPath $probePath -Destination $entry.destinationPath -ErrorAction Stop
            $moved = $false
        }
        catch {
            $probeError = $_
            if ($moved -and (Test-Path -LiteralPath $probePath -PathType Leaf)) {
                try { Move-Item -LiteralPath $probePath -Destination $entry.destinationPath -ErrorAction Stop }
                catch { throw "Managed-file lock probe failed and could not restore '$($entry.destinationPath)': $($_.Exception.Message)" }
            }
            throw "Uninstall made no payload changes because a managed file is locked or not replaceable: '$($entry.destinationPath)'. $RetryMessage $($probeError.Exception.Message)"
        }
    }
}

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-manifest.json') 'V0.3 manifest'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Rime Bilingual V0.3 is not installed in '$RimeUserDir' (manifest not found)."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.product -ne 'rime-bilingual' -or
    $manifest.manifestVersion -ne 4 -or
    $manifest.productVersion -ne '0.3') {
    throw "The manifest in '$RimeUserDir' is not a supported Rime Bilingual V0.3 manifest."
}
if (-not $manifest.rimeAbi -or
    [string]$manifest.rimeAbi.path -cne 'C:\Program Files\Rime\weasel-0.17.4\rime.dll' -or
    [string]$manifest.rimeAbi.sha256 -cne '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B' -or
    [string]$manifest.rimeAbi.machine -cne 'x64' -or
    [string]$manifest.rimeAbi.bridgeExport -cne 'luaopen_rime_bilingual_bridge') {
    throw 'The manifest Rime ABI pin is missing or invalid.'
}
$supportedWeaselDirectory = Split-Path -Parent ([string]$manifest.rimeAbi.path)
$supportedWeaselServerPath = Get-NormalizedPath (Join-Path $supportedWeaselDirectory 'WeaselServer.exe')
$supportedWeaselDeployerPath = Get-NormalizedPath (Join-Path $supportedWeaselDirectory 'WeaselDeployer.exe')
if (-not (Test-Path -LiteralPath $supportedWeaselServerPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $supportedWeaselDeployerPath -PathType Leaf)) {
    throw 'The supported Weasel server/deployer executable is missing.'
}
if (-not $manifest.backupRoot) { throw 'The install manifest has no backupRoot.' }
$backupRootText = ([string]$manifest.backupRoot).Replace('/', '\')
if ($backupRootText -notmatch '^\.rime-bilingual-backups\\(?!\.{1,2}$)[^\\]+$') {
    throw "The manifest backupRoot is not a dedicated Rime Bilingual backup directory: '$backupRootText'."
}

$expectedManagedPaths = @(
    'lua\rime_bilingual.lua',
    'lua\rime_bilingual_dictionary.lua',
    'lua\rime_bilingual_cache.lua',
    'lua\rime_bilingual_async.lua',
    'rime_ice.custom.yaml',
    'rime-bilingual\native\rime_bilingual_bridge.dll'
) | Sort-Object
$manifestPaths = @($manifest.files | ForEach-Object { [string]$_.relativePath })
if (($manifestPaths | Select-Object -Unique).Count -ne $manifestPaths.Count -or
    $manifestPaths.Count -ne $expectedManagedPaths.Count -or
    (Compare-Object -ReferenceObject $expectedManagedPaths -DifferenceObject @($manifestPaths | Sort-Object))) {
    throw 'The manifest must contain exactly the six unique V0.3 managed payload files.'
}
$dataRoots = @($manifest.dataRoots)
if ($dataRoots.Count -ne 1 -or
    [string]$dataRoots[0].relativePath -ne 'rime-bilingual' -or
    [string]$dataRoots[0].uninstallPolicy -ne 'retain') {
    throw 'The manifest must contain exactly the retained rime-bilingual data root.'
}

$manifestAIRoot = Get-NormalizedPath ([string]$manifest.aiRoot)
if ($manifestAIRoot -eq [System.IO.Path]::GetPathRoot($manifestAIRoot) -or $manifestAIRoot -eq $RimeUserDir) {
    throw 'The manifest AI root is unsafe.'
}
$LocalDataRoot = Get-NormalizedPath $LocalDataRoot
if ($LocalDataRoot -ne $manifestAIRoot) { throw 'LocalDataRoot does not match the installed manifest.' }
if ((Test-Path -LiteralPath $LocalDataRoot) -and
    ((Get-Item -LiteralPath $LocalDataRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'LocalDataRoot must not be a symbolic link or junction.'
}
$aiEntries = @($manifest.aiAssets)
if ([string]$manifest.helperInstallPolicy -eq 'managed') {
    if ($aiEntries.Count -ne 1 -or [string]$aiEntries[0].relativePath -ne 'bin\RimeTranslateHelper.exe') {
        throw 'The manifest must contain the managed Helper asset.'
    }
}
elseif ([string]$manifest.helperInstallPolicy -eq 'skipped') {
    if ($aiEntries.Count -ne 0) { throw 'A skipped Helper install must not contain AI assets.' }
}
else { throw 'The manifest Helper install policy is invalid.' }

$backupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$manifest.backupRoot)) 'Backup root'
$expectedBackupParent = Get-NormalizedPath (Join-Path $RimeUserDir '.rime-bilingual-backups')
if ((Get-NormalizedPath (Split-Path -Parent $backupRoot)) -ne $expectedBackupParent) {
    throw 'The manifest backupRoot must be one dedicated child of .rime-bilingual-backups.'
}
$validatedEntries = @()
$changedFiles = @()
foreach ($entry in $manifest.files) {
    $relativePath = [string]$entry.relativePath
    if ([string]::IsNullOrWhiteSpace($relativePath)) { throw 'The manifest contains an empty managed path.' }
    $destinationPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $relativePath) 'Managed file'
    if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne [string]$entry.sha256)) {
        $changedFiles += $relativePath
    }
    elseif ((Test-Path -LiteralPath $destinationPath) -and -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        $changedFiles += $relativePath
    }

    $backupPath = $null
    if ($entry.backupRelativePath) {
        $backupPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$entry.backupRelativePath)) 'Original-file backup'
        $backupPrefix = $backupRoot + [System.IO.Path]::DirectorySeparatorChar
        if (-not $backupPath.StartsWith($backupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Backup for '$relativePath' is outside the dedicated backup root."
        }
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Cannot restore '$relativePath': backup is missing at '$backupPath'."
        }
    }
    $validatedEntries += [pscustomobject]@{
        relativePath = $relativePath
        destinationPath = $destinationPath
        backupPath = $backupPath
        existed = (Test-Path -LiteralPath $destinationPath -PathType Leaf)
    }
}
$validatedAIEntries = @()
$aiBackupRoot = $null
$aiEntriesWithBackup = @($aiEntries | Where-Object { $_.backupRelativePath })
if ($aiEntriesWithBackup.Count -eq 0 -and $manifest.aiBackupRoot) { throw 'The manifest has an unused AI backup root.' }
if ($aiEntriesWithBackup.Count -gt 0 -and -not $manifest.aiBackupRoot) { throw 'The manifest AI backup root is missing.' }
if ($manifest.aiBackupRoot) {
    $aiBackupRootText = ([string]$manifest.aiBackupRoot).Replace('/', '\')
    if ($aiBackupRootText -notmatch '^\.rime-bilingual-backups\\[^\\]+\\ai$') { throw 'The manifest AI backup root is invalid.' }
    $aiBackupRoot = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot $aiBackupRootText) 'AI backup root'
}
foreach ($entry in $aiEntries) {
    $destinationPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot ([string]$entry.relativePath)) 'Managed AI file'
    if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and
        (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne [string]$entry.sha256) {
        $changedFiles += ('AI:' + [string]$entry.relativePath)
    }
    elseif ((Test-Path -LiteralPath $destinationPath) -and -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        $changedFiles += ('AI:' + [string]$entry.relativePath)
    }
    $backupPath = $null
    if ($entry.backupRelativePath) {
        $backupPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot ([string]$entry.backupRelativePath)) 'AI backup'
        if (-not $aiBackupRoot -or
            -not $backupPath.StartsWith($aiBackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw 'The original Helper backup is missing or outside its dedicated root.' }
    }
    $validatedAIEntries += [pscustomobject]@{ destinationPath = $destinationPath; backupPath = $backupPath; existed = (Test-Path -LiteralPath $destinationPath -PathType Leaf) }
}
if ($changedFiles.Count -gt 0) {
    throw ('Uninstall stopped because installed files were modified: {0}. Save those changes or restore the installed files, then retry.' -f ($changedFiles -join ', '))
}

$cacheRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'rime-bilingual') 'Cache root'
$operation = 'Uninstall Rime Bilingual V0.3 and restore backups'
if ($PurgeCache) { $operation += '; permanently delete the local translation database and snapshot' }
if ($PurgeAIAssets) { $operation += '; permanently delete Helper, model, runtime, configuration, and logs' }
if (-not $PSCmdlet.ShouldProcess($RimeUserDir, $operation)) { return }

# Probe Rime destinations before stopping Helper. This keeps a locked Weasel DLL
# failure side-effect free even at the process level. A running Windows PE image
# can allow rename while still denying delete, so the Helper is handled by exact
# process identity rather than relying on this rename probe.
Test-ManagedDestinationReplaceable -Entries $validatedEntries -RetryMessage 'Exit Weasel normally, then retry.'

if ($validatedAIEntries.Count -gt 0) {
    $managedHelperPath = [string]$validatedAIEntries[0].destinationPath
    Stop-ManagedHelperProcesses $managedHelperPath
    Test-ManagedDestinationReplaceable -Entries $validatedAIEntries -RetryMessage 'Ensure the managed Helper is not being relaunched, then retry.'
}

# Validate and stop only the exact llama-server instance managed by model.ps1
# before changing any installed files. A mismatch fails the uninstall atomically.
if ($PurgeAIAssets -and (Test-Path -LiteralPath $LocalDataRoot -PathType Container)) {
    $pidPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot 'llama-server.pid.json') 'llama-server PID record'
    $configPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot 'config.json') 'model configuration'
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        try { $pidRecord = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json } catch { throw 'Refusing AI purge: PID record is invalid.' }
        $process = Get-Process -Id ([int]$pidRecord.pid) -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Refusing AI purge: a recorded process exists but config.json is missing.' }
            $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            try { $actualExecutable = Get-NormalizedPath $process.Path } catch { throw 'Refusing AI purge: cannot verify the recorded process executable.' }
            if ($actualExecutable -ne (Get-NormalizedPath ([string]$pidRecord.executable_path)) -or
                $actualExecutable -ne (Get-NormalizedPath ([string]$configuration.runtime_path))) {
                throw 'Refusing AI purge: recorded PID does not identify the managed llama-server.'
            }
            $row = Get-CimInstance Win32_Process -Filter ("ProcessId = " + ([int]$pidRecord.pid)) -ErrorAction SilentlyContinue
            $commandLine = if ($row) { [string]$row.CommandLine } else { '' }
            if ([string]::IsNullOrWhiteSpace($commandLine) -or
                $commandLine.IndexOf([string]$configuration.model_path, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
                $commandLine -notmatch '(?:^|\s)--host\s+127\.0\.0\.1(?:\s|$)' -or
                $commandLine -notmatch ('(?:^|\s)--port\s+' + [regex]::Escape(([int]$configuration.port).ToString()) + '(?:\s|$)')) {
                throw 'Refusing AI purge: recorded PID command line does not match the managed llama-server.'
            }
            Stop-Process -Id ([int]$pidRecord.pid) -ErrorAction Stop
            try { Wait-Process -Id ([int]$pidRecord.pid) -Timeout 10 -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# WeaselServer can keep the native bridge image mapped while a same-directory
# rename probe still succeeds. Stop only the exact pinned WeaselServer that has
# this installation's bridge loaded, and do it as the final pre-transaction
# step so earlier preflight failures cannot leave the input method stopped.
$managedBridgeEntry = @($validatedEntries | Where-Object { $_.relativePath -eq 'rime-bilingual\native\rime_bilingual_bridge.dll' })[0]
$managedBridgePath = [string]$managedBridgeEntry.destinationPath
$stoppedWeaselPids = @(Stop-SupportedWeaselProcesses $supportedWeaselServerPath $managedBridgePath)
$weaselWasRunning = $stoppedWeaselPids.Count -gt 0

$rollbackRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ('.rime-bilingual-uninstall-rollback-' + [guid]::NewGuid().ToString('N'))) 'Uninstall rollback root'
$rollbackRecords = @()
$committed = $false
try {
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    $recordIndex = 0
    foreach ($entry in @($validatedEntries) + @($validatedAIEntries)) {
        $snapshotPath = Join-Path $rollbackRoot (('{0:D3}.bin' -f $recordIndex))
        if ($entry.existed) { Copy-Item -LiteralPath $entry.destinationPath -Destination $snapshotPath -Force }
        $rollbackRecords += [pscustomobject]@{ destinationPath = $entry.destinationPath; existed = $entry.existed; snapshotPath = $snapshotPath }
        $recordIndex++
    }

    # Mutate the Helper first. If Windows still refuses to replace/delete the PE
    # image, the uninstall fails before any Rime payload has been touched.
    foreach ($entry in $validatedAIEntries) {
        if ($entry.backupPath -and -not $PurgeAIAssets) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $entry.backupPath -Destination $entry.destinationPath -Force
        }
        elseif (Test-Path -LiteralPath $entry.destinationPath) { Remove-Item -LiteralPath $entry.destinationPath -Force }
    }
    # The native bridge is the first Rime mutation. If another process still has
    # the image mapped, failure occurs before Lua/schema payloads are touched.
    $bridgeEntries = @($validatedEntries | Where-Object { $_.relativePath -eq 'rime-bilingual\native\rime_bilingual_bridge.dll' })
    $otherRimeEntries = @($validatedEntries | Where-Object { $_.relativePath -ne 'rime-bilingual\native\rime_bilingual_bridge.dll' })
    foreach ($entry in @($bridgeEntries) + @($otherRimeEntries)) {
        if ($entry.backupPath) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $entry.backupPath -Destination $entry.destinationPath -Force
        }
        elseif (Test-Path -LiteralPath $entry.destinationPath) { Remove-Item -LiteralPath $entry.destinationPath -Force }
    }

    # The manifest is the commit marker. Persistent backups are intentionally
    # retained until after it is removed, so an interrupted run remains resumable.
    Remove-Item -LiteralPath $manifestPath -Force
    $committed = $true
}
catch {
    $uninstallError = $_
    $rollbackErrors = @()
    if (-not $committed) {
        foreach ($record in $rollbackRecords) {
            try {
                if ($record.existed) {
                    $alreadyRestored = (Test-Path -LiteralPath $record.destinationPath -PathType Leaf) -and
                        ((Get-FileHash -LiteralPath $record.destinationPath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $record.snapshotPath -Algorithm SHA256).Hash)
                    if (-not $alreadyRestored) {
                        New-Item -ItemType Directory -Path (Split-Path -Parent $record.destinationPath) -Force | Out-Null
                        Copy-Item -LiteralPath $record.snapshotPath -Destination $record.destinationPath -Force
                    }
                }
                elseif (Test-Path -LiteralPath $record.destinationPath) { Remove-Item -LiteralPath $record.destinationPath -Force }
            }
            catch { $rollbackErrors += "'$($record.destinationPath)': $($_.Exception.Message)" }
        }
    }
    if ($rollbackErrors.Count -eq 0) {
        Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ($weaselWasRunning) {
            try { Start-SupportedWeasel $supportedWeaselServerPath }
            catch { throw ("{0} Rollback succeeded, but WeaselServer could not be restarted: {1}" -f $uninstallError.Exception.Message, $_.Exception.Message) }
        }
        throw $uninstallError
    }
    throw ("Uninstall failed: {0} Rollback was incomplete; recovery data remains at '{1}'. Errors: {2}" -f $uninstallError.Exception.Message, $rollbackRoot, ($rollbackErrors -join '; '))
}

Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
$nativeDirectory = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'rime-bilingual\native') 'Native bridge directory'
if ((Test-Path -LiteralPath $nativeDirectory -PathType Container) -and -not (Get-ChildItem -LiteralPath $nativeDirectory -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $nativeDirectory -Force -ErrorAction SilentlyContinue
}
if ($aiBackupRoot -and (Test-Path -LiteralPath $aiBackupRoot -PathType Container)) {
    Remove-Item -LiteralPath $aiBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $backupRoot -PathType Container) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
$backupParent = Split-Path -Parent $backupRoot
if ((Test-Path -LiteralPath $backupParent -PathType Container) -and -not (Get-ChildItem -LiteralPath $backupParent -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $backupParent -Force -ErrorAction SilentlyContinue
}
if ($PurgeCache -and (Test-Path -LiteralPath $cacheRoot -PathType Container)) { Remove-Item -LiteralPath $cacheRoot -Recurse -Force }
if ($PurgeAIAssets -and (Test-Path -LiteralPath $LocalDataRoot -PathType Container)) { Remove-Item -LiteralPath $LocalDataRoot -Recurse -Force }

if ($weaselWasRunning) {
    try {
        Deploy-And-StartSupportedWeasel $supportedWeaselDeployerPath $supportedWeaselServerPath
    }
    catch {
        Write-Warning "Uninstall committed, but Weasel redeploy/restart failed: $($_.Exception.Message) Run '$supportedWeaselDeployerPath /deploy' and then start '$supportedWeaselServerPath'."
    }
}

Write-Host "Rime Bilingual V0.3 uninstalled from '$RimeUserDir'."
if ($PurgeCache) {
    Write-Host 'The local translation database and published snapshot were deleted.'
}
else {
    Write-Host "Local translation data was retained in '$cacheRoot'. Use -PurgeCache to remove it during uninstall."
}
if (-not $PurgeAIAssets) { Write-Host "Model, runtime, configuration, and logs were retained in '$LocalDataRoot'. Use -PurgeAIAssets to remove them." }
if ($weaselWasRunning) {
    Write-Host 'Weasel was redeployed and restarted after uninstall.'
}
else {
    Write-Host 'Run the Weasel deploy command to reload the restored schema configuration.'
}
