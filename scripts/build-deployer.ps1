[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $projectRoot 'deployer\Cargo.toml'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Deployer Cargo manifest is missing: '$manifest'."
}

$arguments = @('build', '--manifest-path', $manifest)
if ($Profile -eq 'release') { $arguments += '--release' }

& cargo @arguments
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE." }

$output = Join-Path $projectRoot ("deployer\target\{0}\RimeBilingualDeploy.exe" -f $Profile)
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Expected deployer output is missing: '$output'."
}
Write-Host $output

