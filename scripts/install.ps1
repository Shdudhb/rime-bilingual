[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime'),
    [string]$ProjectRoot,
    [string]$LocalDataRoot = (Join-Path $env:LOCALAPPDATA 'RimeBilingual'),
    [string]$HelperPath,
    [string]$BridgePath,
    [switch]$SkipHelper
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

$product = 'rime-bilingual'
$manifestName = '.rime-bilingual-manifest.json'
$legacyManifestName = '.rime-bilingual-v0.1-manifest.json'
$cacheScript = Join-Path $ProjectRoot 'scripts\cache.ps1'
$productVersion = '0.3'
$manifestVersion = 4
$supportedRimePath = 'C:\Program Files\Rime\weasel-0.17.4\rime.dll'
$supportedRimeSha256 = '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B'
$bridgeExport = 'luaopen_rime_bilingual_bridge'
$payload = @(
    'lua\rime_bilingual.lua',
    'lua\rime_bilingual_dictionary.lua',
    'lua\rime_bilingual_cache.lua',
    'lua\rime_bilingual_async.lua',
    'rime_ice.custom.yaml',
    'rime-bilingual\native\rime_bilingual_bridge.dll'
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

function Get-Sha256([string]$Path) {
    # Windows PowerShell 5.1 can propagate -WhatIf into Get-FileHash's provider
    # resolution when this script is invoked through powershell.exe -File. Use
    # .NET directly so dry-run validation remains a pure read and still executes.
    $stream = $null
    $sha = $null
    try {
        $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        ([System.BitConverter]::ToString($bytes)).Replace('-', '')
    }
    finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-PEMetadata([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Not a valid PE image: '$Path'." }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($pe -lt 0 -or $pe + 24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { throw "Not a valid PE image: '$Path'." }
    $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $sections = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optional = $pe + 24
    $magic = [BitConverter]::ToUInt16($bytes, $optional)
    $directory = if ($magic -eq 0x20b) { $optional + 112 } elseif ($magic -eq 0x10b) { $optional + 96 } else { throw "Unsupported PE optional header: '$Path'." }
    $exportRva = [BitConverter]::ToUInt32($bytes, $directory)
    $sectionTable = $optional + $optionalSize
    $sectionRows = @()
    for ($i = 0; $i -lt $sections; $i++) {
        $row = $sectionTable + ($i * 40)
        if ($row + 40 -gt $bytes.Length) { throw "Truncated PE section table: '$Path'." }
        $sectionRows += [pscustomobject]@{
            VirtualSize = [BitConverter]::ToUInt32($bytes, $row + 8)
            VirtualAddress = [BitConverter]::ToUInt32($bytes, $row + 12)
            RawSize = [BitConverter]::ToUInt32($bytes, $row + 16)
            RawAddress = [BitConverter]::ToUInt32($bytes, $row + 20)
        }
    }
    function Convert-Rva([uint32]$Rva) {
        foreach ($section in $sectionRows) {
            $span = [Math]::Max([uint64]$section.VirtualSize, [uint64]$section.RawSize)
            if ([uint64]$Rva -ge [uint64]$section.VirtualAddress -and [uint64]$Rva -lt ([uint64]$section.VirtualAddress + $span)) {
                $offset = [uint64]$section.RawAddress + ([uint64]$Rva - [uint64]$section.VirtualAddress)
                if ($offset -ge [uint64]$bytes.Length) { throw "PE RVA points outside the image: '$Path'." }
                return [int64]$offset
            }
        }
        throw "PE RVA is not mapped by a section: '$Path'."
    }
    $exports = @()
    if ($exportRva -ne 0) {
        $exportOffset = Convert-Rva $exportRva
        if ($exportOffset + 40 -gt $bytes.Length) { throw "Truncated PE export directory: '$Path'." }
        $nameCount = [BitConverter]::ToUInt32($bytes, [int]$exportOffset + 24)
        $namesRva = [BitConverter]::ToUInt32($bytes, [int]$exportOffset + 32)
        if ($nameCount -gt 4096) { throw "Unreasonable PE export count: '$Path'." }
        $namesOffset = Convert-Rva $namesRva
        for ($i = 0; $i -lt $nameCount; $i++) {
            $entryOffset = $namesOffset + ($i * 4)
            if ($entryOffset + 4 -gt $bytes.Length) { throw "Truncated PE export names: '$Path'." }
            $nameOffset = Convert-Rva ([BitConverter]::ToUInt32($bytes, [int]$entryOffset))
            $end = $nameOffset
            while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
            if ($end -ge $bytes.Length -or ($end - $nameOffset) -gt 512) { throw "Invalid PE export name: '$Path'." }
            $exports += [Text.Encoding]::ASCII.GetString($bytes, [int]$nameOffset, [int]($end - $nameOffset))
        }
    }
    [pscustomobject]@{ Machine = $machine; Exports = $exports }
}

$RimeUserDir = Get-NormalizedPath $RimeUserDir
$ProjectRoot = Get-NormalizedPath $ProjectRoot
$LocalDataRoot = Get-NormalizedPath $LocalDataRoot
if ($RimeUserDir -eq [System.IO.Path]::GetPathRoot($RimeUserDir)) {
    throw 'RimeUserDir must not be a filesystem root.'
}
$manifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $manifestName) 'Install manifest'
$legacyManifestPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $legacyManifestName) 'Legacy manifest'

if ($LocalDataRoot -eq [System.IO.Path]::GetPathRoot($LocalDataRoot) -or $LocalDataRoot -eq $RimeUserDir) {
    throw 'LocalDataRoot must be a dedicated non-root directory separate from RimeUserDir.'
}
if ((Test-Path -LiteralPath $LocalDataRoot) -and
    ((Get-Item -LiteralPath $LocalDataRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'LocalDataRoot must not be a symbolic link or junction.'
}
if (-not $HelperPath) { $HelperPath = Join-Path $ProjectRoot 'helper\target\release\RimeTranslateHelper.exe' }
if (-not $BridgePath) { $BridgePath = Join-Path $ProjectRoot 'bridge\target\release\rime_bilingual_bridge.dll' }
$HelperPath = Get-NormalizedPath $HelperPath
$BridgePath = Get-NormalizedPath $BridgePath
$helperDestination = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot 'bin\RimeTranslateHelper.exe') 'Helper destination'
if (-not $SkipHelper -and -not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw "Built Helper is missing: '$HelperPath'. Build it first or explicitly use -SkipHelper."
}
if (-not (Test-Path -LiteralPath $BridgePath -PathType Leaf)) {
    throw "Built native bridge is missing: '$BridgePath'. Run scripts\build-bridge.ps1 first."
}
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Rime Bilingual V0.3 requires an x64 Windows host and an x64 PowerShell process.'
}
$bridgeMetadata = Get-PEMetadata $BridgePath
if ($bridgeMetadata.Machine -ne 0x8664) { throw "Native bridge is not an x64 PE image: '$BridgePath'." }
$bridgeExports = @($bridgeMetadata.Exports)
if ($bridgeExports.Count -ne 1 -or $bridgeExports[0] -cne $bridgeExport) {
    throw "Native bridge must export only '$bridgeExport'."
}
if (-not (Test-Path -LiteralPath $supportedRimePath -PathType Leaf)) {
    throw "Supported Weasel rime.dll is missing: '$supportedRimePath'."
}
$actualRimeSha256 = Get-Sha256 $supportedRimePath
if ($actualRimeSha256 -cne $supportedRimeSha256) {
    throw "Unsupported rime.dll build at '$supportedRimePath'; SHA-256 mismatch."
}

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
            (Get-Sha256 $managedPath) -ne [string]$entry.sha256) {
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
$v2Manifest = $null
$v2ManifestText = $null
$v2ManifestBytes = $null
$isV02AI = $false
$isV03Repair = $false
$previousAIAssets = @()
$previousHelperPolicy = $null
if (Test-Path -LiteralPath $manifestPath) {
    $v2ManifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $v2ManifestText = Get-Content -LiteralPath $manifestPath -Raw
    $candidateManifest = $v2ManifestText | ConvertFrom-Json
    $candidatePaths = @($candidateManifest.files | ForEach-Object { [string]$_.relativePath })
    $isV03 = $candidateManifest.product -eq $product -and $candidateManifest.manifestVersion -eq $manifestVersion -and $candidateManifest.productVersion -eq $productVersion
    if ($isV03) {
        $completeV03 = $candidatePaths.Count -eq $payload.Count -and
            ($candidatePaths | Select-Object -Unique).Count -eq $candidatePaths.Count -and
            -not (Compare-Object -ReferenceObject @($payload | Sort-Object) -DifferenceObject @($candidatePaths | Sort-Object))
        if ($completeV03) { throw "Rime Bilingual $productVersion is already installed in '$RimeUserDir'." }
        $repairPayload = @($payload | Where-Object { $_ -ne 'lua\rime_bilingual_async.lua' })
        $isV03Repair = $candidatePaths.Count -eq $repairPayload.Count -and
            ($candidatePaths | Select-Object -Unique).Count -eq $candidatePaths.Count -and
            -not (Compare-Object -ReferenceObject @($repairPayload | Sort-Object) -DifferenceObject @($candidatePaths | Sort-Object))
        if (-not $isV03Repair) { throw 'The existing V0.3 manifest is malformed and cannot be repaired safely.' }
        if (-not $candidateManifest.rimeAbi -or
            [string]$candidateManifest.rimeAbi.path -cne $supportedRimePath -or
            [string]$candidateManifest.rimeAbi.sha256 -cne $supportedRimeSha256 -or
            [string]$candidateManifest.rimeAbi.machine -cne 'x64' -or
            [string]$candidateManifest.rimeAbi.bridgeExport -cne $bridgeExport) {
            throw 'The existing V0.3 Rime ABI pin is invalid; refusing repair.'
        }
    }
    $isV02 = $candidateManifest.product -eq $product -and $candidateManifest.manifestVersion -eq 2 -and $candidateManifest.productVersion -eq '0.2'
    $isV02AI = $candidateManifest.product -eq $product -and $candidateManifest.manifestVersion -eq 3 -and $candidateManifest.productVersion -eq '0.2-ai'
    if (-not $isV02 -and -not $isV02AI -and -not $isV03Repair) {
        throw 'The existing manifest is not a supported V0.2, V0.2-ai, or repairable V0.3 manifest.'
    }
    $v2Manifest = $candidateManifest
    $v2BackupRootText = ([string]$v2Manifest.backupRoot).Replace('/', '\')
    if ($v2BackupRootText -notmatch '^\.rime-bilingual-backups\\(?!\.{1,2}$)[^\\]+$') { throw 'The V0.2 backup root is invalid.' }
    $v2BackupRoot = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir $v2BackupRootText) 'V0.2 backup root'
    if ((Get-NormalizedPath (Split-Path -Parent $v2BackupRoot)) -ne (Get-NormalizedPath (Join-Path $RimeUserDir '.rime-bilingual-backups'))) {
        throw 'The V0.2 backup root is not a dedicated child directory.'
    }
    $v2Paths = @($v2Manifest.files | ForEach-Object { [string]$_.relativePath })
    $previousPayload = if ($isV03Repair) {
        @($payload | Where-Object { $_ -ne 'lua\rime_bilingual_async.lua' })
    }
    else {
        @('lua\rime_bilingual.lua', 'lua\rime_bilingual_dictionary.lua', 'lua\rime_bilingual_cache.lua', 'rime_ice.custom.yaml')
    }
    if (($v2Paths | Select-Object -Unique).Count -ne $previousPayload.Count -or
        (Compare-Object -ReferenceObject @($previousPayload | Sort-Object) -DifferenceObject @($v2Paths | Sort-Object))) {
        throw 'The previous manifest payload list is invalid.'
    }
    foreach ($entry in $v2Manifest.files) {
        $managedPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$entry.relativePath)) 'V0.2 managed file'
        if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf) -or
            (Get-Sha256 $managedPath) -ne [string]$entry.sha256) {
            throw "V0.2 managed file was modified or is missing: '$($entry.relativePath)'."
        }
        if ($entry.backupRelativePath) {
            $v2BackupPath = Assert-PathInside $RimeUserDir (Join-Path $RimeUserDir ([string]$entry.backupRelativePath)) 'V0.2 original-file backup'
            if (-not $v2BackupPath.StartsWith($v2BackupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $v2BackupPath -PathType Leaf)) { throw "V0.2 backup is invalid: '$($entry.relativePath)'." }
        }
    }
    $v2DataRoots = @($v2Manifest.dataRoots)
    if ($v2DataRoots.Count -ne 1 -or [string]$v2DataRoots[0].relativePath -ne 'rime-bilingual' -or [string]$v2DataRoots[0].uninstallPolicy -ne 'retain') {
        throw 'The V0.2 retained data-root policy is invalid.'
    }
    if ($isV02AI -or $isV03Repair) {
        if ((Get-NormalizedPath ([string]$v2Manifest.aiRoot)) -ne $LocalDataRoot) { throw 'LocalDataRoot does not match the V0.2-ai manifest.' }
        $previousAIAssets = @($v2Manifest.aiAssets)
        $previousHelperPolicy = [string]$v2Manifest.helperInstallPolicy
        if ($previousHelperPolicy -eq 'managed') {
            if ($previousAIAssets.Count -ne 1 -or [string]$previousAIAssets[0].relativePath -ne 'bin\RimeTranslateHelper.exe') {
                throw 'The V0.2-ai Helper asset list is invalid.'
            }
            if (-not (Test-Path -LiteralPath $helperDestination -PathType Leaf) -or
                (Get-Sha256 $helperDestination) -ne [string]$previousAIAssets[0].sha256) {
                throw 'The V0.2-ai managed Helper was modified or is missing.'
            }
            if ($previousAIAssets[0].backupRelativePath) {
                $previousAIBackupRootText = ([string]$v2Manifest.aiBackupRoot).Replace('/', '\')
                if ($previousAIBackupRootText -notmatch '^\.rime-bilingual-backups\\[^\\]+\\ai$') {
                    throw 'The V0.2-ai Helper backup root is invalid.'
                }
                $previousAIBackupRoot = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot $previousAIBackupRootText) 'Previous Helper backup root'
                $previousHelperBackup = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot ([string]$previousAIAssets[0].backupRelativePath)) 'Previous Helper backup'
                if (-not $previousHelperBackup.StartsWith($previousAIBackupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                    -not (Test-Path -LiteralPath $previousHelperBackup -PathType Leaf)) { throw 'The V0.2-ai original Helper backup is missing or outside its dedicated root.' }
            }
            elseif ($v2Manifest.aiBackupRoot) { throw 'The V0.2-ai manifest has an unused Helper backup root.' }
        }
        elseif ($previousHelperPolicy -eq 'skipped') {
            if ($previousAIAssets.Count -ne 0) { throw 'The skipped V0.2-ai Helper policy must have no managed asset.' }
        }
        else { throw 'The V0.2-ai Helper install policy is invalid.' }
        if ($previousHelperPolicy -eq 'managed' -and $SkipHelper) {
            throw 'Cannot use -SkipHelper while upgrading a managed V0.2-ai Helper.'
        }
    }
}
foreach ($relativePath in $payload) {
    $sourcePath = if ($relativePath -eq 'rime-bilingual\native\rime_bilingual_bridge.dll') { $BridgePath } else { Assert-PathInside $ProjectRoot (Join-Path $ProjectRoot $relativePath) 'Payload source' }
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
        if ((Get-Sha256 $destinationPath) -ne $entry.sha256) {
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
elseif ($v2Manifest) {
    $backupRelativeRoot = [string]$v2Manifest.backupRoot
    foreach ($entry in $v2Manifest.files) { $legacyEntries[[string]$entry.relativePath] = $entry }
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

$operation = if ($legacyManifest) { 'Upgrade Rime Bilingual V0.1 to V0.3' } elseif ($isV03Repair) { 'Repair incomplete Rime Bilingual V0.3 installation' } elseif ($isV02AI) { 'Upgrade Rime Bilingual V0.2-ai to V0.3' } elseif ($v2Manifest) { 'Upgrade Rime Bilingual V0.2 to V0.3' } else { 'Install Rime Bilingual V0.3' }
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
$helperExisted = Test-Path -LiteralPath $helperDestination -PathType Leaf
$helperRollbackPath = Join-Path $rollbackRoot 'ai\RimeTranslateHelper.exe'
$helperBackupRelativePath = $null
$helperBackupPath = $null
$helperBackupRoot = $null
$createdHelperBackup = $false
$upgradingManagedHelper = ($isV02AI -or $isV03Repair) -and $previousHelperPolicy -eq 'managed'
if ($upgradingManagedHelper -and $previousAIAssets[0].backupRelativePath) {
    $helperBackupRelativePath = [string]$previousAIAssets[0].backupRelativePath
    $helperBackupPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot $helperBackupRelativePath) 'Existing Helper backup'
    $helperBackupRoot = Split-Path -Parent $helperBackupPath
}

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
    if (-not $SkipHelper -and $helperExisted) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $helperRollbackPath) -Force | Out-Null
        Copy-Item -LiteralPath $helperDestination -Destination $helperRollbackPath -Force
        if (-not $upgradingManagedHelper) {
            $helperBackupRelativePath = Join-Path '.rime-bilingual-backups' ((Split-Path -Leaf $backupRelativeRoot) + '\ai\RimeTranslateHelper.exe')
            $helperBackupPath = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot $helperBackupRelativePath) 'Helper backup'
            $helperBackupRoot = Split-Path -Parent $helperBackupPath
            New-Item -ItemType Directory -Path (Split-Path -Parent $helperBackupPath) -Force | Out-Null
            Copy-Item -LiteralPath $helperDestination -Destination $helperBackupPath -Force
            $createdHelperBackup = $true
        }
    }

    foreach ($relativePath in $payload) {
        $sourcePath = if ($relativePath -eq 'rime-bilingual\native\rime_bilingual_bridge.dll') { $BridgePath } else { Join-Path $ProjectRoot $relativePath }
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
            sha256 = Get-Sha256 $destinationPath
        }
    }

    & $cacheScript init -RimeRoot $RimeUserDir | Out-Null
    & $cacheScript publish -RimeRoot $RimeUserDir | Out-Null

    $aiAssets = @()
    if (-not $SkipHelper) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $helperDestination) -Force | Out-Null
        Copy-Item -LiteralPath $HelperPath -Destination $helperDestination -Force
        $aiAssets = @([pscustomobject]@{
            relativePath = 'bin\RimeTranslateHelper.exe'
            backupRelativePath = $helperBackupRelativePath
            sha256 = Get-Sha256 $helperDestination
        })
    }

    $manifest = [pscustomobject]@{
        manifestVersion = $manifestVersion
        product = $product
        productVersion = $productVersion
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        backupRoot = $backupRelativeRoot
        files = $installedFiles
        dataRoots = @([pscustomobject]@{ relativePath = 'rime-bilingual'; uninstallPolicy = 'retain' })
        aiRoot = $LocalDataRoot
        aiAssets = $aiAssets
        aiBackupRoot = $(if ($helperBackupRelativePath) { Split-Path -Parent $helperBackupRelativePath } else { $null })
        helperInstallPolicy = $(if ($SkipHelper) { 'skipped' } else { 'managed' })
        rimeAbi = [pscustomobject]@{
            path = $supportedRimePath
            sha256 = $supportedRimeSha256
            machine = 'x64'
            bridgeExport = $bridgeExport
        }
    }
    $manifestTemp = $manifestPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
    Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
    if ($legacyManifest) { Remove-Item -LiteralPath $legacyManifestPath -Force }
    $manifestPublished = $true
    try { Remove-Item -LiteralPath $rollbackRoot -Recurse -Force }
    catch { Write-Warning "Install committed, but temporary rollback data could not be removed: '$rollbackRoot'." }
    Write-Host "Rime Bilingual $productVersion installed in '$RimeUserDir'."
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
        if ($v2ManifestText) {
            try { [IO.File]::WriteAllBytes($manifestPath, $v2ManifestBytes) }
            catch { $rollbackErrors += "V0.2 manifest: $($_.Exception.Message)" }
        }
        if (-not $SkipHelper) {
            try {
                if ($helperExisted) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $helperDestination) -Force | Out-Null
                    Copy-Item -LiteralPath $helperRollbackPath -Destination $helperDestination -Force
                }
                else { Remove-Item -LiteralPath $helperDestination -Force -ErrorAction SilentlyContinue }
            }
            catch { $rollbackErrors += "Helper: $($_.Exception.Message)" }
            if ($createdHelperBackup -and $helperBackupPath) { Remove-Item -LiteralPath $helperBackupPath -Force -ErrorAction SilentlyContinue }
            if ($createdHelperBackup -and $helperBackupRoot -and (Test-Path -LiteralPath $helperBackupRoot -PathType Container)) {
                Remove-Item -LiteralPath $helperBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
                $helperBackupInstallRoot = Split-Path -Parent $helperBackupRoot
                if ((Test-Path -LiteralPath $helperBackupInstallRoot -PathType Container) -and
                    -not (Get-ChildItem -LiteralPath $helperBackupInstallRoot -Force | Select-Object -First 1)) {
                    Remove-Item -LiteralPath $helperBackupInstallRoot -Force -ErrorAction SilentlyContinue
                }
                $helperBackupNamespace = Assert-PathInside $LocalDataRoot (Join-Path $LocalDataRoot '.rime-bilingual-backups') 'Helper backup namespace'
                if ((Test-Path -LiteralPath $helperBackupNamespace -PathType Container) -and
                    -not (Get-ChildItem -LiteralPath $helperBackupNamespace -Force | Select-Object -First 1)) {
                    Remove-Item -LiteralPath $helperBackupNamespace -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if ($manifestTemp) { Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue }
        foreach ($backupPath in $createdBackupPaths) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    if ($rollbackErrors.Count -eq 0) {
        Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw $installError
    }
    throw ("Install failed: {0} Rollback was incomplete; recovery data was preserved at '{1}'. Errors: {2}" -f $installError.Exception.Message, $rollbackRoot, ($rollbackErrors -join '; '))
}
