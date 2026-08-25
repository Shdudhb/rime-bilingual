$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $projectRoot 'scripts\install.ps1'
$uninstallScript = Join-Path $projectRoot 'scripts\uninstall.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rime-bilingual-install-test-' + [guid]::NewGuid().ToString('N'))
$helperFixture = Join-Path $testRoot 'RimeTranslateHelper.exe'
$realHelperFixture = Join-Path $projectRoot 'helper\target\release\RimeTranslateHelper.exe'
$bridgeFixture = Join-Path $projectRoot 'bridge\target\release\rime_bilingual_bridge.dll'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function Install-Test([string]$RimeRoot, [string]$AIRoot, [switch]$SkipHelper, [switch]$WhatIf) {
    & $installScript -RimeUserDir $RimeRoot -ProjectRoot $projectRoot -LocalDataRoot $AIRoot -HelperPath $helperFixture -BridgePath $bridgeFixture -SkipHelper:$SkipHelper -WhatIf:$WhatIf
}
function Uninstall-Test([string]$RimeRoot, [string]$AIRoot, [switch]$PurgeCache, [switch]$PurgeAIAssets, [switch]$WhatIf) {
    & $uninstallScript -RimeUserDir $RimeRoot -LocalDataRoot $AIRoot -PurgeCache:$PurgeCache -PurgeAIAssets:$PurgeAIAssets -WhatIf:$WhatIf
}
function Convert-ToV2Fixture([string]$RimeRoot, [string]$AIRoot) {
    Install-Test $RimeRoot $AIRoot
    $path = Join-Path $RimeRoot '.rime-bilingual-manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $manifest.manifestVersion = 2
    $manifest.productVersion = '0.2'
    $manifest.files = @($manifest.files | Where-Object { $_.relativePath -notin @('rime-bilingual\native\rime_bilingual_bridge.dll', 'lua\rime_bilingual_async.lua') })
    foreach ($name in @('aiRoot', 'aiAssets', 'aiBackupRoot', 'helperInstallPolicy', 'rimeAbi')) { $manifest.PSObject.Properties.Remove($name) }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $RimeRoot 'rime-bilingual\native\rime_bilingual_bridge.dll') -Force
    Remove-Item -LiteralPath (Join-Path $RimeRoot 'lua\rime_bilingual_async.lua') -Force
    if (Test-Path -LiteralPath $AIRoot) { Remove-Item -LiteralPath $AIRoot -Recurse -Force }
}
function Convert-ToV3Fixture([string]$RimeRoot, [string]$AIRoot) {
    Install-Test $RimeRoot $AIRoot
    $path = Join-Path $RimeRoot '.rime-bilingual-manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $manifest.manifestVersion = 3
    $manifest.productVersion = '0.2-ai'
    $manifest.files = @($manifest.files | Where-Object { $_.relativePath -notin @('rime-bilingual\native\rime_bilingual_bridge.dll', 'lua\rime_bilingual_async.lua') })
    $manifest.PSObject.Properties.Remove('rimeAbi')
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $RimeRoot 'rime-bilingual\native\rime_bilingual_bridge.dll') -Force
    Remove-Item -LiteralPath (Join-Path $RimeRoot 'lua\rime_bilingual_async.lua') -Force
}
function Convert-ToIncompleteV03Fixture([string]$RimeRoot, [string]$AIRoot) {
    Install-Test $RimeRoot $AIRoot
    $path = Join-Path $RimeRoot '.rime-bilingual-manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $manifest.files = @($manifest.files | Where-Object { $_.relativePath -ne 'lua\rime_bilingual_async.lua' })
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $RimeRoot 'lua\rime_bilingual_async.lua') -Force
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Set-Content -LiteralPath $helperFixture -Value 'helper fixture' -Encoding ASCII -NoNewline
    Assert-True (Test-Path -LiteralPath $bridgeFixture -PathType Leaf) 'bridge release fixture must be built before installer tests'
    Assert-True (Test-Path -LiteralPath $realHelperFixture -PathType Leaf) 'real Helper release fixture must be built before Windows executable-lock tests'
    $uninstallSource = Get-Content -LiteralPath $uninstallScript -Raw
    $weaselStopBlock = [regex]::Match(
        $uninstallSource,
        'function Stop-SupportedWeaselProcesses.*?(?=function Start-SupportedWeasel)',
        [Text.RegularExpressions.RegexOptions]::Singleline
    ).Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($weaselStopBlock)) 'uninstall must define the supported Weasel shutdown routine'
    Assert-True ($weaselStopBlock -match "-ArgumentList\s+'/quit'") 'Weasel shutdown must use the official /quit command'
    Assert-True ($weaselStopBlock -notmatch "-ArgumentList\s+'/quit'.*-Wait") 'Weasel /quit invocation must not block waiting for the control process to exit'
    Assert-True ($weaselStopBlock -match 'Get-WeaselBridgeOwners') 'forced Weasel cleanup must be scoped to verified bridge owners'
    Assert-True ($weaselStopBlock -match '(?m)^\s*Stop-Process\s+-Id\s+\$processId\s+-Force') 'verified bridge owners may be force-stopped after graceful /quit fails'

    foreach ($shell in @('pwsh.exe', 'powershell.exe')) {
        $shellName = [IO.Path]::GetFileNameWithoutExtension($shell)
        $wr = Join-Path $testRoot ($shellName + '-file-whatif-rime')
        $wa = Join-Path $testRoot ($shellName + '-file-whatif-ai')
        $whatIfArguments = @('-NoProfile')
        if ($shellName -eq 'powershell') { $whatIfArguments += @('-ExecutionPolicy', 'Bypass') }
        $whatIfArguments += @('-File', $installScript, '-RimeUserDir', $wr, '-LocalDataRoot', $wa, '-HelperPath', $helperFixture, '-BridgePath', $bridgeFixture, '-WhatIf')
        & $shell @whatIfArguments *> $null
        Assert-True ($LASTEXITCODE -eq 0) "$shell -File install -WhatIf must complete read-only validation"
        Assert-True (-not (Test-Path $wr) -and -not (Test-Path $wa)) "$shell -File install -WhatIf must not create install roots"

        $r = Join-Path $testRoot ($shellName + '-file-rime')
        $a = Join-Path $testRoot ($shellName + '-file-ai')
        $shellArguments = @('-NoProfile')
        if ($shellName -eq 'powershell') { $shellArguments += @('-ExecutionPolicy', 'Bypass') }
        $shellArguments += @('-File', $installScript, '-RimeUserDir', $r, '-LocalDataRoot', $a, '-HelperPath', $helperFixture, '-BridgePath', $bridgeFixture)
        & $shell @shellArguments *> $null
        Assert-True ($LASTEXITCODE -eq 0) "$shell -File install without ProjectRoot must succeed"
        $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($m.manifestVersion -eq 4) "$shell -File must resolve ProjectRoot from the script body"
        $uninstallArguments = @('-NoProfile')
        if ($shellName -eq 'powershell') { $uninstallArguments += @('-ExecutionPolicy', 'Bypass') }
        $uninstallArguments += @('-File', $uninstallScript, '-RimeUserDir', $r, '-LocalDataRoot', $a, '-PurgeCache', '-PurgeAIAssets')
        & $shell @uninstallArguments *> $null
        Assert-True ($LASTEXITCODE -eq 0) "$shell -File uninstall must succeed"
    }

    $r = Join-Path $testRoot 'whatif-rime'; $a = Join-Path $testRoot 'whatif-ai'
    Install-Test $r $a -WhatIf
    Assert-True (-not (Test-Path $r)) 'install WhatIf must not create Rime root'
    Assert-True (-not (Test-Path $a)) 'install WhatIf must not create AI root'

    $r = Join-Path $testRoot 'missing-rime'; $a = Join-Path $testRoot 'missing-ai'; $stopped = $false
    try { & $installScript -RimeUserDir $r -ProjectRoot $projectRoot -LocalDataRoot $a -HelperPath (Join-Path $testRoot 'missing.exe') } catch { $stopped = $true }
    Assert-True $stopped 'missing Helper must fail'
    Assert-True (-not (Test-Path $r)) 'missing Helper failure must be side-effect free'

    $r = Join-Path $testRoot 'skip-rime'; $a = Join-Path $testRoot 'skip-ai'
    Install-Test $r $a -SkipHelper
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.helperInstallPolicy -eq 'skipped' -and @($m.aiAssets).Count -eq 0) 'SkipHelper must be explicit in schema 4'
    Uninstall-Test $r $a -PurgeCache

    $r = Join-Path $testRoot 'fresh-rime'; $a = Join-Path $testRoot 'fresh-ai'
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    $originalPatch = "patch: { existing_user_setting: true }`r`n"
    Set-Content (Join-Path $r 'rime_ice.custom.yaml') $originalPatch -Encoding UTF8 -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $a 'bin') -Force | Out-Null
    Set-Content (Join-Path $a 'bin\RimeTranslateHelper.exe') 'pre-existing helper' -Encoding ASCII -NoNewline
    Install-Test $r $a
    $manifestPath = Join-Path $r '.rime-bilingual-manifest.json'
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 4 -and $m.productVersion -eq '0.3') 'fresh manifest must be schema 4 / V0.3'
    Assert-True (@($m.files).Count -eq 6 -and @($m.aiAssets).Count -eq 1) 'Rime payload including async Lua and bridge, and Helper must be tracked separately'
    Assert-True (Test-Path (Join-Path $r 'lua\rime_bilingual_async.lua')) 'async Lua runtime must be installed'
    Assert-True (Test-Path (Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll')) 'native bridge must be installed in the Rime data tree'
    Assert-True ($m.rimeAbi.sha256 -eq '2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B') 'manifest must record the pinned rime.dll ABI'
    Assert-True (Test-Path (Join-Path $a 'bin\RimeTranslateHelper.exe')) 'Helper must be installed under local bin'
    New-Item -ItemType Directory -Path (Join-Path $a 'models\keep') -Force | Out-Null
    Set-Content (Join-Path $a 'models\keep\model.gguf') 'retain'
    Uninstall-Test $r $a -WhatIf
    Assert-True (Test-Path $manifestPath) 'uninstall WhatIf must preserve manifest'
    Uninstall-Test $r $a
    Assert-True ((Get-Content (Join-Path $r 'rime_ice.custom.yaml') -Raw) -eq $originalPatch) 'user patch must be restored'
    Assert-True (-not (Test-Path (Join-Path $r 'lua\rime_bilingual_async.lua'))) 'uninstall must remove a newly managed async Lua runtime'
    Assert-True ((Get-Content (Join-Path $a 'bin\RimeTranslateHelper.exe') -Raw) -eq 'pre-existing helper') 'default uninstall must restore a pre-existing Helper'
    Assert-True (Test-Path (Join-Path $a 'models\keep\model.gguf')) 'default uninstall must retain model/runtime'
    Assert-True (Test-Path (Join-Path $r 'rime-bilingual\translations.db')) 'default uninstall must retain cache'

    $r = Join-Path $testRoot 'v2-rime'; $a = Join-Path $testRoot 'v2-ai'
    Convert-ToV2Fixture $r $a
    $db = Join-Path $r 'rime-bilingual\translations.db'; $snap = Join-Path $r 'rime-bilingual\cache_snapshot.lua'
    $dbHash = (Get-FileHash $db -Algorithm SHA256).Hash; $snapHash = (Get-FileHash $snap -Algorithm SHA256).Hash
    Install-Test $r $a
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 4 -and $m.productVersion -eq '0.3') 'V0.2 must upgrade additively'
    Assert-True ((Get-FileHash $db -Algorithm SHA256).Hash -eq $dbHash) 'upgrade must preserve database'
    Assert-True ((Get-FileHash $snap -Algorithm SHA256).Hash -eq $snapHash) 'upgrade must preserve snapshot'
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'v3-rime'; $a = Join-Path $testRoot 'v3-ai'
    Convert-ToV3Fixture $r $a
    $db = Join-Path $r 'rime-bilingual\translations.db'; $snap = Join-Path $r 'rime-bilingual\cache_snapshot.lua'
    $helper = Join-Path $a 'bin\RimeTranslateHelper.exe'
    $dbHash = (Get-FileHash $db -Algorithm SHA256).Hash; $snapHash = (Get-FileHash $snap -Algorithm SHA256).Hash
    Install-Test $r $a
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 4 -and $m.productVersion -eq '0.3') 'schema 3 V0.2-ai must upgrade to schema 4 V0.3'
    Assert-True ((Get-FileHash $db -Algorithm SHA256).Hash -eq $dbHash) 'V0.2-ai upgrade must preserve database'
    Assert-True ((Get-FileHash $snap -Algorithm SHA256).Hash -eq $snapHash) 'V0.2-ai upgrade must preserve snapshot'
    Assert-True (Test-Path $helper) 'V0.2-ai upgrade must retain and track Helper'
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'repair-v03-rime'; $a = Join-Path $testRoot 'repair-v03-ai'
    Convert-ToIncompleteV03Fixture $r $a
    $db = Join-Path $r 'rime-bilingual\translations.db'; $snap = Join-Path $r 'rime-bilingual\cache_snapshot.lua'
    $dbHash = (Get-FileHash $db -Algorithm SHA256).Hash; $snapHash = (Get-FileHash $snap -Algorithm SHA256).Hash
    Install-Test $r $a
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 4 -and $m.productVersion -eq '0.3' -and @($m.files).Count -eq 6) 'incomplete schema 4 V0.3 must repair to the complete six-file payload'
    Assert-True (Test-Path (Join-Path $r 'lua\rime_bilingual_async.lua')) 'same-version repair must install async Lua runtime'
    Assert-True ((Get-FileHash $db -Algorithm SHA256).Hash -eq $dbHash) 'same-version repair must preserve database'
    Assert-True ((Get-FileHash $snap -Algorithm SHA256).Hash -eq $snapHash) 'same-version repair must preserve snapshot'
    $alreadyStopped = $false; try { Install-Test $r $a } catch { $alreadyStopped = $_.Exception.Message -match 'already installed' }
    Assert-True $alreadyStopped 'complete V0.3 must still refuse duplicate install'
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'tamper-rime'; $a = Join-Path $testRoot 'tamper-ai'
    Convert-ToV3Fixture $r $a
    Add-Content (Join-Path $r 'lua\rime_bilingual.lua') '-- user modification'
    $stopped = $false; try { Install-Test $r $a } catch { $stopped = $true }
    Assert-True $stopped 'upgrade must refuse modified V0.2-ai payload'
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 3) 'tampered upgrade must retain V0.2-ai manifest'

    $r = Join-Path $testRoot 'invalid-bridge-rime'; $a = Join-Path $testRoot 'invalid-bridge-ai'; $stopped = $false
    try { & $installScript -RimeUserDir $r -ProjectRoot $projectRoot -LocalDataRoot $a -HelperPath $helperFixture -BridgePath $helperFixture } catch { $stopped = $true }
    Assert-True $stopped 'installer must reject a non-PE bridge before mutation'
    Assert-True (-not (Test-Path $r)) 'invalid bridge failure must be side-effect free'

    $r = Join-Path $testRoot 'helper-tamper-rime'; $a = Join-Path $testRoot 'helper-tamper-ai'
    Install-Test $r $a
    Add-Content (Join-Path $a 'bin\RimeTranslateHelper.exe') 'tampered'
    $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
    Assert-True $stopped 'uninstall must refuse a modified managed Helper'
    Copy-Item $helperFixture (Join-Path $a 'bin\RimeTranslateHelper.exe') -Force
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'bridge-tamper-rime'; $a = Join-Path $testRoot 'bridge-tamper-ai'
    Install-Test $r $a
    Add-Content (Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll') 'tampered'
    $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
    Assert-True $stopped 'uninstall must refuse a modified managed bridge'
    Copy-Item $bridgeFixture (Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll') -Force
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'async-tamper-rime'; $a = Join-Path $testRoot 'async-tamper-ai'
    Install-Test $r $a
    Add-Content (Join-Path $r 'lua\rime_bilingual_async.lua') '-- tampered'
    $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
    Assert-True $stopped 'uninstall must refuse a modified managed async Lua runtime'
    Copy-Item (Join-Path $projectRoot 'lua\rime_bilingual_async.lua') (Join-Path $r 'lua\rime_bilingual_async.lua') -Force
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'pinned-rime'; $a = Join-Path $testRoot 'pinned-ai'
    Install-Test $r $a
    $manifestPath = Join-Path $r '.rime-bilingual-manifest.json'
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $beforeHashes = @{}
    foreach ($entry in $m.files) { $beforeHashes[[string]$entry.relativePath] = (Get-FileHash (Join-Path $r ([string]$entry.relativePath)) -Algorithm SHA256).Hash }
    $bridgeInstalled = Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll'
    $pin = [IO.File]::Open($bridgeInstalled, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
        Assert-True $stopped 'locked bridge must stop uninstall during the zero-mutation preflight'
        Assert-True (Test-Path $manifestPath) 'locked bridge failure must retain manifest'
        foreach ($entry in $m.files) {
            $path = Join-Path $r ([string]$entry.relativePath)
            Assert-True ((Test-Path $path -PathType Leaf) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $beforeHashes[[string]$entry.relativePath]) 'locked bridge failure must leave every managed payload unchanged'
        }
    }
    finally { $pin.Dispose() }
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'running-helper-rime'; $a = Join-Path $testRoot 'running-helper-ai'
    & $installScript -RimeUserDir $r -ProjectRoot $projectRoot -LocalDataRoot $a -HelperPath $realHelperFixture -BridgePath $bridgeFixture *> $null
    $manifestPath = Join-Path $r '.rime-bilingual-manifest.json'
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $beforeHashes = @{}
    foreach ($entry in $m.files) { $beforeHashes[[string]$entry.relativePath] = (Get-FileHash (Join-Path $r ([string]$entry.relativePath)) -Algorithm SHA256).Hash }
    $installedHelper = Join-Path $a 'bin\RimeTranslateHelper.exe'
    $db = Join-Path $r 'rime-bilingual\translations.db'
    $unrelatedRoot = Join-Path $testRoot 'unrelated-helper-process'
    New-Item -ItemType Directory -Path $unrelatedRoot -Force | Out-Null
    $unrelatedHelper = Join-Path $unrelatedRoot 'RimeTranslateHelper.exe'
    Copy-Item -LiteralPath $realHelperFixture -Destination $unrelatedHelper -Force
    $managedHelperProcess = $null
    $unrelatedHelperProcess = $null
    try {
        $managedHelperProcess = Start-Process -FilePath $installedHelper -ArgumentList @('--bind', '127.0.0.1:0', '--cache-path', $db) -PassThru -WindowStyle Hidden
        $unrelatedHelperProcess = Start-Process -FilePath $unrelatedHelper -ArgumentList @('--bind', '127.0.0.1:0', '--cache-path', $db) -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 600
        Assert-True ($null -ne (Get-Process -Id $managedHelperProcess.Id -ErrorAction SilentlyContinue)) 'managed real Helper fixture must be running before uninstall'
        Assert-True ($null -ne (Get-Process -Id $unrelatedHelperProcess.Id -ErrorAction SilentlyContinue)) 'unrelated same-name Helper fixture must be running before uninstall'

        $managedRow = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $managedHelperProcess.Id)
        Assert-True ([IO.Path]::GetFullPath([string]$managedRow.ExecutablePath) -eq [IO.Path]::GetFullPath($installedHelper)) 'running managed Helper must originate from the exact installed path'

        Uninstall-Test $r $a -WhatIf
        Assert-True ($null -ne (Get-Process -Id $managedHelperProcess.Id -ErrorAction SilentlyContinue)) 'uninstall WhatIf must not stop the managed Helper process'

        $bridgeInstalled = Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll'
        $pin = [IO.File]::Open($bridgeInstalled, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
            Assert-True $stopped 'a locked Rime bridge must abort before the managed Helper is stopped'
            Assert-True ($null -ne (Get-Process -Id $managedHelperProcess.Id -ErrorAction SilentlyContinue)) 'locked bridge failure must leave the managed Helper running'
            Assert-True (Test-Path $manifestPath) 'locked bridge failure with running Helper must retain manifest'
            foreach ($entry in $m.files) {
                $path = Join-Path $r ([string]$entry.relativePath)
                Assert-True ((Test-Path $path -PathType Leaf) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $beforeHashes[[string]$entry.relativePath]) 'locked bridge failure with running Helper must leave every Rime payload unchanged'
            }
        }
        finally { $pin.Dispose() }

        Uninstall-Test $r $a
        Assert-True ($null -eq (Get-Process -Id $managedHelperProcess.Id -ErrorAction SilentlyContinue)) 'uninstall must stop the exact managed Helper before removing its executable'
        Assert-True ($null -ne (Get-Process -Id $unrelatedHelperProcess.Id -ErrorAction SilentlyContinue)) 'uninstall must not stop an unrelated same-name Helper from another path'
        Assert-True (-not (Test-Path $manifestPath)) 'running-Helper uninstall must commit successfully after the exact Helper is stopped'
        Assert-True (-not (Test-Path $installedHelper)) 'newly managed Helper executable must be removed after it is stopped'
    }
    finally {
        if ($managedHelperProcess) { Stop-Process -Id $managedHelperProcess.Id -Force -ErrorAction SilentlyContinue }
        if ($unrelatedHelperProcess) { Stop-Process -Id $unrelatedHelperProcess.Id -Force -ErrorAction SilentlyContinue }
    }

    $r = Join-Path $testRoot 'rollback-uninstall-rime'; $a = Join-Path $testRoot 'rollback-uninstall-ai'
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    $rollbackOriginalPatch = "patch: { rollback_original: true }`r`n"
    Set-Content (Join-Path $r 'rime_ice.custom.yaml') $rollbackOriginalPatch -Encoding UTF8 -NoNewline
    Install-Test $r $a
    $manifestPath = Join-Path $r '.rime-bilingual-manifest.json'
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $patchEntry = @($m.files | Where-Object { $_.relativePath -eq 'rime_ice.custom.yaml' })[0]
    $lockedBackup = Join-Path $r ([string]$patchEntry.backupRelativePath)
    $pin = [IO.File]::Open($lockedBackup, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $stopped = $false; try { Uninstall-Test $r $a } catch { $stopped = $true }
        Assert-True $stopped 'a post-preflight restore failure must abort uninstall'
        Assert-True (Test-Path $manifestPath) 'transaction rollback must retain manifest'
        foreach ($entry in $m.files) {
            $path = Join-Path $r ([string]$entry.relativePath)
            Assert-True ((Test-Path $path -PathType Leaf) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq [string]$entry.sha256) 'transaction rollback must restore every managed payload'
        }
    }
    finally { $pin.Dispose() }
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets
    Assert-True ((Get-Content (Join-Path $r 'rime_ice.custom.yaml') -Raw) -eq $rollbackOriginalPatch) 'retry after rollback must restore the original user patch'

    $r = Join-Path $testRoot 'resume-rime'; $a = Join-Path $testRoot 'resume-ai'
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    $resumeOriginalPatch = "patch: { resume_original: true }`r`n"
    Set-Content (Join-Path $r 'rime_ice.custom.yaml') $resumeOriginalPatch -Encoding UTF8 -NoNewline
    Install-Test $r $a
    Remove-Item (Join-Path $r 'lua\rime_bilingual.lua') -Force
    Remove-Item (Join-Path $r 'lua\rime_bilingual_async.lua') -Force
    Remove-Item (Join-Path $r 'rime_ice.custom.yaml') -Force
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets
    Assert-True (-not (Test-Path (Join-Path $r '.rime-bilingual-manifest.json'))) 'interrupted uninstall resume must remove manifest on success'
    Assert-True ((Get-Content (Join-Path $r 'rime_ice.custom.yaml') -Raw) -eq $resumeOriginalPatch) 'interrupted uninstall resume must restore a missing backed-up user file'
    Assert-True (-not (Test-Path (Join-Path $r 'rime-bilingual\native\rime_bilingual_bridge.dll'))) 'interrupted uninstall resume must remove remaining managed bridge'

    $r = Join-Path $testRoot 'rollback-rime'; $a = Join-Path $testRoot 'rollback-ai'
    Convert-ToV2Fixture $r $a
    New-Item -ItemType Directory -Path $a -Force | Out-Null
    Set-Content (Join-Path $a 'bin') 'blocks helper directory' -Encoding ASCII
    $stopped = $false; try { Install-Test $r $a } catch { $stopped = $true }
    Assert-True $stopped 'Helper deployment failure must stop upgrade'
    $m = Get-Content (Join-Path $r '.rime-bilingual-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($m.manifestVersion -eq 2) 'rollback must restore V0.2 manifest'
    Assert-True ((Get-Content (Join-Path $a 'bin') -Raw).Trim() -eq 'blocks helper directory') 'rollback must preserve unrelated AI content'

    $r = Join-Path $testRoot 'pid-rime'; $a = Join-Path $testRoot 'pid-ai'
    Install-Test $r $a
    $fakeRuntime = Join-Path $a 'runtime\fake\llama-server.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fakeRuntime) -Force | Out-Null
    Set-Content $fakeRuntime 'not the current process'
    @{ pid = $PID; executable_path = $fakeRuntime } | ConvertTo-Json | Set-Content (Join-Path $a 'llama-server.pid.json') -Encoding UTF8
    @{ runtime_path = $fakeRuntime; model_path = (Join-Path $a 'models\fake.gguf'); port = 18080 } | ConvertTo-Json | Set-Content (Join-Path $a 'config.json') -Encoding UTF8
    $stopped = $false; try { Uninstall-Test $r $a -PurgeAIAssets } catch { $stopped = $true }
    Assert-True $stopped 'AI purge must refuse a PID identity mismatch'
    Assert-True (Test-Path (Join-Path $r '.rime-bilingual-manifest.json')) 'PID mismatch must fail before uninstall mutations'
    Remove-Item (Join-Path $a 'llama-server.pid.json') -Force
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets

    $r = Join-Path $testRoot 'purge-rime'; $a = Join-Path $testRoot 'purge-ai'
    Install-Test $r $a
    New-Item -ItemType Directory -Path (Join-Path $a 'runtime\test') -Force | Out-Null
    Set-Content (Join-Path $a 'runtime\test\llama-server.exe') 'runtime'
    @{ pid = 2147483000; executable_path = (Join-Path $a 'runtime\test\llama-server.exe') } | ConvertTo-Json | Set-Content (Join-Path $a 'llama-server.pid.json') -Encoding UTF8
    Uninstall-Test $r $a -PurgeCache -PurgeAIAssets
    Assert-True (-not (Test-Path (Join-Path $r 'rime-bilingual'))) 'PurgeCache must remove cache root'
    Assert-True (-not (Test-Path $a)) 'PurgeAIAssets must remove dedicated AI root'

    Write-Host 'PASS: V0.3 installer/upgrade/uninstall safety checks succeeded.'
}
finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
