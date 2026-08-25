$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $projectRoot 'deployer\Cargo.toml'
$exe = Join-Path $projectRoot 'deployer\target\release\RimeBilingualDeploy.exe'
$rime = 'C:\Program Files\Rime\weasel-0.17.4\rime.dll'
$shared = 'C:\Program Files\Rime\weasel-0.17.4\data'
$user = Join-Path $env:APPDATA 'Rime'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

& cargo test --manifest-path $manifest
if ($LASTEXITCODE -ne 0) { throw 'deployer Rust tests failed.' }

& cargo build --manifest-path $manifest --release
if ($LASTEXITCODE -ne 0) { throw 'deployer release build failed.' }
Assert-True (Test-Path -LiteralPath $exe -PathType Leaf) 'release deployer must exist'

$before = if (Test-Path -LiteralPath (Join-Path $user 'build\rime_ice.schema.yaml') -PathType Leaf) {
    (Get-FileHash -LiteralPath (Join-Path $user 'build\rime_ice.schema.yaml') -Algorithm SHA256).Hash
} else { $null }

& $exe --rime-dll $rime --shared-data-dir $shared --user-data-dir $user --dry-run | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'dry-run validation must succeed against the pinned live Rime ABI'

$after = if (Test-Path -LiteralPath (Join-Path $user 'build\rime_ice.schema.yaml') -PathType Leaf) {
    (Get-FileHash -LiteralPath (Join-Path $user 'build\rime_ice.schema.yaml') -Algorithm SHA256).Hash
} else { $null }
Assert-True ($before -eq $after) 'dry-run must not mutate the live compiled schema'

$tempUser = Join-Path ([IO.Path]::GetTempPath()) ('rime-bilingual-headless-deploy-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempUser -Force | Out-Null
    # Mirror source/configuration material only. Deliberately exclude userdb,
    # sync data, the live build directory, cache data, and local manifests.
    Get-ChildItem -LiteralPath $user -File | Where-Object {
        $_.Extension -in @('.yaml', '.txt') -and $_.Name -ne 'installation.yaml' -and $_.Name -ne 'user.yaml'
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tempUser $_.Name)
    }
    foreach ($directoryName in @('cn_dicts', 'en_dicts', 'opencc', 'lua')) {
        $sourceDirectory = Join-Path $user $directoryName
        if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
            Copy-Item -LiteralPath $sourceDirectory -Destination (Join-Path $tempUser $directoryName) -Recurse
        }
    }

    & $exe --rime-dll $rime --shared-data-dir $shared --user-data-dir $tempUser | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'isolated headless workspace deployment must succeed'
    $compiledSchema = Join-Path $tempUser 'build\rime_ice.schema.yaml'
    Assert-True (Test-Path -LiteralPath $compiledSchema -PathType Leaf) 'isolated deployment must compile rime_ice.schema.yaml'
    $compiledText = Get-Content -LiteralPath $compiledSchema -Raw
    Assert-True ($compiledText -match 'lua_filter@\*rime_bilingual') 'compiled schema must contain the bilingual filter'
    Assert-True ($compiledText -match 'lua_processor@\*rime_bilingual_async') 'compiled schema must contain the async processor'
    Assert-True ($compiledText -match '(?m)^rime_bilingual:') 'compiled schema must contain the bilingual configuration block'
}
finally {
    if (Test-Path -LiteralPath $tempUser -PathType Container) {
        Remove-Item -LiteralPath $tempUser -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS: headless deployer build/ABI/isolated deployment tests succeeded.'
