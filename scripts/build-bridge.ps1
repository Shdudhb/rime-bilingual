[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$manifest = Join-Path $ProjectRoot 'bridge\Cargo.toml'
$artifact = Join-Path $ProjectRoot 'bridge\target\release\rime_bilingual_bridge.dll'

if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'The native bridge must be built from an x64 PowerShell process on x64 Windows.'
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Bridge manifest is missing: '$manifest'." }

& cargo test --manifest-path $manifest
if ($LASTEXITCODE -ne 0) { throw "Bridge tests failed with exit code $LASTEXITCODE." }
& cargo build --release --manifest-path $manifest
if ($LASTEXITCODE -ne 0) { throw "Bridge release build failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Bridge build did not produce '$artifact'." }

$bytes = [IO.File]::ReadAllBytes($artifact)
if ($bytes.Length -lt 68 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw 'Bridge artifact is not a PE image.' }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or
    [BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550 -or
    [BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) {
    throw 'Bridge artifact is not an x64 PE image.'
}

Write-Host "Built x64 bridge: '$artifact'."
