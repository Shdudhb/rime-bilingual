[CmdletBinding()]
param(
    [switch]$SkipE2E
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$callerPath = Join-Path $projectRoot 'scripts\translate-batch.ps1'
$mockPath = Join-Path $PSScriptRoot 'fixtures\mock_helper.ps1'
$helperPath = Join-Path $projectRoot 'helper\target\release\RimeTranslateHelper.exe'
$script:Failures = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { $script:Failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
}

function Assert-Throws([scriptblock]$Operation, [string]$Pattern, [string]$Message) {
    try { & $Operation | Out-Null; $script:Failures++; Write-Host "FAIL: $Message (did not throw)" -ForegroundColor Red }
    catch {
        if ($_.Exception.Message -match $Pattern) { Write-Host "PASS: $Message" -ForegroundColor Green }
        else { $script:Failures++; Write-Host "FAIL: $Message ($($_.Exception.Message))" -ForegroundColor Red }
    }
}

function Get-FreePort {
    $socket = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $socket.Start(); return ([Net.IPEndPoint]$socket.LocalEndpoint).Port }
    finally { $socket.Stop() }
}

function Start-MockHelper([string]$Mode, [string]$TemporaryRoot) {
    $port = Get-FreePort
    $ready = Join-Path $TemporaryRoot ("mock-$port.ready")
    $hostExe = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mockPath, '-Port', [string]$port, '-Mode', $Mode, '-ReadyPath', $ready)
    $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
        $process.Refresh()
        if ($process.HasExited) { throw "mock Helper exited during startup with code $($process.ExitCode)." }
    }
    if (-not (Test-Path -LiteralPath $ready)) { throw 'mock Helper did not become ready.' }
    return [pscustomobject]@{ Process = $process; Path = [IO.Path]::GetFullPath($hostExe); Port = $port }
}

function Stop-OwnedProcess($Owned) {
    if ($null -eq $Owned -or $null -eq $Owned.Process) { return }
    $process = Get-Process -Id $Owned.Process.Id -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        try { $Owned.Process.Dispose() } catch { }
        return
    }
    try { $actual = [IO.Path]::GetFullPath($process.Path) }
    catch {
        if ($null -eq (Get-Process -Id $Owned.Process.Id -ErrorAction SilentlyContinue)) {
            try { $Owned.Process.Dispose() } catch { }
            return
        }
        throw "Refusing to stop PID $($Owned.Process.Id): path cannot be verified."
    }
    if ($actual -ne $Owned.Path -or $process.StartTime -ne $Owned.Process.StartTime) {
        throw "Refusing to stop PID $($Owned.Process.Id): process identity changed."
    }
    try { Stop-Process -Id $process.Id -ErrorAction Stop }
    catch {
        if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { throw }
        try { $Owned.Process.Dispose() } catch { }
        return
    }
    try { Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    try { $Owned.Process.Dispose() } catch { }
}

function Wait-HelperHealth([int]$Port, [Diagnostics.Process]$Process, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Helper exited during startup with code $($Process.ExitCode)." }
        try {
            $health = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/health") -TimeoutSec 2
            if ($health.status -eq 'ok' -and $health.llama_ready) { return }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    throw 'Helper did not report a ready llama-server before timeout.'
}

$oldTestMode = $env:RIME_BILINGUAL_TRANSLATE_TEST_MODE
$env:RIME_BILINGUAL_TRANSLATE_TEST_MODE = '1'
try { . $callerPath } finally { $env:RIME_BILINGUAL_TRANSLATE_TEST_MODE = $oldTestMode }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('rime-bilingual-helper-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $candidateWo = [string][char]0x6211
    $candidateNi = [string][char]0x4F60
    $candidateTa = [string][char]0x4ED6
    $candidateToday = ([string][char]0x4ECA) + ([string][char]0x5929)
    $candidatePage = @($candidateWo, $candidateNi, $candidateTa, $candidateToday)
    $request = New-ParameterRequest $candidatePage 'test-params'
    foreach ($case in @(
        [pscustomobject]@{ Mode = 'success'; Pattern = $null; Name = 'valid Helper response succeeds' },
        [pscustomobject]@{ Mode = 'invalid'; Pattern = 'count does not match'; Name = 'invalid Helper response fails closed' },
        [pscustomobject]@{ Mode = 'non2xx'; Pattern = 'HTTP 503.*MODEL_UNAVAILABLE'; Name = 'non-2xx Helper response is surfaced' }
    )) {
        $mock = $null
        try {
            $mock = Start-MockHelper $case.Mode $temporaryRoot
            $endpoint = "http://127.0.0.1:$($mock.Port)"
            if ($null -eq $case.Pattern) {
                $result = Invoke-RimeBilingualTranslation $request $endpoint 5
                Assert-True (@($result.translations).Count -eq 4) $case.Name
                Assert-True ((@($result.translations) -join '|') -ceq 'I|You|He|Today') 'success preserves translation order'
            } else {
                Assert-Throws { Invoke-RimeBilingualTranslation $request $endpoint 5 } $case.Pattern $case.Name
            }
        } finally { Stop-OwnedProcess $mock }
    }

    $unusedPort = Get-FreePort
    Assert-Throws { Invoke-RimeBilingualTranslation $request "http://127.0.0.1:$unusedPort" 2 } 'Helper unavailable' 'unavailable Helper is reported'
    Assert-Throws { Invoke-RimeBilingualTranslation $request 'http://localhost:18081' 2 } 'form http://127.0.0.1' 'caller rejects non-canonical loopback endpoint'

    $jsonRequestObject = New-ParameterRequest @($candidateWo) 'json-1'
    $inputJson = $jsonRequestObject | ConvertTo-Json -Depth 5 -Compress
    $parsed = ConvertFrom-StrictJson $inputJson 'Input'
    Assert-Request $parsed
    Assert-True ($parsed.request_id -eq 'json-1') 'strict JSON request input is accepted'

    $jsonMock = $null
    try {
        $jsonMock = Start-MockHelper 'success' $temporaryRoot
        $cliInput = $request | ConvertTo-Json -Depth 5 -Compress
        $cliOutput = & $callerPath -InputJson $cliInput -HelperEndpoint "http://127.0.0.1:$($jsonMock.Port)" -TimeoutSec 5 | ConvertFrom-Json
        Assert-True ((@($cliOutput.translations) -join '|') -ceq 'I|You|He|Today') 'CLI accepts JSON input and emits validated JSON'
    } finally { Stop-OwnedProcess $jsonMock }

    $parameterMock = $null
    try {
        $parameterMock = Start-MockHelper 'success' $temporaryRoot
        $parameterOutput = & $callerPath -Candidates $candidatePage -RequestId 'test-params' -HelperEndpoint "http://127.0.0.1:$($parameterMock.Port)" -TimeoutSec 5 | ConvertFrom-Json
        Assert-True ((@($parameterOutput.translations) -join '|') -ceq 'I|You|He|Today') 'CLI accepts candidate parameters and emits validated JSON'
    } finally { Stop-OwnedProcess $parameterMock }

    if (-not $SkipE2E) {
        Assert-True (Test-Path -LiteralPath $helperPath -PathType Leaf) 'release Helper executable exists for E2E'
        $helperPort = Get-FreePort
        $stdout = Join-Path $temporaryRoot 'helper.stdout.log'
        $stderr = Join-Path $temporaryRoot 'helper.stderr.log'
        $arguments = @('--bind', "127.0.0.1:$helperPort", '--llama-endpoint', 'http://127.0.0.1:18080/v1/chat/completions', '--model', 'gemma-3-1b-it-qat-q4_0', '--timeout-ms', '120000')
        $helperProcess = Start-Process -FilePath $helperPath -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $ownedHelper = [pscustomobject]@{ Process = $helperProcess; Path = [IO.Path]::GetFullPath($helperPath); Port = $helperPort }
        try {
            Wait-HelperHealth $helperPort $helperProcess 15
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $e2e = Invoke-RimeBilingualTranslation (New-ParameterRequest $candidatePage 'e2e-gemma') "http://127.0.0.1:$helperPort" 120
            $stopwatch.Stop()
            Assert-True (@($e2e.translations).Count -eq 4) 'Gemma E2E returns one translation per candidate'
            Assert-True (@(@($e2e.translations) | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) 'Gemma E2E returns four non-empty English strings'
            Assert-True ($e2e.request_id -eq 'e2e-gemma') 'Gemma E2E correlates request_id'
            Write-Host ('E2E translations: ' + ((@($e2e.translations) | ForEach-Object { [string]$_ }) -join ' | '))
            Write-Host ("E2E helper elapsed_ms: $($e2e.elapsed_ms); caller wall_ms: $($stopwatch.ElapsedMilliseconds); model: $($e2e.model)")
        } finally { Stop-OwnedProcess $ownedHelper }
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        for ($cleanupAttempt = 0; $cleanupAttempt -lt 10; $cleanupAttempt++) {
            try { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction Stop; break }
            catch {
                if ($cleanupAttempt -eq 9) { Write-Warning "Could not remove test directory: $temporaryRoot" }
                else { Start-Sleep -Milliseconds 100 }
            }
        }
    }
}

if ($script:Failures -gt 0) { throw "$($script:Failures) Helper integration test(s) failed." }
Write-Host 'All Helper integration tests passed.' -ForegroundColor Green
