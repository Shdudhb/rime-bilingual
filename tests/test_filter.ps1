param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Read-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Windows PowerShell 5.1 otherwise uses the system ANSI code page for
    # Get-Content.  The repository payload is UTF-8, so decode its bytes
    # explicitly before inspecting dictionary keys or schema text.
    $text = [System.Text.Encoding]::UTF8.GetString(
        [System.IO.File]::ReadAllBytes($Path)
    )

    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        return $text.Substring(1)
    }

    return $text
}

function New-UnicodeString {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$CodePoints
    )

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function New-ModelCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [object]$Comment,
        [string]$Type = 'word',
        [double]$Quality = 0.0,
        [int]$Start = 0,
        [int]$End = 1
    )

    $candidate = [pscustomobject]@{
        text = $Text
        comment = $Comment
        type = $Type
        quality = $Quality
        start = $Start
        end = $End
    }

    # The real Lua API returns the genuine candidate.  This smallest useful
    # model returns the same object, while still making the get_genuine call
    # explicit in the behavior under test.
    Add-Member -InputObject $candidate -MemberType ScriptMethod -Name GetGenuine -Value {
        return $this
    } -Force

    return $candidate
}

function Test-ModelString {
    param(
        [object]$Value,
        [bool]$AllowEmpty = $false,
        [int]$MaxBytes = 4096
    )

    if ($Value -isnot [string]) {
        return $false
    }
    if (-not $AllowEmpty -and $Value.Length -eq 0) {
        return $false
    }
    return [System.Text.Encoding]::UTF8.GetByteCount($Value) -le $MaxBytes
}

function Invoke-CacheSnapshotModel {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Snapshot,
        [int]$MaxEntries = 10000,
        [int]$MaxStringBytes = 4096
    )

    $empty = @{}
    $fail = {
        param([string]$Reason)
        return [pscustomobject]@{
            Valid = $false
            Cache = $empty
            WarningCount = 1
            Reason = $Reason
        }
    }

    if ($Snapshot['format_version'] -ne 1) {
        return & $fail 'format_version'
    }
    if ($Snapshot['db_schema_version'] -ne 1) {
        return & $fail 'db_schema_version'
    }
    if ($Snapshot['source_language'] -cne 'zh') {
        return & $fail 'source_language'
    }
    if ($Snapshot['target_language'] -cne 'en') {
        return & $fail 'target_language'
    }
    if ($Snapshot['translation_mode'] -cne 'literal') {
        return & $fail 'translation_mode'
    }

    $revision = $Snapshot['revision']
    $revisionValid = $revision -is [ValueType] -and $revision -is [IConvertible]
    if ($revisionValid) {
        try {
            $revisionNumber = [double]$revision
            $revisionValid = ($revisionNumber -ge 0 -and $revisionNumber -le 2147483647 -and $revisionNumber -eq [math]::Truncate($revisionNumber))
        }
        catch {
            $revisionValid = $false
        }
    }
    if (-not $revisionValid) {
        return & $fail 'revision'
    }

    $entries = $Snapshot['entries']
    if ($entries -isnot [hashtable]) {
        return & $fail 'entries'
    }
    if ($entries.Count -gt $MaxEntries) {
        return & $fail 'entry-count'
    }

    $cache = @{}
    foreach ($pair in $entries.GetEnumerator()) {
        $sourceText = $pair.Key
        $translatedText = $pair.Value

        if (-not (Test-ModelString -Value $sourceText -MaxBytes $MaxStringBytes)) {
            return & $fail 'entry-source-text'
        }
        if (-not (Test-ModelString -Value $translatedText -MaxBytes $MaxStringBytes)) {
            return & $fail 'entry-translated-text'
        }
        if ($sourceText -isnot [string] -or $translatedText -isnot [string]) {
            return & $fail 'entry-shape'
        }
        $cache[$sourceText] = $translatedText
    }

    return [pscustomobject]@{
        Valid = $true
        Cache = $cache
        WarningCount = 0
        Reason = $null
    }
}

function ConvertFrom-CanonicalLuaStringModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Encoded,
        [int]$MaxStringBytes = 4096
    )

    $builder = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $Encoded.Length; $index++) {
        $character = $Encoded[$index]
        if ($character -ne '\') {
            $null = $builder.Append($character)
            continue
        }

        $index++
        if ($index -ge $Encoded.Length) { throw 'truncated escape' }
        $escaped = $Encoded[$index]
        $knownEscape = $true
        switch ($escaped) {
            'b' { $null = $builder.Append([char]0x08); break }
            't' { $null = $builder.Append([char]0x09); break }
            'n' { $null = $builder.Append([char]0x0A); break }
            'f' { $null = $builder.Append([char]0x0C); break }
            'r' { $null = $builder.Append([char]0x0D); break }
            "'" { $null = $builder.Append("'"); break }
            '\' { $null = $builder.Append('\'); break }
            default { $knownEscape = $false }
        }
        if ($knownEscape) { continue }

        if ($index + 2 -ge $Encoded.Length) { throw 'truncated decimal escape' }
        $digits = $Encoded.Substring($index, 3)
        if ($digits -notmatch '^\d{3}$') { throw 'invalid escape' }
        $code = [int]$digits
        if (-not ($code -lt 0x20 -or $code -eq 0x7F) -or $code -in @(0x08, 0x09, 0x0A, 0x0C, 0x0D)) {
            throw 'non-canonical decimal escape'
        }
        $null = $builder.Append([char]$code)
        $index += 2
    }

    $decoded = $builder.ToString()
    if ($decoded.Length -eq 0 -or [Text.Encoding]::UTF8.GetByteCount($decoded) -gt $MaxStringBytes) {
        throw 'decoded string is empty or too long'
    }
    return $decoded
}

function Invoke-CanonicalSnapshotTextModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [int]$MaxEntries = 10000,
        [int]$MaxStringBytes = 4096,
        [int]$MaxFileBytes = (16 * 1024 * 1024)
    )

    $fail = {
        param([string]$Reason)
        return [pscustomobject]@{ Valid = $false; Cache = @{}; WarningCount = 1; Reason = $Reason }
    }

    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt $MaxFileBytes) {
        return & $fail 'file-size'
    }

    $withoutCrLf = $Text.Replace("`r`n", '')
    if ($Text.Contains("`r`n")) {
        if ($withoutCrLf.Contains("`r") -or $withoutCrLf.Contains("`n")) { return & $fail 'mixed-newlines' }
        $newline = "`r`n"
    }
    else {
        if ($Text.Contains("`r")) { return & $fail 'invalid-newline' }
        $newline = "`n"
    }

    $lines = @([regex]::Split($Text, [regex]::Escape($newline)))
    if ($lines.Count -lt 11 -or $lines[$lines.Count - 1] -ne '') { return & $fail 'shape' }
    if ($lines[0] -cne 'return {' -or
        $lines[1] -cne '  format_version = 1,' -or
        $lines[2] -cne '  db_schema_version = 1,' -or
        $lines[4] -cne "  source_language = 'zh'," -or
        $lines[5] -cne "  target_language = 'en'," -or
        $lines[6] -cne "  translation_mode = 'literal'," -or
        $lines[7] -cne '  entries = {' -or
        $lines[$lines.Count - 3] -cne '  },' -or
        $lines[$lines.Count - 2] -cne '}') {
        return & $fail 'metadata-or-shape'
    }

    $revisionMatch = [regex]::Match($lines[3], '^  revision = (0|[1-9]\d*),$')
    $revision = 0L
    if (-not $revisionMatch.Success -or
        -not [long]::TryParse($revisionMatch.Groups[1].Value, [ref]$revision) -or
        $revision -gt 2147483647) {
        return & $fail 'revision'
    }

    $entryPattern = @'
^    \['(?<key>(?:\\(?:[btnfr'\\]|\d{3})|[^\x00-\x1F\x7F'\\])*)'\] = '(?<value>(?:\\(?:[btnfr'\\]|\d{3})|[^\x00-\x1F\x7F'\\])*)',$
'@
    $cache = @{}
    $previous = $null
    $entryCount = $lines.Count - 11
    if ($entryCount -gt $MaxEntries) { return & $fail 'entry-count' }

    for ($lineIndex = 8; $lineIndex -lt $lines.Count - 3; $lineIndex++) {
        $match = [regex]::Match($lines[$lineIndex], $entryPattern)
        if (-not $match.Success) { return & $fail 'entry-syntax' }
        try {
            $key = ConvertFrom-CanonicalLuaStringModel -Encoded $match.Groups['key'].Value -MaxStringBytes $MaxStringBytes
            $value = ConvertFrom-CanonicalLuaStringModel -Encoded $match.Groups['value'].Value -MaxStringBytes $MaxStringBytes
        }
        catch {
            return & $fail ('entry-string:' + $_.Exception.Message)
        }
        if ($cache.ContainsKey($key)) { return & $fail 'duplicate-key' }
        if ($null -ne $previous -and [string]::CompareOrdinal($key, $previous) -lt 0) {
            return & $fail 'entry-order'
        }
        $cache[$key] = $value
        $previous = $key
    }

    return [pscustomobject]@{ Valid = $true; Cache = $cache; WarningCount = 0; Reason = $null }
}

function Invoke-FilterModel {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Candidates,
        [Parameter(Mandatory = $true)]
        [hashtable]$Dictionary,
        [hashtable]$Cache = @{},
        [bool]$Enabled = $true,
        [bool]$PreserveExistingComment = $true,
        [string]$Prefix = '',
        [string]$Separator = ''
    )

    $yielded = @()

    foreach ($candidate in $Candidates) {
        if ($Enabled) {
            $translation = $null
            $candidateText = [string]$candidate.text
            if ($Dictionary.ContainsKey($candidateText)) {
                $translation = $Dictionary[$candidateText]
            }

            if ($null -eq $translation -and $Cache.ContainsKey($candidateText)) {
                $translation = $Cache[$candidateText]
            }

            # Lua treats even an empty string as truthy.  Test for nil rather
            # than using PowerShell truthiness so this model follows Lua.
            if ($null -ne $translation) {
                $english = $Prefix + [string]$translation
                if ($null -eq $candidate.comment) {
                    $existing = ''
                }
                else {
                    $existing = [string]$candidate.comment
                }

                $genuine = $candidate.GetGenuine()
                if ($PreserveExistingComment -and $existing -ne '') {
                    $genuine.comment = $existing + $Separator + $english
                }
                else {
                    $genuine.comment = $english
                }
            }
        }

        # The production filter yields this exact candidate, rather than a
        # copied candidate that could change ordering or selection identity.
        $yielded += $candidate
    }

    return $yielded
}

$filterPath = Join-Path $ProjectRoot 'lua\rime_bilingual.lua'
$dictionaryPath = Join-Path $ProjectRoot 'lua\rime_bilingual_dictionary.lua'
$cachePath = Join-Path $ProjectRoot 'lua\rime_bilingual_cache.lua'
$patchPath = Join-Path $ProjectRoot 'rime_ice.custom.yaml'

Assert-True (Test-Path -LiteralPath $filterPath -PathType Leaf) 'filter module exists'
Assert-True (Test-Path -LiteralPath $dictionaryPath -PathType Leaf) 'dictionary module exists'
Assert-True (Test-Path -LiteralPath $cachePath -PathType Leaf) 'cache loader module exists'
Assert-True (Test-Path -LiteralPath $patchPath -PathType Leaf) 'schema patch exists'

$filter = Read-Utf8File -Path $filterPath
$dictionarySource = Read-Utf8File -Path $dictionaryPath
$cacheSource = Read-Utf8File -Path $cachePath
$schemaPatch = Read-Utf8File -Path $patchPath

# STATIC checks bind the model below to the actual production implementation;
# they are not a substitute for loading the modules in librime-lua.
Assert-True (([regex]::Matches($filter, 'require\("rime_bilingual_dictionary"\)')).Count -eq 1) 'filter loads the local dictionary exactly once'
Assert-True (([regex]::Matches($filter, 'require\("rime_bilingual_cache"\)')).Count -eq 1) 'filter loads the cache loader exactly once'
Assert-True ($filter -match 'for\s+candidate\s+in\s+input:iter\(\)\s+do') 'filter iterates the incoming candidate stream'
Assert-True ($filter -match 'bilingual_dictionary\[candidate\.text\]') 'filter uses exact candidate text dictionary lookup'
Assert-True ($filter -match 'bilingual_cache\[candidate\.text\]') 'filter uses exact candidate text cache lookup'
Assert-True ($filter -match 'rime_api:get_user_data_dir\(\)') 'filter locates the cache under the Rime user data directory'
Assert-True ($filter -match 'candidate:get_genuine\(\)\.comment\s*=') 'filter changes only the genuine candidate comment'
Assert-True ($filter -match 'yield\(candidate\)') 'filter yields the original candidate'
Assert-True ($filter -match 'if\s+translation\s*==\s*nil\s+then') 'filter checks cache only after a dictionary miss'
Assert-True ($filter -match 'if\s+translation\s*~=\s*nil\s+then') 'filter annotates dictionary or cache hits'
Assert-True ($filter -match 'preserve_existing_comment') 'filter supports existing comment preservation'
Assert-True ($filter -notmatch '(?i)https?://|curl|socket|openrouter|google') 'typing path contains no network access'
Assert-True ($filter -notmatch '(?i)\bloadfile\b|\bSQLite\b|\bhttp\b|\bsocket\b|\bprocess\b') 'candidate filter does not load files or invoke external services'
Assert-True ($filter -notmatch '(?m)^\s*candidate\.(text|type|quality|start_pos|end_pos)\s*=') 'filter does not rewrite candidate identity fields'

Assert-True ($cacheSource -notmatch '(?m)\bload(file|string)?\s*\(') 'cache loader never executes snapshot text as Lua code'
Assert-True ($cacheSource -match 'io\.open') 'cache loader reads the snapshot only during initialization'
Assert-True ($cacheSource -match 'parse_snapshot\(text\)') 'cache loader parses snapshot text as canonical data'
Assert-True ($cacheSource -match [regex]::Escape('  format_version = 1,')) 'cache loader requires canonical format_version syntax'
Assert-True ($cacheSource -match [regex]::Escape('  db_schema_version = 1,')) 'cache loader requires canonical db_schema_version syntax'
Assert-True ($cacheSource -match [regex]::Escape("  source_language = 'zh',")) 'cache loader requires canonical source_language syntax'
Assert-True ($cacheSource -match [regex]::Escape("  target_language = 'en',")) 'cache loader requires canonical target_language syntax'
Assert-True ($cacheSource -match [regex]::Escape("  translation_mode = 'literal',")) 'cache loader requires canonical translation_mode syntax'
Assert-True ($cacheSource -match 'read_revision\(parser\)') 'cache loader parses a bounded integer revision'
Assert-True ($cacheSource -match 'seen\[source_text\]') 'cache loader rejects duplicate entry keys'
Assert-True ($cacheSource -match 'source_text\s*<\s*previous_source') 'cache loader requires canonical entry ordering'
Assert-True ($cacheSource -match 'MAX_ENTRIES\s*=\s*\d+') 'cache loader bounds entry count'
Assert-True ($cacheSource -match 'MAX_STRING_BYTES\s*=\s*\d+') 'cache loader bounds string size'
Assert-True ($cacheSource -match 'MAX_FILE_BYTES\s*=\s*\d+') 'cache loader bounds snapshot file size before reading it'
Assert-True ($cacheSource -match 'file\.read,\s*file,\s*MAX_FILE_BYTES\s*\+\s*1') 'cache loader uses a bounded read even if the file grows after seek'
Assert-True ($cacheSource -notmatch 'file\.read,\s*file,\s*"\*a"') 'cache loader never performs an unbounded read-all operation'
Assert-True ($cacheSource -match 'return \{\}') 'cache loader falls back to an empty cache'

Assert-True ($schemaPatch -match '"engine/filters/@before last"\s*:\s*lua_filter@\*rime_bilingual') 'schema patch inserts before the final uniquifier'
Assert-True ($schemaPatch -match 'lua_filter@\*rime_bilingual') 'schema patch registers the filter'
Assert-True ($schemaPatch -match 'cache_enabled:\s*true') 'schema patch enables the V0.2 cache by default'

$defaultSeparator = ' ' + (New-UnicodeString -CodePoints @(0x00B7)) + ' '
Assert-True ($schemaPatch -match ('comment_separator:\s*"' + [regex]::Escape($defaultSeparator) + '"')) 'schema patch keeps the configured comment separator'

$entryPattern = '^\s*\["(?<source>[^"]*)"\]\s*=\s*"(?<target>[^"]*)",\s*$'
$entries = @{}
foreach ($line in ($dictionarySource -split "`r?`n")) {
    $entryMatch = [regex]::Match($line, $entryPattern)
    if ($entryMatch.Success) {
        $source = $entryMatch.Groups['source'].Value
        $target = $entryMatch.Groups['target'].Value
        Assert-True (-not $entries.ContainsKey($source)) "dictionary key is unique (UTF-8 key length $($source.Length))"
        $entries[$source] = $target
    }
}

Assert-True ($dictionarySource -match '(?m)^\s*return\s*\{') 'dictionary is a Lua table module'
Assert-True ($dictionarySource -notmatch '(?i)require\(|function\s|\bio\.|\bos\.') 'dictionary remains data-only'
Assert-True ($entries.Count -ge 80) 'dictionary has at least 80 local entries'

# Build expected keys from Unicode code points instead of putting CJK
# literals in this script.  This works in both Windows PowerShell 5.1 and
# pwsh regardless of the host source-code page.
$wo = New-UnicodeString -CodePoints @(0x6211)
$today = New-UnicodeString -CodePoints @(0x4ECA, 0x5929)
$schoolTraditional = New-UnicodeString -CodePoints @(0x5B78, 0x6821)
$schoolSimplified = New-UnicodeString -CodePoints @(0x5B66, 0x6821)
$noProblemTraditional = New-UnicodeString -CodePoints @(0x6C92, 0x95DC, 0x4FC2)
$unknown = 'not-in-dictionary'
$cacheOnly = 'cache-only'

Assert-True ($entries.ContainsKey($wo) -and $entries[$wo] -eq 'I / me') 'dictionary translates the known key U+6211'
Assert-True ($entries.ContainsKey($today) -and $entries[$today] -eq 'Today') 'dictionary translates the known key U+4ECA U+5929'
Assert-True ($entries.ContainsKey($schoolTraditional) -and $entries[$schoolTraditional] -eq 'School') 'dictionary includes the Traditional key U+5B78 U+6821'
Assert-True ($entries.ContainsKey($schoolSimplified) -and $entries[$schoolSimplified] -eq 'School') 'dictionary includes the Simplified key U+5B66 U+6821'
Assert-True ($entries.ContainsKey($noProblemTraditional) -and $entries[$noProblemTraditional] -eq "it's okay") 'dictionary supports apostrophes in values'
Assert-True (-not $entries.ContainsKey($unknown)) 'model miss key is absent from the dictionary'

$cacheSnapshot = @{
    format_version = 1
    db_schema_version = 1
    source_language = 'zh'
    target_language = 'en'
    translation_mode = 'literal'
    revision = 7
    entries = @{
        $cacheOnly = 'From cache'
        $today = 'Cache must lose'
    }
}
$cacheModel = Invoke-CacheSnapshotModel -Snapshot $cacheSnapshot
Assert-True $cacheModel.Valid 'valid V0.2 snapshot passes the static/model validator'
Assert-True ($cacheModel.WarningCount -eq 0) 'valid V0.2 snapshot emits no warning'
Assert-True ($cacheModel.Cache[$cacheOnly] -eq 'From cache') 'cache model exposes the translated_text value'

$malformedSnapshots = @(
    @{ format_version = 2; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = @{} },
    @{ format_version = 1; db_schema_version = 2; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = @{} },
    @{ format_version = 1; db_schema_version = 1; source_language = 'en'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = @{} },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'fr'; translation_mode = 'literal'; revision = 1; entries = @{} },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'natural'; revision = 1; entries = @{} },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1.5; entries = @{} },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = 'not-a-table' },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = @{ $cacheOnly = @{ zh = $cacheOnly; en = 'From cache' } } },
    @{ format_version = 1; db_schema_version = 1; source_language = 'zh'; target_language = 'en'; translation_mode = 'literal'; revision = 1; entries = @{ $cacheOnly = ('x' * 4097) } }
)
foreach ($malformedSnapshot in $malformedSnapshots) {
    $malformedResult = Invoke-CacheSnapshotModel -Snapshot $malformedSnapshot
    Assert-True (-not $malformedResult.Valid) "malformed snapshot is rejected ($($malformedResult.Reason))"
    Assert-True ($malformedResult.WarningCount -eq 1) "malformed snapshot warns exactly once ($($malformedResult.Reason))"
    Assert-True ($malformedResult.Cache.Count -eq 0) "malformed snapshot falls back to an empty cache ($($malformedResult.Reason))"
}

# Exercise the security boundary as raw snapshot text. The production loader
# implements the same canonical grammar without invoking load/loadfile, so
# program tokens can only be rejected and never executed.
$validEscapedSnapshot = @(
    'return {',
    '  format_version = 1,',
    '  db_schema_version = 1,',
    '  revision = 7,',
    "  source_language = 'zh',",
    "  target_language = 'en',",
    "  translation_mode = 'literal',",
    '  entries = {',
    "    ['a\\b'] = 'line\nquote\' and slash \\ tab\t',",
    "    ['z'] = 'last\007',",
    '  },',
    '}'
) -join "`r`n"
$validEscapedSnapshot += "`r`n"
$validTextResult = Invoke-CanonicalSnapshotTextModel -Text $validEscapedSnapshot
Assert-True $validTextResult.Valid "canonical raw snapshot text with publisher escaping is accepted ($($validTextResult.Reason))"
Assert-True ($validTextResult.Cache['a\b'] -eq ("line`nquote' and slash \ tab`t")) 'canonical Lua escaping is decoded as data'
Assert-True ($validTextResult.Cache['z'] -eq ('last' + [char]0x07)) 'canonical three-digit control escape is decoded as data'
Assert-True ($validTextResult.WarningCount -eq 0) 'canonical raw snapshot emits no warning'

$programSnapshots = @(
    "while true do end`r`n",
    "return os.execute('cmd')`r`n",
    ($validEscapedSnapshot + "collectgarbage()`r`n"),
    ($validEscapedSnapshot.Replace("  entries = {`r`n", "  entries = {`r`n    [setmetatable({}, {})] = 'x',`r`n"))
)
foreach ($programSnapshot in $programSnapshots) {
    $programResult = Invoke-CanonicalSnapshotTextModel -Text $programSnapshot
    Assert-True (-not $programResult.Valid) 'loops, function calls, and extra tokens are rejected as non-data'
    Assert-True ($programResult.Cache.Count -eq 0 -and $programResult.WarningCount -eq 1) 'rejected program text fails open with one warning'
}

$duplicateSnapshot = $validEscapedSnapshot.Replace(
    "    ['z'] = 'last\007',`r`n",
    "    ['a\\b'] = 'duplicate',`r`n    ['z'] = 'last\007',`r`n"
)
$duplicateResult = Invoke-CanonicalSnapshotTextModel -Text $duplicateSnapshot
Assert-True (-not $duplicateResult.Valid -and $duplicateResult.Reason -eq 'duplicate-key') 'duplicate entry keys reject the entire snapshot'
Assert-True ($duplicateResult.Cache.Count -eq 0 -and $duplicateResult.WarningCount -eq 1) 'duplicate keys fail open with one warning'

$oversizedEntrySnapshot = $validEscapedSnapshot.Replace("'last\007'", ("'" + ('x' * 4097) + "'"))
$oversizedEntryResult = Invoke-CanonicalSnapshotTextModel -Text $oversizedEntrySnapshot
Assert-True (-not $oversizedEntryResult.Valid -and $oversizedEntryResult.Reason -like 'entry-string:*') 'decoded strings over 4096 UTF-8 bytes are rejected'

$nonCanonicalEscapeResult = Invoke-CanonicalSnapshotTextModel -Text ($validEscapedSnapshot.Replace("'last\007'", "'last\009'"))
Assert-True (-not $nonCanonicalEscapeResult.Valid -and $nonCanonicalEscapeResult.Reason -like 'entry-string:*') 'decimal aliases for publisher named escapes are rejected as non-canonical'

$oversizedFileResult = Invoke-CanonicalSnapshotTextModel -Text ($validEscapedSnapshot + ('x' * 128)) -MaxFileBytes ([Text.Encoding]::UTF8.GetByteCount($validEscapedSnapshot))
Assert-True (-not $oversizedFileResult.Valid -and $oversizedFileResult.Reason -eq 'file-size') 'snapshot file size is checked before parsing'

$tooManyEntryLines = @(for ($entryIndex = 0; $entryIndex -le 10000; $entryIndex++) {
    "    ['k$($entryIndex.ToString('D5'))'] = 'value',"
})
$tooManyEntriesSnapshot = (@(
    'return {',
    '  format_version = 1,',
    '  db_schema_version = 1,',
    '  revision = 8,',
    "  source_language = 'zh',",
    "  target_language = 'en',",
    "  translation_mode = 'literal',",
    '  entries = {'
) + $tooManyEntryLines + @('  },', '}')) -join "`n"
$tooManyEntriesSnapshot += "`n"
$tooManyEntriesResult = Invoke-CanonicalSnapshotTextModel -Text $tooManyEntriesSnapshot
Assert-True (-not $tooManyEntriesResult.Valid -and $tooManyEntriesResult.Reason -eq 'entry-count') 'snapshots over 10000 entries are rejected before constructing the cache'
Assert-True ($tooManyEntriesResult.Cache.Count -eq 0 -and $tooManyEntriesResult.WarningCount -eq 1) 'oversized entry tables fail open with one warning'

# No independent Lua interpreter is required for this test environment.  Run
# a candidate-stream model of the production loop to verify observable
# semantics: hits, misses, dictionary precedence, comment options, identity,
# field preservation, and yield order.  Static assertions above bind the model
# to the production Lua operations that it mirrors.
$hitWithComment = New-ModelCandidate -Text $today -Comment 'native-comment' -Type 'word' -Quality 9.25 -Start 2 -End 4
$missWithComment = New-ModelCandidate -Text $unknown -Comment 'keep-this-comment' -Type 'shadow' -Quality 3.5 -Start 4 -End 7
$hitWithoutComment = New-ModelCandidate -Text $schoolTraditional -Comment $null -Type 'word' -Quality 1.25 -Start 7 -End 9
$cacheHit = New-ModelCandidate -Text $cacheOnly -Comment 'cache-comment' -Type 'word' -Quality 0.75 -Start 9 -End 10
$inputCandidates = @($hitWithComment, $missWithComment, $hitWithoutComment, $cacheHit)

$yieldedCandidates = @(Invoke-FilterModel `
    -Candidates $inputCandidates `
    -Dictionary $entries `
    -Cache $cacheModel.Cache `
    -Enabled $true `
    -PreserveExistingComment $true `
    -Prefix '' `
    -Separator $defaultSeparator)

Assert-True ($yieldedCandidates.Count -eq $inputCandidates.Count) 'filter yields one candidate for every input candidate'
for ($index = 0; $index -lt $inputCandidates.Count; $index++) {
    Assert-True ([object]::ReferenceEquals($yieldedCandidates[$index], $inputCandidates[$index])) "yield preserves candidate identity and order at index $index"
}

Assert-True ($hitWithComment.comment -eq ('native-comment' + $defaultSeparator + 'Today')) 'dictionary hit preserves an existing comment by default'
Assert-True ($missWithComment.comment -eq 'keep-this-comment') 'dictionary miss leaves the existing comment unchanged'
Assert-True ($hitWithoutComment.comment -eq 'School') 'dictionary hit without an existing comment gets only the translation'
Assert-True ($cacheHit.comment -eq ('cache-comment' + $defaultSeparator + 'From cache')) 'cache miss fallback annotates a cache-only candidate'

$dictionaryWinsCandidate = New-ModelCandidate -Text $today -Comment $null -Type 'word' -Quality 1.0 -Start 0 -End 2
$dictionaryWinsResult = @(Invoke-FilterModel `
    -Candidates @($dictionaryWinsCandidate) `
    -Dictionary $entries `
    -Cache $cacheModel.Cache `
    -Enabled $true `
    -PreserveExistingComment $true `
    -Prefix '' `
    -Separator $defaultSeparator)
Assert-True ($dictionaryWinsCandidate.comment -eq 'Today') 'built-in dictionary wins over the cache for the same text'

Assert-True ($hitWithComment.text -eq $today -and $hitWithComment.type -eq 'word' -and $hitWithComment.quality -eq 9.25 -and $hitWithComment.start -eq 2 -and $hitWithComment.end -eq 4) 'hit preserves candidate text, type, quality, and range'
Assert-True ($missWithComment.text -eq $unknown -and $missWithComment.type -eq 'shadow' -and $missWithComment.quality -eq 3.5 -and $missWithComment.start -eq 4 -and $missWithComment.end -eq 7) 'miss preserves candidate text, type, quality, and range'

$overwriteCandidate = New-ModelCandidate -Text $today -Comment 'old-comment' -Type 'word' -Quality 4.0 -Start 1 -End 3
$overwriteResult = @(Invoke-FilterModel `
    -Candidates @($overwriteCandidate) `
    -Dictionary $entries `
    -Enabled $true `
    -PreserveExistingComment $false `
    -Prefix 'EN: ' `
    -Separator $defaultSeparator)
Assert-True ([object]::ReferenceEquals($overwriteResult[0], $overwriteCandidate)) 'overwrite mode yields the same candidate object'
Assert-True ($overwriteCandidate.comment -eq 'EN: Today') 'overwrite mode replaces an existing comment'

$disabledCandidate = New-ModelCandidate -Text $today -Comment 'disabled-comment' -Type 'word' -Quality 2.0 -Start 0 -End 2
$disabledResult = @(Invoke-FilterModel `
    -Candidates @($disabledCandidate) `
    -Dictionary $entries `
    -Enabled $false `
    -PreserveExistingComment $true `
    -Prefix '' `
    -Separator $defaultSeparator)
Assert-True ([object]::ReferenceEquals($disabledResult[0], $disabledCandidate)) 'disabled mode yields the same candidate object'
Assert-True ($disabledCandidate.comment -eq 'disabled-comment') 'disabled mode leaves the candidate comment unchanged'

Write-Output "STATIC/MODEL checks passed ($($entries.Count) dictionary entries); UTF-8 payload, cache validation, and candidate behavior model passed."
Write-Output 'PRODUCTION RUNTIME checks: not executed; a Weasel/librime-lua host is required for genuine init/func execution.'
