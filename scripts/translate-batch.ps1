[CmdletBinding(DefaultParameterSetName = 'Parameters')]
param(
    [Parameter(ParameterSetName = 'Parameters')]
    [string[]]$Candidates,

    [Parameter(ParameterSetName = 'Parameters')]
    [string]$RequestId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Json')]
    [string]$InputJson,

    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$InputPath,

    [string]$HelperEndpoint = 'http://127.0.0.1:18081',

    [ValidateRange(1, 120)]
    [int]$TimeoutSec = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProtocolVersion = 1
$script:MaxCandidates = 20
$script:MaxRequestIdBytes = 128
$script:MaxCandidateBytes = 256
$script:MaxTranslationBytes = 256
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Get-Utf8ByteCount([string]$Value) {
    return $script:Utf8.GetByteCount($Value)
}

function Test-ControlCharacter([string]$Value) {
    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) { return $true }
    }
    return $false
}

function Assert-ExactProperties($Value, [string[]]$Expected, [string]$Label) {
    if ($null -eq $Value) { throw "$Label must be a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count) { throw "$Label has missing or unknown fields." }
    for ($index = 0; $index -lt $wanted.Count; $index++) {
        if ($actual[$index] -cne $wanted[$index]) { throw "$Label has missing or unknown fields." }
    }
}

function Assert-Request($Request) {
    Assert-ExactProperties $Request @('protocol_version', 'request_id', 'context', 'candidates') 'request'
    if ($Request.protocol_version -isnot [int] -and $Request.protocol_version -isnot [long]) {
        throw 'request.protocol_version must be integer 1.'
    }
    if ([int64]$Request.protocol_version -ne $script:ProtocolVersion) {
        throw 'request.protocol_version must be integer 1.'
    }
    if ($Request.request_id -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.request_id) -or
        (Get-Utf8ByteCount $Request.request_id) -gt $script:MaxRequestIdBytes) {
        throw 'request.request_id must be a non-empty string of at most 128 UTF-8 bytes.'
    }
    if ($Request.context -isnot [string] -or $Request.context.Length -ne 0) {
        throw 'request.context must be an empty string in protocol v1.'
    }
    if ($Request.candidates -isnot [array]) { throw 'request.candidates must be a JSON array.' }
    $items = @($Request.candidates)
    if ($items.Count -lt 1 -or $items.Count -gt $script:MaxCandidates) {
        throw 'request.candidates must contain 1 to 20 items.'
    }
    foreach ($candidate in $items) {
        if ($candidate -isnot [string] -or [string]::IsNullOrWhiteSpace($candidate) -or
            (Get-Utf8ByteCount $candidate) -gt $script:MaxCandidateBytes -or
            (Test-ControlCharacter $candidate)) {
            throw 'each candidate must be a non-empty string of at most 256 UTF-8 bytes without control characters.'
        }
    }
}

function ConvertFrom-StrictJson([string]$Json, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Json)) { throw "$Label JSON is empty." }
    try { return ($Json | ConvertFrom-Json) }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
}

function New-ParameterRequest([string[]]$Items, [string]$Id) {
    if ($null -eq $Items) { throw '-Candidates is required when JSON input is not used.' }
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = 'cli-' + [guid]::NewGuid().ToString('N') }
    return [pscustomobject][ordered]@{
        protocol_version = 1
        request_id = $Id
        context = ''
        candidates = @($Items)
    }
}

function Get-TranslateUri([string]$Endpoint) {
    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) {
        throw 'HelperEndpoint must be an absolute loopback HTTP URL.'
    }
    if ($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1' -or $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or ($uri.AbsolutePath -ne '/')) {
        throw 'HelperEndpoint must have the form http://127.0.0.1:<port>.'
    }
    return [Uri]::new($uri, '/translate')
}

function Assert-Response($Response, $Request) {
    Assert-ExactProperties $Response @('protocol_version', 'request_id', 'translations', 'model', 'elapsed_ms') 'response'
    if (($Response.protocol_version -isnot [int] -and $Response.protocol_version -isnot [long]) -or
        [int64]$Response.protocol_version -ne $script:ProtocolVersion) {
        throw 'response.protocol_version is invalid.'
    }
    if ($Response.request_id -isnot [string] -or $Response.request_id -cne $Request.request_id) {
        throw 'response.request_id does not match the request.'
    }
    if ($Response.translations -isnot [array]) { throw 'response.translations must be a JSON array.' }
    $translations = @($Response.translations)
    $candidates = @($Request.candidates)
    if ($translations.Count -ne $candidates.Count) {
        throw 'response.translations count does not match request.candidates.'
    }
    foreach ($translation in $translations) {
        if ($translation -isnot [string] -or [string]::IsNullOrWhiteSpace($translation) -or
            (Get-Utf8ByteCount $translation) -gt $script:MaxTranslationBytes -or
            (Test-ControlCharacter $translation)) {
            throw 'each translation must be a non-empty string of at most 256 UTF-8 bytes without control characters.'
        }
    }
    if ($Response.model -isnot [string] -or [string]::IsNullOrWhiteSpace($Response.model) -or
        (Get-Utf8ByteCount $Response.model) -gt 128 -or (Test-ControlCharacter $Response.model)) {
        throw 'response.model is invalid.'
    }
    if (($Response.elapsed_ms -isnot [int] -and $Response.elapsed_ms -isnot [long]) -or [int64]$Response.elapsed_ms -lt 0) {
        throw 'response.elapsed_ms must be a non-negative integer.'
    }
}

function Invoke-RimeBilingualTranslation($Request, [string]$Endpoint = 'http://127.0.0.1:18081', [int]$RequestTimeoutSec = 120) {
    Assert-Request $Request
    $uri = Get-TranslateUri $Endpoint
    $json = $Request | ConvertTo-Json -Depth 5 -Compress
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSec)
    $content = New-Object System.Net.Http.StringContent($json, $script:Utf8, 'application/json')
    try {
        try { $httpResponse = $client.PostAsync($uri, $content).GetAwaiter().GetResult() }
        catch { throw "Helper unavailable at ${Endpoint}: $($_.Exception.Message)" }
        try {
            $body = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $httpResponse.IsSuccessStatusCode) {
                $detail = 'invalid or empty error response'
                try {
                    $errorEnvelope = ConvertFrom-StrictJson $body 'Helper error response'
                    if ($null -ne $errorEnvelope.error -and $errorEnvelope.error.code -is [string]) {
                        $detail = [string]$errorEnvelope.error.code
                    }
                } catch { }
                throw "Helper returned HTTP $([int]$httpResponse.StatusCode) ($detail)."
            }
            $response = ConvertFrom-StrictJson $body 'Helper response'
            Assert-Response $response $Request
            return $response
        } finally { $httpResponse.Dispose() }
    } finally {
        $content.Dispose()
        $client.Dispose()
    }
}

if ($env:RIME_BILINGUAL_TRANSLATE_TEST_MODE -eq '1') { return }

switch ($PSCmdlet.ParameterSetName) {
    'Json' { $request = ConvertFrom-StrictJson $InputJson 'Input' }
    'File' {
        $fullInputPath = [IO.Path]::GetFullPath($InputPath)
        if (-not (Test-Path -LiteralPath $fullInputPath -PathType Leaf)) { throw "Input JSON file not found: $fullInputPath" }
        $request = ConvertFrom-StrictJson ([IO.File]::ReadAllText($fullInputPath, $script:Utf8)) 'Input file'
    }
    default { $request = New-ParameterRequest $Candidates $RequestId }
}

$result = Invoke-RimeBilingualTranslation $request $HelperEndpoint $TimeoutSec
$result | ConvertTo-Json -Depth 5 -Compress
