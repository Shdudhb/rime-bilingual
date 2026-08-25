[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('init', 'put', 'import', 'purge-model', 'publish', 'validate')]
    [string]$Command,

    [string]$DatabasePath,

    [Alias('OutputPath')]
    [string]$SnapshotPath,

    [Alias('Text')]
    [string]$SourceText,

    [Alias('Translation', 'TargetText')]
    [ValidateNotNullOrEmpty()]
    [string]$TranslatedText,

    [Alias('ProvenanceSource')]
    [string]$Source = 'manual',

    [string]$UpdatedAtUtc,

    [Alias('Path', 'FilePath')]
    [string]$InputPath,

    [string]$DefaultSource = 'import',

    [string]$RimeRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$modulePath = Join-Path $PSScriptRoot 'lib\rime_bilingual_sqlite.psm1'
Import-Module -Force -DisableNameChecking $modulePath
$databasePathWasExplicit = $PSBoundParameters.ContainsKey('DatabasePath')
$snapshotPathWasExplicit = $PSBoundParameters.ContainsKey('SnapshotPath')

if ([string]::IsNullOrWhiteSpace($RimeRoot)) {
    $paths = Get-RimeBilingualDefaultPaths
}
else {
    $paths = Get-RimeBilingualDefaultPaths -RimeRoot $RimeRoot
}

if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
    $DatabasePath = $paths.DatabasePath
}
if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $SnapshotPath = $paths.SnapshotPath
}

switch ($Command) {
    'init' {
        Write-Output (Initialize-RimeBilingualCache -DatabasePath $DatabasePath)
    }
    'put' {
        if ($null -eq $SourceText) {
            throw 'put requires -SourceText.'
        }
        if ([string]::IsNullOrEmpty($TranslatedText)) {
            throw 'put requires a non-empty -TranslatedText.'
        }
        Write-Output (Put-RimeBilingualCacheEntry `
            -DatabasePath $DatabasePath `
            -SourceText $SourceText `
            -TranslatedText $TranslatedText `
            -Source $Source `
            -UpdatedAtUtc $UpdatedAtUtc)
    }
    'import' {
        if ([string]::IsNullOrWhiteSpace($InputPath)) {
            throw 'import requires -InputPath.'
        }
        Write-Output (Import-RimeBilingualCacheEntries `
            -DatabasePath $DatabasePath `
            -InputPath $InputPath `
            -DefaultSource $DefaultSource)
    }
    'purge-model' {
        Write-Output (Remove-RimeBilingualModelCacheEntries -DatabasePath $DatabasePath)
    }
    'publish' {
        Write-Output (Publish-RimeBilingualCacheSnapshot `
            -DatabasePath $DatabasePath `
            -SnapshotPath $SnapshotPath)
    }
    'validate' {
        if (($snapshotPathWasExplicit -or -not $databasePathWasExplicit) -and
            (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
            Write-Output (Validate-RimeBilingualCache `
                -DatabasePath $DatabasePath `
                -SnapshotPath $SnapshotPath)
        }
        else {
            Write-Output (Validate-RimeBilingualCache -DatabasePath $DatabasePath)
        }
    }
}
