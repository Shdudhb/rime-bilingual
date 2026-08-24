$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $projectRoot 'scripts\install.ps1'
$uninstallScript = Join-Path $projectRoot 'scripts\uninstall.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rime-bilingual-install-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-LegacyFixture([string]$RimeRoot) {
    New-Item -ItemType Directory -Path (Join-Path $RimeRoot 'lua') -Force | Out-Null
    $backupRoot = '.rime-bilingual-backups\legacy-fixture'
    $originalPatch = "patch: { original_setting: true }`r`n"
    $legacyFiles = @(
        [pscustomobject]@{ relativePath = 'lua\rime_bilingual.lua'; content = "return { func = function(input) return input end }`r`n"; backupRelativePath = $null },
        [pscustomobject]@{ relativePath = 'lua\rime_bilingual_dictionary.lua'; content = "return {}`r`n"; backupRelativePath = $null },
        [pscustomobject]@{ relativePath = 'rime_ice.custom.yaml'; content = "patch: { legacy_filter: true }`r`n"; backupRelativePath = "$backupRoot\rime_ice.custom.yaml" }
    )
    $entries = @()
    foreach ($file in $legacyFiles) {
        $path = Join-Path $RimeRoot $file.relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value $file.content -Encoding UTF8 -NoNewline
        if ($file.backupRelativePath) {
            $backupPath = Join-Path $RimeRoot $file.backupRelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Set-Content -LiteralPath $backupPath -Value $originalPatch -Encoding UTF8 -NoNewline
        }
        $entries += [pscustomobject]@{
            relativePath = $file.relativePath
            backupRelativePath = $file.backupRelativePath
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
    $manifest = [pscustomobject]@{
        product = 'rime-bilingual'
        version = '0.1'
        backupRoot = $backupRoot
        files = $entries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RimeRoot '.rime-bilingual-v0.1-manifest.json') -Encoding UTF8
    $originalPatch
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $whatIfRoot = Join-Path $testRoot 'WhatIfRime'
    & $installScript -RimeUserDir $whatIfRoot -ProjectRoot $projectRoot -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $whatIfRoot)) 'install -WhatIf must not create the Rime root'

    $freshRoot = Join-Path $testRoot 'FreshRime'
    New-Item -ItemType Directory -Path $freshRoot -Force | Out-Null
    $originalPatch = "patch: { existing_user_setting: true }`r`n"
    Set-Content -LiteralPath (Join-Path $freshRoot 'rime_ice.custom.yaml') -Value $originalPatch -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $freshRoot 'unrelated.custom.yaml') -Value 'keep me' -Encoding UTF8
    & $installScript -RimeUserDir $freshRoot -ProjectRoot $projectRoot

    $manifestPath = Join-Path $freshRoot '.rime-bilingual-manifest.json'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'V0.2 manifest should exist'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($manifest.manifestVersion -eq 2 -and $manifest.productVersion -eq '0.2') 'manifest should identify V0.2'
    Assert-True ($manifest.files.Count -eq 4) 'manifest should track all four runtime payload files'
    Assert-True (Test-Path -LiteralPath (Join-Path $freshRoot 'rime-bilingual\translations.db')) 'install should initialize SQLite'
    Assert-True (Test-Path -LiteralPath (Join-Path $freshRoot 'rime-bilingual\cache_snapshot.lua')) 'install should publish a snapshot'

    & $uninstallScript -RimeUserDir $freshRoot -WhatIf
    Assert-True (Test-Path -LiteralPath $manifestPath) 'uninstall -WhatIf must preserve the manifest'

    $filterPath = Join-Path $freshRoot 'lua\rime_bilingual.lua'
    Add-Content -LiteralPath $filterPath -Value '-- user edit'
    $stopped = $false
    try { & $uninstallScript -RimeUserDir $freshRoot } catch { $stopped = $true }
    Assert-True $stopped 'uninstall must refuse to remove a modified managed file'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'lua\rime_bilingual.lua') -Destination $filterPath -Force

    & $uninstallScript -RimeUserDir $freshRoot
    Assert-True (-not (Test-Path -LiteralPath $manifestPath)) 'manifest should be removed after uninstall'
    Assert-True ((Get-Content -LiteralPath (Join-Path $freshRoot 'rime_ice.custom.yaml') -Raw) -eq $originalPatch) 'pre-existing patch should be restored'
    Assert-True (Test-Path -LiteralPath (Join-Path $freshRoot 'rime-bilingual\translations.db')) 'cache database should be retained by default'
    Assert-True (Test-Path -LiteralPath (Join-Path $freshRoot 'rime-bilingual\cache_snapshot.lua')) 'snapshot should be retained by default'

    # Force a failure after payload replacement: a file where the cache data
    # directory must be makes cache initialization fail. The installer must
    # restore the original patch and remove all newly copied payloads.
    $rollbackRoot = Join-Path $testRoot 'RollbackRime'
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    $rollbackOriginalPatch = "patch: { rollback_original: true }`r`n"
    Set-Content -LiteralPath (Join-Path $rollbackRoot 'rime_ice.custom.yaml') -Value $rollbackOriginalPatch -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $rollbackRoot 'rime-bilingual') -Value 'blocks cache directory creation' -Encoding UTF8
    $midInstallStopped = $false
    try { & $installScript -RimeUserDir $rollbackRoot -ProjectRoot $projectRoot } catch { $midInstallStopped = $true }
    Assert-True $midInstallStopped 'cache initialization failure should stop install after payload replacement'
    Assert-True ((Get-Content -LiteralPath (Join-Path $rollbackRoot 'rime_ice.custom.yaml') -Raw) -eq $rollbackOriginalPatch) 'mid-install failure should restore the original patch'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'lua\rime_bilingual.lua'))) 'mid-install failure should remove the new filter'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot '.rime-bilingual-manifest.json'))) 'mid-install failure should not leave a manifest'
    Assert-True ((Get-Content -LiteralPath (Join-Path $rollbackRoot 'rime-bilingual') -Raw).Trim() -eq 'blocks cache directory creation') 'mid-install failure should preserve the unrelated blocking file'

    $purgeRoot = Join-Path $testRoot 'PurgeRime'
    & $installScript -RimeUserDir $purgeRoot -ProjectRoot $projectRoot
    & $uninstallScript -RimeUserDir $purgeRoot -PurgeCache
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $purgeRoot 'rime-bilingual'))) '-PurgeCache should remove only the cache data root'

    $legacyRoot = Join-Path $testRoot 'LegacyRime'
    $legacyOriginalPatch = New-LegacyFixture $legacyRoot
    & $installScript -RimeUserDir $legacyRoot -ProjectRoot $projectRoot
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyRoot '.rime-bilingual-v0.1-manifest.json'))) 'upgrade should remove the legacy manifest'
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyRoot '.rime-bilingual-manifest.json')) 'upgrade should publish the V0.2 manifest'
    $upgradedManifest = Get-Content -LiteralPath (Join-Path $legacyRoot '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    $patchEntry = $upgradedManifest.files | Where-Object { $_.relativePath -eq 'rime_ice.custom.yaml' }
    Assert-True ($patchEntry.backupRelativePath -like '*legacy-fixture*') 'upgrade must preserve the pre-V0.1 backup reference'
    & $uninstallScript -RimeUserDir $legacyRoot
    Assert-True ((Get-Content -LiteralPath (Join-Path $legacyRoot 'rime_ice.custom.yaml') -Raw) -eq $legacyOriginalPatch) 'uninstall after upgrade should restore the pre-V0.1 patch'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyRoot 'lua\rime_bilingual.lua'))) 'uninstall after upgrade should remove the managed filter'

    $tamperedLegacyRoot = Join-Path $testRoot 'TamperedLegacyRime'
    $null = New-LegacyFixture $tamperedLegacyRoot
    Add-Content -LiteralPath (Join-Path $tamperedLegacyRoot 'lua\rime_bilingual.lua') -Value '-- changed'
    $upgradeStopped = $false
    try { & $installScript -RimeUserDir $tamperedLegacyRoot -ProjectRoot $projectRoot } catch { $upgradeStopped = $true }
    Assert-True $upgradeStopped 'upgrade must refuse a modified V0.1 payload'
    Assert-True (Test-Path -LiteralPath (Join-Path $tamperedLegacyRoot '.rime-bilingual-v0.1-manifest.json')) 'failed upgrade must preserve the legacy manifest'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tamperedLegacyRoot '.rime-bilingual-manifest.json'))) 'failed upgrade must not publish V0.2 manifest'

    $unsafeLegacyRoot = Join-Path $testRoot 'UnsafeLegacyRime'
    $null = New-LegacyFixture $unsafeLegacyRoot
    $unsafeManifestPath = Join-Path $unsafeLegacyRoot '.rime-bilingual-v0.1-manifest.json'
    $unsafeManifest = Get-Content -LiteralPath $unsafeManifestPath -Raw | ConvertFrom-Json
    $unsafeManifest.backupRoot = '.'
    $unsafeManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $unsafeManifestPath -Encoding UTF8
    $unsafeStopped = $false
    try { & $installScript -RimeUserDir $unsafeLegacyRoot -ProjectRoot $projectRoot } catch { $unsafeStopped = $true }
    Assert-True $unsafeStopped 'upgrade must reject a backup root that could target the Rime root'

    $interruptedRoot = Join-Path $testRoot 'InterruptedRime'
    & $installScript -RimeUserDir $interruptedRoot -ProjectRoot $projectRoot
    $validInterruptedManifestText = Get-Content -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-manifest.json') -Raw
    $interruptedLegacy = [pscustomobject]@{ product = 'rime-bilingual'; version = '0.1'; backupRoot = '.rime-bilingual-backups\interrupted'; files = @() }
    $interruptedLegacy | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-v0.1-manifest.json') -Encoding UTF8
    $invalidInterruptedManifest = $validInterruptedManifestText | ConvertFrom-Json
    $invalidInterruptedManifest.files = @()
    $invalidInterruptedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-manifest.json') -Encoding UTF8
    $invalidInterruptedStopped = $false
    try { & $installScript -RimeUserDir $interruptedRoot -ProjectRoot $projectRoot } catch { $invalidInterruptedStopped = $true }
    Assert-True $invalidInterruptedStopped 'interrupted recovery must reject an incomplete V0.2 payload list'
    Assert-True (Test-Path -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-v0.1-manifest.json')) 'invalid interrupted recovery must preserve the legacy manifest'
    Set-Content -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-manifest.json') -Value $validInterruptedManifestText -Encoding UTF8 -NoNewline
    & $installScript -RimeUserDir $interruptedRoot -ProjectRoot $projectRoot
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-v0.1-manifest.json'))) 'rerun should finalize a verified interrupted manifest migration'
    Assert-True (Test-Path -LiteralPath (Join-Path $interruptedRoot '.rime-bilingual-manifest.json')) 'interrupted migration recovery should retain V0.2 manifest'
    & $uninstallScript -RimeUserDir $interruptedRoot -PurgeCache

    $tamperedV2Root = Join-Path $testRoot 'TamperedV2Rime'
    & $installScript -RimeUserDir $tamperedV2Root -ProjectRoot $projectRoot
    $tamperedV2ManifestPath = Join-Path $tamperedV2Root '.rime-bilingual-manifest.json'
    $validV2ManifestText = Get-Content -LiteralPath $tamperedV2ManifestPath -Raw
    $tamperedV2Manifest = $validV2ManifestText | ConvertFrom-Json
    $tamperedV2Manifest.backupRoot = '.rime-bilingual-backups\.'
    $tamperedV2Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tamperedV2ManifestPath -Encoding UTF8
    $tamperedV2Stopped = $false
    try { & $uninstallScript -RimeUserDir $tamperedV2Root } catch { $tamperedV2Stopped = $true }
    Assert-True $tamperedV2Stopped 'uninstall must reject a manifest backup root outside the dedicated backup namespace'
    Assert-True (Test-Path -LiteralPath (Join-Path $tamperedV2Root 'lua\rime_bilingual.lua')) 'rejected tampered manifest must not remove managed payloads'
    Set-Content -LiteralPath $tamperedV2ManifestPath -Value $validV2ManifestText -Encoding UTF8 -NoNewline
    & $uninstallScript -RimeUserDir $tamperedV2Root -PurgeCache

    Write-Host 'PASS: V0.2 fresh install, V0.1 upgrade, interrupted migration recovery, safe uninstall, retained cache, purge, and tamper checks succeeded.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
