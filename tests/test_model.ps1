[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\model.ps1'
$script:Failures = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:Failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
    else { Write-Host "PASS: $Message" -ForegroundColor Green }
}

function Assert-Throws([scriptblock]$Operation, [string]$Pattern, [string]$Message) {
    try { & $Operation; $script:Failures++; Write-Host "FAIL: $Message (did not throw)" -ForegroundColor Red }
    catch {
        if ($_.Exception.Message -match $Pattern) { Write-Host "PASS: $Message" -ForegroundColor Green }
        else { $script:Failures++; Write-Host "FAIL: $Message ($($_.Exception.Message))" -ForegroundColor Red }
    }
}

$oldTestMode = $env:RIME_BILINGUAL_MODEL_TEST_MODE
$env:RIME_BILINGUAL_MODEL_TEST_MODE = '1'
try { . $scriptPath -Action status } finally { $env:RIME_BILINGUAL_MODEL_TEST_MODE = $oldTestMode }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('rime-bilingual-model-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $payload = Join-Path $tempRoot 'payload.bin'
    [IO.File]::WriteAllBytes($payload, [byte[]](1, 2, 3, 4, 5))
    $hash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True (Test-FileIntegrity $payload 5 $hash) 'integrity accepts exact size and hash'
    Assert-True (-not (Test-FileIntegrity $payload 4 $hash)) 'integrity rejects wrong size'
    Assert-True (-not (Test-FileIntegrity $payload 5 ('0' * 64))) 'integrity rejects bad hash'

    $downloadSource = Join-Path $tempRoot 'mock-source.bin'
    [IO.File]::WriteAllBytes($downloadSource, [byte[]](9, 8, 7))
    $downloadHash = (Get-FileHash -LiteralPath $downloadSource -Algorithm SHA256).Hash.ToLowerInvariant()
    function Invoke-AssetDownload([string]$Uri, [string]$Destination, [string]$BearerToken) {
        if ($Uri -ne 'https://example.invalid/asset') { throw 'unexpected mock URL' }
        if ($BearerToken -ne 'secret-test-token') { throw 'mock token was not passed privately' }
        Copy-Item -LiteralPath $downloadSource -Destination $Destination
    }
    $downloadDestination = Join-Path $tempRoot 'downloaded.bin'
    $mockAsset = @{ Url = 'https://example.invalid/asset'; FileName = 'asset'; Size = [int64]3; Sha256 = $downloadHash }
    Receive-VerifiedAsset $mockAsset $downloadDestination 'secret-test-token'
    Assert-True (Test-FileIntegrity $downloadDestination 3 $downloadHash) 'mock download is verified and atomically placed'
    Receive-VerifiedAsset $mockAsset $downloadDestination 'secret-test-token'
    Assert-True (Test-FileIntegrity $downloadDestination 3 $downloadHash) 'atomic placement replaces an existing verified asset'

    $badDestination = Join-Path $tempRoot 'bad.bin'
    $badAsset = @{ Url = 'https://example.invalid/asset'; FileName = 'asset'; Size = [int64]3; Sha256 = ('0' * 64) }
    Assert-Throws { Receive-VerifiedAsset $badAsset $badDestination 'secret-test-token' } 'failed size or SHA-256' 'bad download hash is rejected'
    Assert-True (-not (Test-Path -LiteralPath $badDestination)) 'bad download is never installed'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '.bad.bin.*.tmp').Count -eq 0) 'bad download temp file is removed'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $badZip = Join-Path $tempRoot 'traversal.zip'
    $archive = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('../escaped.txt')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write('escape') } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
    $extractRoot = Join-Path $tempRoot 'extract'
    Assert-Throws { Expand-ZipSafely $badZip $extractRoot } 'escapes destination' 'zip traversal is rejected'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'escaped.txt'))) 'zip traversal writes nothing outside destination'

    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True ($scriptText -match "--host', '127\.0\.0\.1'") 'start arguments force IPv4 loopback binding'
    Assert-True ($scriptText -match "--model'") 'start arguments include configured model path'
    Assert-True ($scriptText -match "--ctx-size'") 'start arguments include context size'
    Assert-True ($scriptText -notmatch '0\.0\.0\.0') 'manager has no wildcard bind default'

    $fakeExe = Join-Path $tempRoot 'llama-server.exe'
    [IO.File]::WriteAllText($fakeExe, 'not executable')
    $fakeConfig = [pscustomobject]@{ runtime_path = $fakeExe; model_path = (Join-Path $tempRoot 'model.gguf'); port = 8080 }
    $self = Get-Process -Id $PID
    $wrongRecord = [pscustomobject]@{ pid = $PID; executable_path = $fakeExe }
    Assert-True (-not (Test-ManagedProcess $wrongRecord $fakeConfig)) 'PID reuse or executable mismatch is rejected'

    $statusRoot = Join-Path $tempRoot 'status-empty'
    $statusOutput = & $scriptPath status -DataRoot $statusRoot | ConvertFrom-Json
    Assert-True (-not $statusOutput.configured -and -not $statusOutput.running -and -not $statusOutput.healthy) 'status is idempotent when nothing is installed'
    Assert-True (-not (Test-Path -LiteralPath $statusRoot)) 'status does not create state'

    $whatIfRoot = Join-Path $tempRoot 'whatif'
    & $scriptPath install -Component runtime -DataRoot $whatIfRoot -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $whatIfRoot)) 'install -WhatIf does not create state or download'

    $example = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\model.example.json') -Raw | ConvertFrom-Json
    Assert-True ($example.bind_host -eq '127.0.0.1') 'example config binds only loopback'
    Assert-True ($example.port -eq 18080) 'example config uses the reserved llama-server port'
    Assert-True ($example.model_profile -eq 'gemma') 'example config keeps Gemma as default'
    Assert-True ($example.model_commit -eq 'd1be121d36172a4b0b964657e2ee859d61138593') 'example config pins the Gemma commit'

    Assert-True ($scriptText -match '530f57d2a874ce017827c1e5a926812b9d5de4667248575d1372b1c0acf94d83') 'runtime SHA-256 is pinned'
    Assert-True ($scriptText -match '95e5b8d891cd6a794f66c2a6fb59a41e9562b4660560b854274eceffb628b22a') 'Gemma SHA-256 is pinned'
    Assert-True ($scriptText -match 'da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4') 'Qwen SHA-256 is pinned'
    Assert-True ($scriptText -notmatch 'Write-(Host|Output|Verbose).*Token') 'token is not written to logs or output'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($script:Failures -gt 0) { throw "$($script:Failures) model manager test(s) failed." }
Write-Host 'All model manager tests passed.' -ForegroundColor Green
