[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$product = 'rime-bilingual'
$manifestName = '.rime-bilingual-manifest.json'
$legacyManifestName = '.rime-bilingual-v0.1-manifest.json'
$cacheScript = Join-Path $ProjectRoot 'scripts\cache.ps1'
$payload = @(
    'lua\rime_bilingual.lua',
    'lua\rime_bilingual_dictionary.lua',
    'lua\rime_bilingual_cache.lua',
    'rime_ice.custom.yaml'
)

function Get-NormalizedPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\', '/') -eq $pathRoot.TrimEnd('\', '/')) { return $pathRoot }
    $fullPath.TrimEnd('\', '/')
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

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$ProjectRoot = Get-NormalizedPath $ProjectRoot
if ($RimeUserDir -eq [System.IO.Path]::GetPathRoot($RimeUserDir)) {
    throw 'RimeUserDir must not be a filesystem root.'
}
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $manifestName) 'V0.2 manifest'
$legacyManifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $legacyManifestName) 'Legacy manifest'

if ((Test-Path -LiteralPath $manifestPath) -and (Test-Path -LiteralPath $legacyManifestPath)) {
    $interruptedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($interruptedManifest.product -ne $product -or
        $interruptedManifest.manifestVersion -ne 2 -or
        $interruptedManifest.productVersion -ne '0.2') {
        throw 'Both manifests exist and the V0.2 manifest is invalid; refusing an ambiguous install.'
    }
    $interruptedBackupRootText = ([string]$interruptedManifest.backupRoot).Replace('/', '\')
    if ($interruptedBackupRootText -notmatch '^\.rime-bilingual-backups\\(?!\.{1,2}$)[^\\]+$') {
        throw 'Both manifests exist and the V0.2 backup root is invalid.'
    }
    $interruptedBackupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $interruptedBackupRootText) 'Interrupted-upgrade backup root'
    $expectedBackupParent = Get-NormalizedPath (Join-Path $RimeUserDir '.rime-bilingual-backups')
    if ((Get-NormalizedPath (Split-Path -Parent $interruptedBackupRoot)) -ne $expectedBackupParent) {
        throw 'Both manifests exist and the V0.2 backup root is not a dedicated child directory.'
    }
    $interruptedPaths = @($interruptedManifest.files | ForEach-Object { [string]$_.relativePath })
    $expectedInterruptedPaths = @($payload | Sort-Object)
    if (($interruptedPaths | Select-Object -Unique).Count -ne $interruptedPaths.Count -or
        $interruptedPaths.Count -ne $expectedInterruptedPaths.Count -or
        (Compare-Object -ReferenceObject $expectedInterruptedPaths -DifferenceObject @($interruptedPaths | Sort-Object))) {
        throw 'Both manifests exist and the V0.2 payload list is invalid.'
    }
    $interruptedDataRoots = @($interruptedManifest.dataRoots)
    if ($interruptedDataRoots.Count -ne 1 -or
        [string]$interruptedDataRoots[0].relativePath -ne 'rime-bilingual' -or
        [string]$interruptedDataRoots[0].uninstallPolicy -ne 'retain') {
        throw 'Both manifests exist and the V0.2 data root policy is invalid.'
    }
    foreach ($entry in $interruptedManifest.files) {
        $managedPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$entry.relativePath)) 'Interrupted-upgrade managed file'
        if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash -ne [string]$entry.sha256) {
            throw "Both manifests exist and the installed V0.2 payload is incomplete or modified: '$($entry.relativePath)'."
        }
        if ($entry.backupRelativePath) {
            $interruptedBackupPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$entry.backupRelativePath)) 'Interrupted-upgrade backup'
            if (-not $interruptedBackupPath.StartsWith($interruptedBackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $interruptedBackupPath -PathType Leaf)) {
                throw "Both manifests exist and the backup for '$($entry.relativePath)' is invalid."
            }
        }
    }
    if ($PSCmdlet.ShouldProcess($RimeUserDir, 'Finalize an interrupted V0.1 to V0.2 manifest migration')) {
        Remove-Item -LiteralPath $legacyManifestPath -Force
        Write-Host "Interrupted V0.2 manifest migration finalized in '$RimeUserDir'."
    }
    return
}
if (Test-Path -LiteralPath $manifestPath) {
    throw "Rime Bilingual V0.2 is already installed in '$RimeUserDir'."
}
foreach ($relativePath in $payload) {
    $sourcePath = Assert-PathInside $ProjectRoot (Join-Path $ProjectRoot $relativePath) 'Payload source'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required project file is missing: '$sourcePath'."
    }
    $null = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $relativePath) 'Payload destination'
}
$cacheScript = Assert-PathInside $ProjectRoot $cacheScript 'Cache tool'
if (-not (Test-Path -LiteralPath $cacheScript -PathType Leaf)) {
    throw "Required cache tool is missing: '$cacheScript'."
}

$legacyManifest = $null
$legacyEntries = @{}
if (Test-Path -LiteralPath $legacyManifestPath -PathType Leaf) {
    $legacyManifest = Get-Content -LiteralPath $legacyManifestPath -Raw | ConvertFrom-Json
    if ($legacyManifest.product -ne $product -or $legacyManifest.version -ne '0.1') {
        throw 'Unsupported legacy manifest.'
    }
    if (-not $legacyManifest.backupRoot) { throw 'Legacy manifest has no backupRoot.' }
    $legacyBackupRootText = ([string]$legacyManifest.backupRoot).Replace('/', '\')
    if ($legacyBackupRootText -notmatch '^\.rime-bilingual-backups\\(?!\.{1,2}$)[^\\]+$') {
        throw "Legacy backupRoot is not a dedicated Rime Bilingual backup directory: '$legacyBackupRootText'."
    }
    $legacyBackupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $legacyManifest.backupRoot) 'Legacy backup root'
    $expectedBackupParent = Get-NormalizedPath (Join-Path $RimeUserDir '.rime-bilingual-backups')
    if ((Get-NormalizedPath (Split-Path -Parent $legacyBackupRoot)) -ne $expectedBackupParent) {
        throw "Legacy backupRoot is not a dedicated child directory: '$legacyBackupRootText'."
    }
    $expectedLegacyPaths = @('lua\rime_bilingual.lua', 'lua\rime_bilingual_dictionary.lua', 'rime_ice.custom.yaml')
    foreach ($entry in $legacyManifest.files) {
        $relativePath = [string]$entry.relativePath
        if ($legacyEntries.ContainsKey($relativePath)) { throw "Legacy manifest contains duplicate path '$relativePath'." }
        $destinationPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $relativePath) 'Legacy managed file'
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "Legacy managed file is missing: '$relativePath'."
        }
        if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Legacy managed file was modified: '$relativePath'."
        }
        if ($entry.backupRelativePath) {
            $backupPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $entry.backupRelativePath) 'Legacy backup'
            if (-not $backupPath.StartsWith($legacyBackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                throw "Legacy backup is missing: '$backupPath'."
            }
        }
        $legacyEntries[$relativePath] = $entry
    }
    $actualLegacyPaths = @($legacyEntries.Keys | Sort-Object)
    $expectedLegacyPaths = @($expectedLegacyPaths | Sort-Object)
    if (($actualLegacyPaths.Count -ne $expectedLegacyPaths.Count) -or
        (Compare-Object -ReferenceObject $expectedLegacyPaths -DifferenceObject $actualLegacyPaths)) {
        throw 'Legacy manifest must contain exactly the three V0.1 managed payload files.'
    }
    $backupRelativeRoot = [string]$legacyManifest.backupRoot
}
else {
    $backupRelativeRoot = Join-Path '.rime-bilingual-backups' ('{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N')))
}

$cacheRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'rime-bilingual') 'Cache data root'
$databasePath = Assert-PathInside $RimeUserDir (Join-Path $cacheRoot 'translations.db') 'Cache database'
$snapshotPath = Assert-PathInside $RimeUserDir (Join-Path $cacheRoot 'cache_snapshot.lua') 'Cache snapshot'
if (Test-Path -LiteralPath $databasePath -PathType Leaf) {
    & $cacheScript validate -RimeRoot $RimeUserDir | Out-Null
}

$operation = if ($legacyManifest) { 'Upgrade Rime Bilingual V0.1 to V0.2' } else { 'Install Rime Bilingual V0.2' }
if (-not $PSCmdlet.ShouldProcess($RimeUserDir, $operation)) { return }

$backupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $backupRelativeRoot) 'Backup root'
$rollbackRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ('.rime-bilingual-rollback-' + [guid]::NewGuid().ToString('N'))) 'Rollback root'
$databaseExisted = Test-Path -LiteralPath $databasePath -PathType Leaf
$snapshotExisted = Test-Path -LiteralPath $snapshotPath -PathType Leaf
$rollbackEntries = @()
$installedFiles = @()
$manifestPublished = $false
$manifestTemp = $null
$createdBackupPaths = @()

try {
    New-Item -ItemType Directory -Path $RimeUserDir -Force | Out-Null
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null

    foreach ($relativePath in $payload) {
        $destinationPath = Join-Path $RimeUserDir $relativePath
        $rollbackPath = Join-Path $rollbackRoot $relativePath
        $existed = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if ($existed) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $rollbackPath) -Force | Out-Null
            Copy-Item -LiteralPath $destinationPath -Destination $rollbackPath -Force
        }
        $rollbackEntries += [pscustomobject]@{ relativePath = $relativePath; existed = $existed; rollbackPath = $rollbackPath }
    }
    if ($snapshotExisted) {
        $snapshotRollback = Join-Path $rollbackRoot 'data\cache_snapshot.lua'
        New-Item -ItemType Directory -Path (Split-Path -Parent $snapshotRollback) -Force | Out-Null
        Copy-Item -LiteralPath $snapshotPath -Destination $snapshotRollback -Force
    }

    foreach ($relativePath in $payload) {
        $sourcePath = Join-Path $ProjectRoot $relativePath
        $destinationPath = Join-Path $RimeUserDir $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
        $backupRelativePath = $null
        if ($legacyEntries.ContainsKey($relativePath)) {
            $backupRelativePath = $legacyEntries[$relativePath].backupRelativePath
        }
        elseif (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $backupRelativePath = Join-Path $backupRelativeRoot $relativePath
            $backupPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $backupRelativePath) 'Original-file backup'
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force
            $createdBackupPaths += $backupPath
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $installedFiles += [pscustomobject]@{
            relativePath = $relativePath
            backupRelativePath = $backupRelativePath
            sha256 = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        }
    }

    & $cacheScript init -RimeRoot $RimeUserDir | Out-Null
    & $cacheScript publish -RimeRoot $RimeUserDir | Out-Null

    $manifest = [pscustomobject]@{
        manifestVersion = 2
        product = $product
        productVersion = '0.2'
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        backupRoot = $backupRelativeRoot
        files = $installedFiles
        dataRoots = @([pscustomobject]@{ relativePath = 'rime-bilingual'; uninstallPolicy = 'retain' })
    }
    $manifestTemp = $manifestPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
    Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
    if ($legacyManifest) { Remove-Item -LiteralPath $legacyManifestPath -Force }
    $manifestPublished = $true
    try { Remove-Item -LiteralPath $rollbackRoot -Recurse -Force }
    catch { Write-Warning "Install committed, but temporary rollback data could not be removed: '$rollbackRoot'." }
    Write-Host "Rime Bilingual V0.2 installed in '$RimeUserDir'."
    Write-Host 'Run the Weasel deploy command to load the cache snapshot.'
}
catch {
    $installError = $_
    $rollbackErrors = @()
    if (-not $manifestPublished) {
        foreach ($entry in $rollbackEntries) {
            $destinationPath = Join-Path $RimeUserDir $entry.relativePath
            try {
                if ($entry.existed) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
                    Copy-Item -LiteralPath $entry.rollbackPath -Destination $destinationPath -Force
                }
                else { Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue }
            }
            catch { $rollbackErrors += "payload '$($entry.relativePath)': $($_.Exception.Message)" }
        }
        try {
            if ($snapshotExisted) {
                Copy-Item -LiteralPath (Join-Path $rollbackRoot 'data\cache_snapshot.lua') -Destination $snapshotPath -Force
            }
            else { Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue }
        }
        catch { $rollbackErrors += "snapshot: $($_.Exception.Message)" }
        try { if (-not $databaseExisted) { Remove-Item -LiteralPath $databasePath -Force -ErrorAction SilentlyContinue } }
        catch { $rollbackErrors += "database: $($_.Exception.Message)" }
        try { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue }
        catch { $rollbackErrors += "manifest: $($_.Exception.Message)" }
        if ($manifestTemp) { Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue }
        foreach ($backupPath in $createdBackupPaths) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    if ($rollbackErrors.Count -eq 0) {
        Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw $installError
    }
    throw ("Install failed: {0} Rollback was incomplete; recovery data was preserved at '{1}'. Errors: {2}" -f $installError.Exception.Message, $rollbackRoot, ($rollbackErrors -join '; '))
}
