[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [switch]$PurgeCache
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

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir '.rime-bilingual-manifest.json') 'V0.2 manifest'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Rime Bilingual V0.2 is not installed in '$RimeUserDir' (manifest not found)."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.product -ne 'rime-bilingual' -or
    $manifest.manifestVersion -ne 2 -or
    $manifest.productVersion -ne '0.2') {
    throw "The manifest in '$RimeUserDir' is not a supported Rime Bilingual V0.2 manifest."
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
    'rime_ice.custom.yaml'
) | Sort-Object
$manifestPaths = @($manifest.files | ForEach-Object { [string]$_.relativePath })
if (($manifestPaths | Select-Object -Unique).Count -ne $manifestPaths.Count -or
    $manifestPaths.Count -ne $expectedManagedPaths.Count -or
    (Compare-Object -ReferenceObject $expectedManagedPaths -DifferenceObject @($manifestPaths | Sort-Object))) {
    throw 'The manifest must contain exactly the four unique V0.2 managed payload files.'
}
$dataRoots = @($manifest.dataRoots)
if ($dataRoots.Count -ne 1 -or
    [string]$dataRoots[0].relativePath -ne 'rime-bilingual' -or
    [string]$dataRoots[0].uninstallPolicy -ne 'retain') {
    throw 'The manifest must contain exactly the retained rime-bilingual data root.'
}

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
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf) -or
        ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne [string]$entry.sha256)) {
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
    }
}
if ($changedFiles.Count -gt 0) {
    throw ('Uninstall stopped because installed files were modified: {0}. Save those changes or restore the installed files, then retry.' -f ($changedFiles -join ', '))
}

$cacheRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir 'rime-bilingual') 'Cache root'
$operation = 'Uninstall Rime Bilingual V0.2 and restore backups'
if ($PurgeCache) { $operation += '; permanently delete the local translation database and snapshot' }
if (-not $PSCmdlet.ShouldProcess($RimeUserDir, $operation)) { return }

foreach ($entry in $validatedEntries) {
    if ($entry.backupPath) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destinationPath) -Force | Out-Null
        Copy-Item -LiteralPath $entry.backupPath -Destination $entry.destinationPath -Force
    }
    elseif (Test-Path -LiteralPath $entry.destinationPath) {
        Remove-Item -LiteralPath $entry.destinationPath -Force
    }
}

if (Test-Path -LiteralPath $backupRoot) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
}
$backupParent = Split-Path -Parent $backupRoot
if ((Test-Path -LiteralPath $backupParent -PathType Container) -and
    -not (Get-ChildItem -LiteralPath $backupParent -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $backupParent -Force
}
Remove-Item -LiteralPath $manifestPath -Force

if ($PurgeCache -and (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
    Remove-Item -LiteralPath $cacheRoot -Recurse -Force
}

Write-Host "Rime Bilingual V0.2 uninstalled from '$RimeUserDir'."
if ($PurgeCache) {
    Write-Host 'The local translation database and published snapshot were deleted.'
}
else {
    Write-Host "Local translation data was retained in '$cacheRoot'. Use -PurgeCache to remove it during uninstall."
}
Write-Host 'Run the Weasel deploy command to reload the restored schema configuration.'
