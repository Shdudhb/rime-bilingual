param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $thrown = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $thrown = $true
    }
    Assert-True $thrown $Message
}

function Read-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True -Condition (-not ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
        -Message 'snapshot must not contain a UTF-8 BOM'
    return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Get-PrivateCacheRows {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Sql,
        [object[]]$Parameters = @()
    )

    return @(& $Module {
        param($Path, $Statement, $BoundParameters)
        $database = Open-RimeBilingualDatabase -DatabasePath $Path -ReadOnly
        try {
            return @(Invoke-RimeBilingualSql -Database $database -Sql $Statement `
                -Parameters $BoundParameters -Query)
        }
        finally {
            Close-RimeBilingualDatabase -Database $database
        }
    } $DatabasePath $Sql $Parameters)
}

function Invoke-PrivateCacheSql {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Sql,
        [object[]]$Parameters = @()
    )

    & $Module {
        param($Path, $Statement, $BoundParameters)
        $database = Open-RimeBilingualDatabase -DatabasePath $Path
        try {
            $null = Invoke-RimeBilingualSql -Database $database -Sql $Statement `
                -Parameters $BoundParameters
        }
        finally {
            Close-RimeBilingualDatabase -Database $database
        }
    } $DatabasePath $Sql $Parameters
}

$cacheScript = Join-Path $ProjectRoot 'scripts\cache.ps1'
$modulePath = Join-Path $ProjectRoot 'scripts\lib\rime_bilingual_sqlite.psm1'
$schemaPath = Join-Path $ProjectRoot 'data\cache_schema.sql'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('rime-bilingual-cache-test-' + [guid]::NewGuid().ToString('N'))
$databasePath = Join-Path $testRoot 'translations.db'
$snapshotPath = Join-Path $testRoot 'cache_snapshot.lua'
$incompatiblePath = Join-Path $testRoot 'incompatible.db'
$importPath = Join-Path $testRoot 'entries.csv'
$module = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Assert-True (Test-Path -LiteralPath $cacheScript -PathType Leaf) 'cache CLI exists'
    Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) 'SQLite module exists'
    Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'cache schema exists'

    $module = Import-Module -Force -PassThru -DisableNameChecking -Name $modulePath

    # The publisher's byte ceiling must match the production loader. Use fewer
    # than 10,000 individually valid entries whose combined UTF-8 output is
    # larger than 16 MiB; generation must fail before replacing any snapshot.
    $oversizedSnapshotEntries = @(
        for ($largeIndex = 0; $largeIndex -lt 2100; $largeIndex++) {
            [pscustomobject]@{
                source_text = ('k{0:D4}' -f $largeIndex) + ('s' * 4088)
                translated_text = 'v' * 4096
            }
        }
    )
    Assert-Throws -Action {
        & $module {
            param($Items)
            New-RimeBilingualSnapshotText -Revision 0 -Entries $Items
        } (, $oversizedSnapshotEntries)
    } -Message 'publisher rejects a snapshot larger than the loader byte ceiling'
    $oversizedSnapshotEntries = $null

    # Fresh initialization creates the expected database and metadata without
    # requiring any external SQLite provider.
    $init = & $cacheScript init -DatabasePath $databasePath
    Assert-True (Test-Path -LiteralPath $databasePath -PathType Leaf) 'init creates the database'
    Assert-True ([int64]$init.Revision -eq 0) 'fresh cache revision is zero'
    Assert-True ([int64]$init.SchemaVersion -eq 1) 'fresh cache schema version is one'
    Assert-True ([int64]$init.ApplicationId -ne 0) 'fresh cache application id is fixed and nonzero'

    $validated = & $cacheScript validate -DatabasePath $databasePath
    Assert-True ([bool]$validated.Valid) 'fresh cache validates'
    Assert-True ([int64]$validated.EntryCount -eq 0) 'fresh cache has no entries'
    Assert-Throws -Action {
        & $cacheScript put -DatabasePath $databasePath -SourceText 'empty translation' -TranslatedText ''
    } -Message 'put rejects an empty translation before it can invalidate the runtime snapshot'
    Assert-Throws -Action {
        & $cacheScript put -DatabasePath $databasePath -SourceText 'oversized translation' -TranslatedText ('x' * 4097)
    } -Message 'put rejects a translation over the loader byte limit'

    # Inspect the real SQLite schema through the module's own P/Invoke layer.
    $translationInfo = Get-PrivateCacheRows -Module $module -DatabasePath $databasePath `
        -Sql "PRAGMA table_info('translations')"
    $metaInfo = Get-PrivateCacheRows -Module $module -DatabasePath $databasePath `
        -Sql "PRAGMA table_info('cache_meta')"
    Assert-True ($translationInfo.Count -eq 7) 'translations has all required columns'
    Assert-True ($metaInfo.Count -eq 3) 'cache_meta has revision metadata columns'
    $expectedPrimaryKey = @('source_text', 'source_language', 'target_language', 'translation_mode')
    for ($index = 0; $index -lt $expectedPrimaryKey.Count; $index++) {
        Assert-True ([string]$translationInfo[$index].name -eq $expectedPrimaryKey[$index]) `
            "translations primary-key column $index is correct"
        Assert-True ([int]$translationInfo[$index].pk -eq ($index + 1)) `
            "translations primary-key sequence $index is correct"
    }
    $masterRows = Get-PrivateCacheRows -Module $module -DatabasePath $databasePath `
        -Sql "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
    $translationMaster = $masterRows | Where-Object { $_.name -eq 'translations' } | Select-Object -First 1
    Assert-True ($null -ne $translationMaster) 'translations table is present in sqlite_master'
    Assert-True ([string]$translationMaster.sql -match '(?i)WITHOUT\s+ROWID') `
        'translations is declared WITHOUT ROWID'
    $schemaSource = [System.IO.File]::ReadAllText($schemaPath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($schemaSource -notmatch '(?i)CREATE\s+TABLE\s+translations\s*\([^;]*\bROWID\b(?!\s*\))') `
        'schema does not use a rowid table declaration'

    # A put creates one revision.  An upsert of the same fixed runtime key
    # replaces the row and increments the revision once, rather than creating
    # a second row.
    $firstPut = & $cacheScript put -DatabasePath $databasePath `
        -SourceText '今天' -TranslatedText 'Today' -Source 'first' `
        -UpdatedAtUtc '2024-01-01T00:00:00Z'
    Assert-True ([int64]$firstPut.Revision -eq 1) 'first put increments revision to one'
    $secondPut = & $cacheScript put -DatabasePath $databasePath `
        -SourceText '今天' -TranslatedText 'Today updated' -Source 'second' `
        -UpdatedAtUtc '2024-01-02T00:00:00Z'
    Assert-True ([int64]$secondPut.Revision -eq 2) 'upsert increments revision to two'

    # Insert two non-runtime tuples through the same parameterized P/Invoke
    # API.  They must coexist with the literal row because language and mode
    # are part of the composite key.
    $alternateSql = @'
INSERT INTO translations
    (source_text, source_language, target_language, translation_mode,
     translated_text, source, updated_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?)
'@
    Invoke-PrivateCacheSql -Module $module -DatabasePath $databasePath -Sql $alternateSql `
        -Parameters @('今天', 'zh', 'en', 'natural', 'Natural Today', 'alternate', '2024-01-03T00:00:00Z')
    Invoke-PrivateCacheSql -Module $module -DatabasePath $databasePath -Sql $alternateSql `
        -Parameters @('今天', 'ja', 'en', 'literal', 'Japanese Today', 'alternate', '2024-01-03T00:00:00Z')
    $sameTextRows = Get-PrivateCacheRows -Module $module -DatabasePath $databasePath `
        -Sql 'SELECT source_language, target_language, translation_mode, translated_text, source FROM translations WHERE source_text = ? ORDER BY source_language, translation_mode' `
        -Parameters @('今天')
    Assert-True ($sameTextRows.Count -eq 3) 'composite key keeps language and mode rows isolated'
    $literalRow = $sameTextRows | Where-Object { $_.source_language -eq 'zh' -and $_.translation_mode -eq 'literal' } | Select-Object -First 1
    Assert-True ([string]$literalRow.translated_text -eq 'Today updated') 'literal upsert retained the updated translation'
    Assert-True ([string]$literalRow.source -eq 'second') 'literal upsert replaced provenance'

    # Import rows containing quote, backslash, newline, NUL/control data and
    # Lua-looking text.  ConvertTo-Csv writes a valid UTF-8 local fixture; no
    # network or external translation service is involved.
    $dangerousSource = "quote' slash\ line$([char]10) nul$([char]0) ctrl$([char]1) return { os.execute('owned') }"
    $dangerousTranslation = "value' slash\ line$([char]10) nul$([char]0) ctrl$([char]2) return { os.execute('owned') }"
    $importRows = @(
        [pscustomobject]@{
            source_text = 'alpha'
            translated_text = 'Alpha'
            source = 'fixture'
            updated_at_utc = '2024-01-04T00:00:00Z'
        },
        [pscustomobject]@{
            source_text = $dangerousSource
            translated_text = $dangerousTranslation
            source = 'fixture'
            updated_at_utc = '2024-01-04T00:00:00Z'
        }
    )
    $csvText = ($importRows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($importPath, $csvText, [System.Text.UTF8Encoding]::new($false))
    $imported = & $cacheScript import -DatabasePath $databasePath -InputPath $importPath -DefaultSource fixture
    Assert-True ([int64]$imported.Revision -eq 3) 'one import batch increments revision once'
    Assert-True ([int]$imported.EntryCount -eq 2) 'import reports both rows'

    $published = & $cacheScript publish -DatabasePath $databasePath -SnapshotPath $snapshotPath
    Assert-True ([int64]$published.Revision -eq 3) 'published snapshot uses committed revision'
    $snapshotText = Read-Utf8NoBom -Path $snapshotPath
    $snapshotBytesBeforeRepeat = [System.IO.File]::ReadAllBytes($snapshotPath)
    $publishedAgain = & $cacheScript publish -DatabasePath $databasePath -SnapshotPath $snapshotPath
    $snapshotBytesAfterRepeat = [System.IO.File]::ReadAllBytes($snapshotPath)
    Assert-True ($snapshotBytesBeforeRepeat.Length -eq $snapshotBytesAfterRepeat.Length) `
        'repeated publication has the same byte length'
    for ($index = 0; $index -lt $snapshotBytesBeforeRepeat.Length; $index++) {
        Assert-True ($snapshotBytesBeforeRepeat[$index] -eq $snapshotBytesAfterRepeat[$index]) `
            "repeated publication is deterministic at byte $index"
    }
    Assert-True ([int64]$publishedAgain.Revision -eq 3) 'repeated publication keeps revision'
    Assert-True ($snapshotText -match "source_language\s*=\s*'zh'") 'snapshot has fixed source language'
    Assert-True ($snapshotText -match "target_language\s*=\s*'en'") 'snapshot has fixed target language'
    Assert-True ($snapshotText -match "translation_mode\s*=\s*'literal'") 'snapshot has fixed translation mode'
    Assert-True ($snapshotText -match "\\'") 'snapshot escapes apostrophes'
    Assert-True ($snapshotText -match "\\\\") 'snapshot escapes backslashes'
    Assert-True ($snapshotText -match "\\n") 'snapshot escapes newlines'
    Assert-True ($snapshotText -match "\\000") 'snapshot escapes NUL control bytes'
    Assert-True ($snapshotText -match "\\001|\\002") 'snapshot escapes non-printable controls'
    Assert-True ($snapshotText -match 'return \{ os\.execute') 'Lua-looking payload remains inside data text'
    $canonicalLuaString = "'(?:[^'\\\x00-\x1F\x7F]|\\[btnfr'\\]|\\[0-9]{3})*'"
    $publishedEntryLines = @($snapshotText -split '\r?\n' | Where-Object { $_ -match '^\s{4}\[' })
    Assert-True ($publishedEntryLines.Count -eq 3) 'publisher emitted all runtime entries'
    foreach ($publishedEntryLine in $publishedEntryLines) {
        Assert-True ($publishedEntryLine -match ("^\s{{4}}\[{0}\] = {0},$" -f $canonicalLuaString)) 'every publisher entry roundtrips through the production canonical string grammar'
    }
    $validatedPublished = & $cacheScript validate -DatabasePath $databasePath -SnapshotPath $snapshotPath
    Assert-True ([bool]$validatedPublished.SnapshotValid) 'published snapshot validates against DB revision'

    # A failed replacement must leave the previous snapshot untouched.  A
    # non-sharing handle simulates another process holding the deployed file.
    $oldSnapshotBytes = [System.IO.File]::ReadAllBytes($snapshotPath)
    $lockedStream = New-Object System.IO.FileStream(
        $snapshotPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::None
    )
    try {
        Assert-Throws -Action {
            & $cacheScript publish -DatabasePath $databasePath -SnapshotPath $snapshotPath
        } -Message 'locked snapshot publication fails'
    }
    finally {
        $lockedStream.Dispose()
    }
    $afterFailedPublish = [System.IO.File]::ReadAllBytes($snapshotPath)
    Assert-True ($afterFailedPublish.Length -eq $oldSnapshotBytes.Length) `
        'failed publication preserves snapshot length'
    for ($index = 0; $index -lt $oldSnapshotBytes.Length; $index++) {
        Assert-True ($afterFailedPublish[$index] -eq $oldSnapshotBytes[$index]) `
            "failed publication preserves old snapshot byte $index"
    }

    # Defense in depth for a compatible DB edited outside this CLI: publish
    # must reject a runtime row the loader cannot accept and preserve the last
    # valid snapshot.
    Invoke-PrivateCacheSql -Module $module -DatabasePath $databasePath -Sql $alternateSql -Parameters @('externally poisoned', 'zh', 'en', 'literal', '', 'external', '2024-01-05T00:00:00Z')
    $snapshotHashBeforePoisonedPublish = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    Assert-Throws -Action {
        & $cacheScript publish -DatabasePath $databasePath -SnapshotPath $snapshotPath
    } -Message 'publisher rejects an externally inserted empty runtime translation'
    Assert-True ((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -eq $snapshotHashBeforePoisonedPublish) 'invalid DB content cannot replace the last valid snapshot'
    Invoke-PrivateCacheSql -Module $module -DatabasePath $databasePath -Sql 'DELETE FROM translations WHERE source_text = ? AND source_language = ? AND target_language = ? AND translation_mode = ?' -Parameters @('externally poisoned', 'zh', 'en', 'literal')

    # An incompatible existing file is never overwritten during init.
    [System.IO.File]::WriteAllText($incompatiblePath, 'this is not a SQLite database', [System.Text.UTF8Encoding]::new($false))
    $incompatibleHashBefore = (Get-FileHash -LiteralPath $incompatiblePath -Algorithm SHA256).Hash
    Assert-Throws -Action {
        & $cacheScript init -DatabasePath $incompatiblePath
    } -Message 'init rejects an incompatible database'
    $incompatibleHashAfter = (Get-FileHash -LiteralPath $incompatiblePath -Algorithm SHA256).Hash
    Assert-True ($incompatibleHashBefore -eq $incompatibleHashAfter) `
        'incompatible database remains byte-for-byte unchanged'

    # The cache maintenance path has no outbound/network implementation.
    $cacheSource = [System.IO.File]::ReadAllText($cacheScript, [System.Text.UTF8Encoding]::new($false, $true)) + `
        [System.IO.File]::ReadAllText($modulePath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($cacheSource -notmatch '(?i)https?://|Invoke-WebRequest|Invoke-RestMethod|WebClient|System\.Net|curl|socket|openrouter|google') `
        'cache maintenance source contains no network client strings'

    Write-Output 'PASS: SQLite schema, parameterized cache upsert/import, deterministic escaped snapshot, failure preservation, and incompatibility checks passed.'
}
finally {
    if ($null -ne $module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
