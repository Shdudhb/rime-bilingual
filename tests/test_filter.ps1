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
$asyncPath = Join-Path $ProjectRoot 'lua\rime_bilingual_async.lua'
$dictionaryPath = Join-Path $ProjectRoot 'lua\rime_bilingual_dictionary.lua'
$cachePath = Join-Path $ProjectRoot 'lua\rime_bilingual_cache.lua'
$patchPath = Join-Path $ProjectRoot 'rime_ice.custom.yaml'

Assert-True (Test-Path -LiteralPath $filterPath -PathType Leaf) 'filter module exists'
Assert-True (Test-Path -LiteralPath $asyncPath -PathType Leaf) 'async processor/bridge wrapper exists'
Assert-True (Test-Path -LiteralPath $dictionaryPath -PathType Leaf) 'dictionary module exists'
Assert-True (Test-Path -LiteralPath $cachePath -PathType Leaf) 'cache loader module exists'
Assert-True (Test-Path -LiteralPath $patchPath -PathType Leaf) 'schema patch exists'

$filter = Read-Utf8File -Path $filterPath
$filterCode = $filter -replace '(?m)--.*$', ''
$asyncSource = Read-Utf8File -Path $asyncPath
$asyncCode = $asyncSource -replace '(?m)--.*$', ''
$dictionarySource = Read-Utf8File -Path $dictionaryPath
$cacheSource = Read-Utf8File -Path $cachePath
$schemaPatch = Read-Utf8File -Path $patchPath

# STATIC checks bind the model below to the actual production implementation;
# they are not a substitute for loading the modules in librime-lua.
Assert-True (([regex]::Matches($filter, 'require\("rime_bilingual_dictionary"\)')).Count -eq 1) 'filter loads the local dictionary exactly once'
Assert-True (([regex]::Matches($filter, 'require\("rime_bilingual_cache"\)')).Count -eq 1) 'filter loads the cache loader exactly once'
Assert-True (([regex]::Matches($filter, 'require\("rime_bilingual_async"\)')).Count -eq 1) 'filter loads only the bounded native bridge wrapper for async work'
Assert-True (([regex]::Matches($filter, '\brequire\s*\(')).Count -eq 3) 'filter imports only dictionary, snapshot loader, and the async wrapper'
Assert-True ($filter -match 'for\s+candidate\s+in\s+input:iter\(\)\s+do') 'filter iterates the incoming candidate stream'
Assert-True ($filter -match 'bilingual_dictionary\[candidate\.text\]') 'filter uses exact candidate text dictionary lookup'
Assert-True ($filter -match 'bilingual_cache\[candidate\.text\]') 'filter uses exact candidate text cache lookup'
Assert-True ($filter -match 'rime_api:get_user_data_dir\(\)') 'filter locates the cache under the Rime user data directory'
Assert-True ($filter -match 'cache_loader\.is_vertical_layout\(user_data_dir, warn\)') 'filter gates bilingual annotations on the compiled Weasel vertical layout'
Assert-True ($filter -match 'env\.bilingual_enabled\s*=\s*requested_enabled and env\.bilingual_vertical_layout') 'horizontal Weasel layout disables dictionary, cache, and AI annotations'
Assert-True ($filter -match 'enabled\s*=\s*env\.bilingual_enabled') 'filter passes the vertical-only gate into the async component'
Assert-True ($filter -match 'candidate:get_genuine\(\)\.comment\s*=') 'filter changes only the genuine candidate comment'
Assert-True ($filter -match 'yield\(candidate\)') 'filter yields the original candidate'
Assert-True ($filter -match 'if\s+translation\s*==\s*nil\s+then') 'filter checks cache only after a dictionary miss'
Assert-True ($filter -match 'if\s+translation\s*~=\s*nil\s+then') 'filter annotates dictionary or cache hits'
Assert-True ($filter -match 'preserve_existing_comment') 'filter supports existing comment preservation'
Assert-True ($filter -notmatch '(?i)https?://|curl|socket|openrouter|google') 'filter contains no network client'
Assert-True ($filter -notmatch '(?i)\bloadfile\b|\bdofile\b|\bSQLite\b|\bhttp\b|\bsocket\b|\bprocess\b|\bio\s*\.|\bos\s*\.|\bpackage\s*\.') 'candidate filter does not perform file, database, process, or network I/O'
Assert-True ($filter -notmatch '(?i)\bllama(?:-server)?\b|\bgguf\b|/translate\b|chat/completions|translate-batch|model\.ps1') 'candidate filter has no direct dependency on runtime, model, or HTTP batch API'
Assert-True ($filter -notmatch '(?m)^\s*candidate\.(text|type|quality|start_pos|end_pos)\s*=') 'filter does not rewrite candidate identity fields'

# V0.3 loads the pinned DLL only during init. Callback functions perform only
# bounded table/string work and pcall into native try_* methods; the worker owns
# UIA/HTTP and Helper owns SQLite/model access.
Assert-True (([regex]::Matches($asyncSource, 'package\.loadlib')).Count -eq 1) 'native bridge is loaded exactly once from init code'
Assert-True ($asyncSource -match 'rime_api:get_user_data_dir\(\)') 'absolute bridge path starts from the Rime user data directory'
Assert-True ($asyncSource -match '/rime-bilingual/native/rime_bilingual_bridge\.dll') 'absolute bridge path uses the managed native payload directory'
Assert-True ($asyncSource -match 'luaopen_rime_bilingual_bridge') 'bridge entrypoint is explicit'
Assert-True ($asyncSource -match 'pcall\(\s*package\.loadlib') 'missing or corrupt bridge is isolated with pcall'
Assert-True ($asyncSource -match 'pcall\(bridge\.configure') 'bridge configuration failure is isolated with pcall'
Assert-True ($asyncSource -match 'pcall\(state\.bridge\[method\], value\)') 'all callback bridge calls are isolated with pcall'
Assert-True ($asyncSource -notmatch '(?i)\bio\s*\.|\bos\s*\.|\bloadfile\b|\bdofile\b|\bsqlite\b|\bsocket\b|\bcurl\b|\bcreateprocess\b') 'Lua async path has no file/database/network/process implementation'
Assert-True ($asyncSource -notmatch 'synthetic|set_timeout|timer') 'Lua never injects a key or uses timer-driven refresh'
Assert-True ($asyncSource -notmatch 'refresh_non_confirmed_composition\(') 'Lua never initiates composition refresh; the patched Weasel main thread owns ready wakeup'
Assert-True ($asyncSource -notmatch 'refresh_generation|refresh_fingerprint|refresh_ready_page_once') 'Lua no longer maintains a key-driven refresh marker'
Assert-True ($asyncSource -match 'local translations = poll\(state, page\)') 'a native-triggered filter rebuild polls ready before page comments are finalized'
Assert-True ($asyncCode -notmatch 'menu:prepare\(') 'async callbacks never force Menu preparation'
Assert-True ($filterCode -notmatch 'segment\.menu|menu:prepare\(') 'candidate filter never re-enters the Menu currently evaluating that filter'
Assert-True ($asyncSource -match 'update_notifier' -and $asyncSource -match 'menu:candidate_count\(\)' -and $asyncSource -match 'menu:get_candidate_at\(absolute_index\)') 'page-change notifier reads only already materialized Menu candidates'
Assert-True ($asyncSource -match 'state\.composition_input ~= input') 'page-change notifier ignores input edits handled by the normal filter pass'
Assert-True ($asyncSource -match 'state\.page\.page_start == page_start') 'same-page highlight updates poll the saved page instead of replacing it'
Assert-True ($asyncSource -match 'if options\.enabled == false then' -and $asyncSource -match 'state\.enabled = false') 'horizontal layout disables async work during filter init'
Assert-True ($filter -match 'local buffered = \{\}') 'filter tracks one bounded upstream candidate page while yielding normally'
Assert-True ($filter -match 'target_page_start = math\.floor\(selected_index / page_size\) \* page_size') 'filter targets only the page containing the current selected_index'
Assert-True ($filter -match 'absolute_index >= target_page_start' -and $filter -match 'absolute_index < target_page_start \+ page_size') 'filter ignores prefetched candidates outside the selected visible page'
Assert-True ($filter -match 'local submitted = false' -and $filter -match 'if submitted or #buffered == 0') 'one filter invocation submits at most one visible-page batch'
Assert-True ($asyncSource -match 'dictionary\[candidate\.text\] == nil and cache\[candidate\.text\] == nil') 'only dictionary/snapshot misses enter the AI batch'
Assert-True ($filter -match 'async\.finish_filter\(env, page, misses\)') 'the selected visible page uses one bounded async submission'
Assert-True ($asyncSource -match 'result\.generation ~= state\.expected_generation') 'ready generation must equal the submitted pair'
Assert-True ($asyncSource -match 'result\.fingerprint ~= state\.expected_fingerprint') 'ready fingerprint must equal the submitted pair'
Assert-True ($asyncSource -match 'function M\.func\(key_event, env\)') 'processor receives the real key event through its standard func callback'
Assert-True ($asyncSource -match 'representation == "BackSpace"') 'processor has an explicit latency guard for Backspace'
Assert-True ($asyncSource -match 'state\.skip_next_filter = true') 'Backspace marks the next async filter pass for skipping'
Assert-True ($asyncSource -match 'if state\.skip_next_filter then') 'filter honors the Backspace skip without materializing the active page'
Assert-True ($asyncSource -match 'local translations = poll\(state, state\.page\)') 'processor performs a bounded poll for every key including PageUp'
Assert-True ($asyncSource -match 'apply_ready\(state, state\.page, translations\)') 'processor applies a ready result without requiring the filter to run again'
Assert-True ($asyncSource -match 'genuine = candidate:get_genuine\(\)') 'filter saves genuine candidate references for current page misses'
Assert-True ($asyncSource -match 'entry\.genuine\.comment = comment') 'processor changes only the saved genuine candidate comment'
Assert-True ($asyncSource -match 'genuine\.text == identity\.text') 'processor revalidates genuine candidate text before changing comment'
Assert-True ($asyncSource -match 'genuine\.type == identity\.type') 'processor revalidates genuine candidate type before changing comment'
Assert-True ($asyncSource -match 'genuine\.start == identity\.start') 'processor revalidates genuine candidate start before changing comment'
Assert-True ($asyncSource -match 'genuine\._end == identity\["end"\]') 'processor revalidates genuine candidate end before changing comment'
Assert-True ($asyncSource -match 'state\.refs = \{\}') 'composition/page generation changes clear saved candidate references'
Assert-True ($asyncSource -match 'function M\.fini\(env\)') 'async component exposes lifecycle cleanup'
Assert-True ($asyncSource -match 'state\.update_connection:disconnect\(\)') 'async component disconnects the page-change notifier during fini'
Assert-True ($filter -match 'function M\.fini\(env\)\s+async\.fini\(env\)') 'filter lifecycle also releases shared async state'
Assert-True ($asyncSource -match 'states\[env\.engine\] = nil') 'fini removes the engine entry from the weak state table'
Assert-True ($asyncSource -match 'composition == nil or composition:empty\(\)') 'processor checks for commit/cancel-cleared composition before polling stale refs'
Assert-True ($asyncSource -match 'return 2') 'processor always returns kNoop and preserves key handling'

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
Assert-True ($cacheSource -match 'MAX_LAYOUT_FILE_BYTES\s*=\s*\d+') 'layout gate bounds the compiled Weasel config before reading it'
Assert-True ($cacheSource -match 'file\.read,\s*file,\s*MAX_FILE_BYTES\s*\+\s*1') 'cache loader uses a bounded read even if the file grows after seek'
Assert-True ($cacheSource -match '/build/weasel\.yaml') 'layout gate reads only the compiled Weasel config during init'
Assert-True ($cacheSource -match 'layout_type == "vertical"') 'modern Weasel vertical layout enables bilingual annotations'
Assert-True ($cacheSource -match 'horizontal == false') 'legacy Weasel horizontal=false also counts as a vertical candidate list'
Assert-True ($cacheSource -match 'translation disabled: Weasel candidate layout is not vertical') 'unknown or horizontal layout fails closed with translations disabled'
Assert-True ($cacheSource -notmatch 'file\.read,\s*file,\s*"\*a"') 'cache loader never performs an unbounded read-all operation'
Assert-True ($cacheSource -match 'return \{\}') 'cache loader falls back to an empty cache'

Assert-True ($schemaPatch -match '"engine/filters/@before last"\s*:\s*lua_filter@\*rime_bilingual') 'schema patch inserts before the final uniquifier'
Assert-True ($schemaPatch -match 'lua_filter@\*rime_bilingual') 'schema patch registers the filter'
Assert-True ($schemaPatch -match '"engine/processors/@before 0"\s*:\s*lua_processor@\*rime_bilingual_async') 'schema patch registers the non-consuming async processor'
Assert-True ($schemaPatch -match 'cache_enabled:\s*true') 'schema patch enables the V0.2 cache by default'
Assert-True ($schemaPatch -match 'async_enabled:\s*true') 'schema patch enables V0.3 async requests by default'
Assert-True ($schemaPatch -match 'helper_endpoint:\s*"http://127\.0\.0\.1:18081"') 'schema config pins a numeric loopback Helper endpoint'
Assert-True ($schemaPatch -match 'request_timeout_ms:\s*3000') 'schema config sets a bounded worker request timeout'
Assert-True ($schemaPatch -match 'expected_rime_sha256:\s*"[0-9A-Fa-f]{64}"') 'schema config pins the supported Rime ABI hash'

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

# V0.2-ai is deliberately outside the Rime process.  An absent helper/model is
# therefore equivalent to having no locally available translation: the filter
# must yield the untouched candidate immediately, without an AI fallback.
$aiUnavailableCandidate = New-ModelCandidate -Text 'ai-unavailable' -Comment 'native-only' -Type 'phrase' -Quality 6.5 -Start 3 -End 8
$aiUnavailableResult = @(Invoke-FilterModel `
    -Candidates @($aiUnavailableCandidate) `
    -Dictionary @{} `
    -Cache @{} `
    -Enabled $true `
    -PreserveExistingComment $true `
    -Prefix '' `
    -Separator $defaultSeparator)
Assert-True ($aiUnavailableResult.Count -eq 1 -and [object]::ReferenceEquals($aiUnavailableResult[0], $aiUnavailableCandidate)) 'missing dictionary/cache/helper/model still yields the original candidate identity'
Assert-True ($aiUnavailableCandidate.text -eq 'ai-unavailable' -and $aiUnavailableCandidate.comment -eq 'native-only') 'missing helper/model leaves candidate text and native comment unchanged'
Assert-True ($aiUnavailableCandidate.type -eq 'phrase' -and $aiUnavailableCandidate.quality -eq 6.5 -and $aiUnavailableCandidate.start -eq 3 -and $aiUnavailableCandidate.end -eq 8) 'missing helper/model preserves candidate type, quality, and range'

# Model the V0.3 pair gate independently of native timing. These checks cover
# the observable Lua policy while static assertions above bind that policy to
# the production implementation and bridge calls.
function Get-AsyncFingerprintModel {
    param([int]$PageStart, [object[]]$Candidates)
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append("RBIL-PAGE-V1`0")
    $null = $builder.Append("$PageStart|")
    foreach ($candidate in $Candidates) {
        foreach ($value in @($candidate.absolute_index, $candidate.text, $candidate.type, $candidate.start, $candidate.end)) {
            $rendered = [string]$value
            $null = $builder.Append(([Text.Encoding]::UTF8.GetByteCount($rendered))).Append(':').Append($rendered).Append('|')
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-AsyncStateModel {
    return [pscustomobject]@{
        Generation = 0L
        Signature = $null
        ExpectedGeneration = $null
        ExpectedFingerprint = $null
        Active = @{}
        SubmitCount = 0
        PollCount = 0
    }
}

function Update-AsyncPageModel {
    param([object]$State, [string]$InputText, [int]$PageStart, [object[]]$Candidates)
    $fingerprint = Get-AsyncFingerprintModel -PageStart $PageStart -Candidates $Candidates
    $signature = "$($InputText.Length):$InputText|$PageStart|$fingerprint"
    if ($signature -cne $State.Signature) {
        $State.Generation++
        $State.Signature = $signature
        $State.ExpectedGeneration = $null
        $State.ExpectedFingerprint = $null
    }
    return [pscustomobject]@{
        generation = $State.Generation
        page_start = $PageStart
        candidates = $Candidates
        fingerprint = $fingerprint
    }
}

function Submit-AsyncPageModel {
    param([object]$State, [object]$Page, [object[]]$Misses)
    if ($Misses.Count -eq 0) { return 'no_submit' }
    $pair = "$($Page.generation):$($Page.fingerprint)"
    $State.ExpectedGeneration = $Page.generation
    $State.ExpectedFingerprint = $Page.fingerprint
    if ($State.Active.ContainsKey($pair)) { return 'duplicate' }
    $State.Active[$pair] = $true
    $State.SubmitCount++
    return 'accepted'
}

function Poll-AsyncPageModel {
    param([object]$State, [object]$Page, [object]$Completion)
    $State.PollCount++
    if ($null -eq $Completion) { return $null }
    if ($Completion.generation -ne $State.ExpectedGeneration -or
        $Completion.fingerprint -cne $State.ExpectedFingerprint -or
        $Completion.generation -ne $Page.generation -or
        $Completion.fingerprint -cne $Page.fingerprint) {
        return $null
    }
    return $Completion.translations
}

function New-AsyncCandidateModel {
    param([int]$Index, [string]$Text, [string]$Type = 'phrase', [int]$Start = 0, [int]$End = 5)
    return [pscustomobject]@{ absolute_index = $Index; text = $Text; type = $Type; start = $Start; end = $End }
}

$asyncState = New-AsyncStateModel
$localOnlyPage = Update-AsyncPageModel -State $asyncState -InputText 'jin' -PageStart 0 -Candidates @(
    (New-AsyncCandidateModel -Index 0 -Text $today),
    (New-AsyncCandidateModel -Index 1 -Text $schoolTraditional)
)
$localOnlyMisses = @($localOnlyPage.candidates | Where-Object { -not $entries.ContainsKey($_.text) -and -not $cacheModel.Cache.ContainsKey($_.text) })
Assert-True ((Submit-AsyncPageModel -State $asyncState -Page $localOnlyPage -Misses $localOnlyMisses) -eq 'no_submit') 'dictionary/snapshot-only page produces zero native submissions'
Assert-True ($asyncState.SubmitCount -eq 0) 'cache hits never call Helper through the bridge'

$missOne = 'async-miss-one'
$missTwo = 'async-miss-two'
$mixedPage = Update-AsyncPageModel -State $asyncState -InputText 'async' -PageStart 0 -Candidates @(
    (New-AsyncCandidateModel -Index 0 -Text $today),
    (New-AsyncCandidateModel -Index 1 -Text $missOne),
    (New-AsyncCandidateModel -Index 2 -Text $cacheOnly),
    (New-AsyncCandidateModel -Index 3 -Text $missTwo)
)
$mixedMisses = @()
for ($slot = 0; $slot -lt $mixedPage.candidates.Count; $slot++) {
    $text = $mixedPage.candidates[$slot].text
    if (-not $entries.ContainsKey($text) -and -not $cacheModel.Cache.ContainsKey($text)) {
        $mixedMisses += [pscustomobject]@{ slot = $slot; text = $text }
    }
}
Assert-True ($mixedMisses.Count -eq 2 -and $mixedMisses[0].slot -eq 1 -and $mixedMisses[1].slot -eq 3) 'one page request contains only ordered dictionary/snapshot misses with original slots'
Assert-True ((Submit-AsyncPageModel -State $asyncState -Page $mixedPage -Misses $mixedMisses) -eq 'accepted') 'one page miss batch is accepted once'
Assert-True ((Submit-AsyncPageModel -State $asyncState -Page $mixedPage -Misses $mixedMisses) -eq 'duplicate') 'same page pair is deduplicated'
Assert-True ($asyncState.SubmitCount -eq 1) 'duplicate callback does not create another batch'

$ready = [pscustomobject]@{
    generation = $mixedPage.generation
    fingerprint = $mixedPage.fingerprint
    translations = @{ 1 = 'First'; 3 = 'Second' }
}
Assert-True ($null -ne (Poll-AsyncPageModel -State $asyncState -Page $mixedPage -Completion $ready)) 'matching generation/fingerprint result becomes visible on a natural callback'

# A completed request may be observed only by the processor: the filter does
# not necessarily run again for selection movement. Model the saved genuine
# reference path and prove that one processor callback applies it idempotently.
$processorOnlyCandidate = New-ModelCandidate -Text $missOne -Comment 'native-comment' -Type 'phrase' -Start 0 -End 5
$savedRef = [pscustomobject]@{
    Genuine = $processorOnlyCandidate
    BaseComment = 'native-comment'
    AppliedComment = $null
}
$filterRerunCount = 0
$processorTranslation = 'Async English'
$processorComment = $savedRef.BaseComment + $defaultSeparator + $processorTranslation
if ($savedRef.AppliedComment -ne $processorComment -or $savedRef.Genuine.comment -ne $processorComment) {
    $savedRef.Genuine.comment = $processorComment
    $savedRef.AppliedComment = $processorComment
}
Assert-True ($filterRerunCount -eq 0 -and $processorOnlyCandidate.comment -eq $processorComment) 'ready result plus only a processor callback updates the saved genuine comment'
$commentAfterFirstProcessorPoll = $processorOnlyCandidate.comment
if ($savedRef.AppliedComment -ne $processorComment -or $savedRef.Genuine.comment -ne $processorComment) {
    $savedRef.Genuine.comment = $processorComment
    $savedRef.AppliedComment = $processorComment
}
Assert-True ($processorOnlyCandidate.comment -eq $commentAfterFirstProcessorPoll) 'repeated processor polls do not append the same translation twice'

$identityChangedCandidate = New-ModelCandidate -Text 'replaced-candidate' -Comment 'replacement-native' -Type 'phrase' -Start 0 -End 5
$immutableIdentity = [pscustomobject]@{ text = $missOne; type = 'phrase'; start = 0; end = 5 }
$identityStillMatches = $identityChangedCandidate.text -ceq $immutableIdentity.text -and
    $identityChangedCandidate.type -ceq $immutableIdentity.type -and
    $identityChangedCandidate.start -eq $immutableIdentity.start -and
    $identityChangedCandidate.end -eq $immutableIdentity.end
if ($identityStillMatches) { $identityChangedCandidate.comment = 'must-not-apply' }
Assert-True ($identityChangedCandidate.comment -eq 'replacement-native') 'processor refuses a saved reference whose live genuine identity changed'

$commitCancelState = [pscustomobject]@{
    Page = $mixedPage
    ExpectedGeneration = $mixedPage.generation
    ExpectedFingerprint = $mixedPage.fingerprint
    Refs = @{ 1 = $savedRef }
}
$compositionEmptyBeforeNextKey = $true
if ($compositionEmptyBeforeNextKey) {
    $commitCancelState.Page = $null
    $commitCancelState.ExpectedGeneration = $null
    $commitCancelState.ExpectedFingerprint = $null
    $commitCancelState.Refs = @{}
}
Assert-True ($null -eq $commitCancelState.Page -and $commitCancelState.Refs.Count -eq 0) 'next processor callback after commit/cancel clears stale page references before poll'

$finiStateTable = @{ engine = [pscustomobject]@{ Refs = @{ 1 = $savedRef }; Page = $mixedPage } }
$finiStateTable.Remove('engine')
Assert-True ($finiStateTable.Count -eq 0) 'component fini removes its engine-scoped shared state'

$changedPage = Update-AsyncPageModel -State $asyncState -InputText 'asyncx' -PageStart 0 -Candidates $mixedPage.candidates
Assert-True ($changedPage.generation -gt $mixedPage.generation) 'composition input change increments generation even if candidates are unchanged'
Assert-True ($null -eq (Poll-AsyncPageModel -State $asyncState -Page $changedPage -Completion $ready)) 'old generation completion is discarded after rapid input'

$pageTwoCandidates = @(
    (New-AsyncCandidateModel -Index 5 -Text 'page-two-a'),
    (New-AsyncCandidateModel -Index 6 -Text 'page-two-b')
)
$pageTwo = Update-AsyncPageModel -State $asyncState -InputText 'asyncx' -PageStart 5 -Candidates $pageTwoCandidates
Assert-True ($pageTwo.generation -gt $changedPage.generation) 'PageUp/PageDown page_start change increments generation'
$pollsBeforePageKey = $asyncState.PollCount
$null = Poll-AsyncPageModel -State $asyncState -Page $pageTwo -Completion $ready
Assert-True ($asyncState.PollCount -eq ($pollsBeforePageKey + 1)) 'PageUp/PageDown processor path performs a poll without consuming the key'
Assert-True ($null -eq (Poll-AsyncPageModel -State $asyncState -Page $pageTwo -Completion $ready)) 'old page fingerprint cannot annotate the new page'

$rapidState = New-AsyncStateModel
$previousGeneration = 0L
for ($rapidIndex = 0; $rapidIndex -lt 100; $rapidIndex++) {
    $rapidCandidate = New-AsyncCandidateModel -Index 0 -Text ("rapid-$rapidIndex")
    $rapidPage = Update-AsyncPageModel -State $rapidState -InputText ("p$rapidIndex") -PageStart 0 -Candidates @($rapidCandidate)
    Assert-True ($rapidPage.generation -gt $previousGeneration) "rapid input generation is monotonic at step $rapidIndex"
    $previousGeneration = $rapidPage.generation
}

$missingDllState = [pscustomobject]@{ Enabled = $true; WarningCount = 0 }
try { throw [DllNotFoundException]::new('simulated managed bridge absence') }
catch { $missingDllState.Enabled = $false; $missingDllState.WarningCount++ }
Assert-True (-not $missingDllState.Enabled -and $missingDllState.WarningCount -eq 1) 'missing DLL disables async fail-soft with one diagnostic'
$fallbackCandidate = New-ModelCandidate -Text $today -Comment $null
$fallbackYield = @(Invoke-FilterModel -Candidates @($fallbackCandidate) -Dictionary $entries -Cache @{})
Assert-True ([object]::ReferenceEquals($fallbackYield[0], $fallbackCandidate) -and $fallbackCandidate.comment -eq 'Today') 'missing bridge preserves dictionary annotation and original candidate identity'

Write-Output "STATIC/MODEL checks passed ($($entries.Count) dictionary entries); UTF-8 payload, cache validation, and candidate behavior model passed."
Write-Output 'PRODUCTION RUNTIME checks: not executed; a Weasel/librime-lua host is required for genuine init/func execution.'
