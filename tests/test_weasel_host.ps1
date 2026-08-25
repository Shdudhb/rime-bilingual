$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $projectRoot 'scripts\install-weasel-host.ps1'
$uninstallScript = Join-Path $projectRoot 'scripts\uninstall-weasel-host.ps1'
$officialRoot = 'C:\Program Files\Rime\weasel-0.17.4'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rime-bilingual-weasel-host-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

try {
    $weaselRoot = Join-Path $testRoot 'weasel-0.17.4'
    $rimeRoot = Join-Path $testRoot 'Rime'
    New-Item -ItemType Directory -Path $weaselRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $rimeRoot -Force | Out-Null

    foreach ($name in @('WeaselServer.exe', 'WeaselDeployer.exe', 'rime.dll')) {
        Copy-Item -LiteralPath (Join-Path $officialRoot $name) -Destination (Join-Path $weaselRoot $name) -Force
    }
    $officialHash = (Get-FileHash -LiteralPath (Join-Path $weaselRoot 'WeaselServer.exe') -Algorithm SHA256).Hash
    Assert-True ($officialHash -eq 'FEF5AF4516092A1CA26E4E307D118583AD3FF5DF547A35FB66CB490FF99EF35B') 'official fixture hash must match the pin'

    $patchedFixture = Join-Path $testRoot 'WeaselServer-patched.exe'
    Copy-Item -LiteralPath (Join-Path $weaselRoot 'WeaselServer.exe') -Destination $patchedFixture -Force
    [IO.File]::AppendAllText($patchedFixture, '_rime_bilingual_refresh', [Text.Encoding]::ASCII)
    $patchedHash = (Get-FileHash -LiteralPath $patchedFixture -Algorithm SHA256).Hash
    Assert-True ($patchedHash -ne $officialHash) 'patched fixture must differ from official image'

    $installSource = Get-Content -LiteralPath $installScript -Raw
    Assert-True ($installSource -match 'Start-SupportedWeasel\s+\$serverPath') 'host install must restart the patched Weasel server'
    Assert-True ($installSource -notmatch 'WeaselDeployer|/deploy|Invoke-WeaselDeploy') 'host patch install must not invoke the GUI Weasel deployer'

    & $installScript -RimeUserDir $rimeRoot -ProjectRoot $projectRoot -WeaselDirectory $weaselRoot -PatchedWeaselServerPath $patchedFixture -DevelopmentNoProcessControl
    $manifestPath = Join-Path $rimeRoot '.rime-bilingual-weasel-host-manifest.json'
    $backupPath = Join-Path $rimeRoot '.rime-bilingual-weasel-host\official-WeaselServer.exe'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'host manifest must be published'
    Assert-True (Test-Path -LiteralPath $backupPath -PathType Leaf) 'official server backup must be retained'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $weaselRoot 'WeaselServer.exe') -Algorithm SHA256).Hash -eq $patchedHash) 'patched server must replace the fixture'
    Assert-True ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -eq $officialHash) 'backup must preserve the official image'

    & $installScript -RimeUserDir $rimeRoot -ProjectRoot $projectRoot -WeaselDirectory $weaselRoot -PatchedWeaselServerPath $patchedFixture -DevelopmentNoProcessControl
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $weaselRoot 'WeaselServer.exe') -Algorithm SHA256).Hash -eq $patchedHash) 'repeat install must be idempotent'

    & $uninstallScript -RimeUserDir $rimeRoot -DevelopmentNoProcessControl
    Assert-True (-not (Test-Path -LiteralPath $manifestPath)) 'host manifest must be removed on uninstall'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rimeRoot '.rime-bilingual-weasel-host'))) 'host backup root must be removed after successful restore'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $weaselRoot 'WeaselServer.exe') -Algorithm SHA256).Hash -eq $officialHash) 'uninstall must restore the exact official server'

    & $installScript -RimeUserDir $rimeRoot -ProjectRoot $projectRoot -WeaselDirectory $weaselRoot -PatchedWeaselServerPath $patchedFixture -DevelopmentNoProcessControl
    [IO.File]::AppendAllText((Join-Path $weaselRoot 'WeaselServer.exe'), 'tamper', [Text.Encoding]::ASCII)
    $stopped = $false
    try { & $uninstallScript -RimeUserDir $rimeRoot -DevelopmentNoProcessControl } catch { $stopped = $_.Exception.Message -match 'modified' }
    Assert-True $stopped 'uninstall must refuse a modified patched server'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'failed uninstall must keep the host manifest'

    Write-Host 'PASS: Weasel host patch install/uninstall transaction tests succeeded.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
