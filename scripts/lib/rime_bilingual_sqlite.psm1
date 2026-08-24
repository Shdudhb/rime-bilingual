Set-StrictMode -Version 2.0

# V0.2 deliberately uses only the SQLite ABI that Windows ships as
# winsqlite3.dll.  No PowerShell provider, sqlite3.exe, Python, or network
# dependency is required by this module.
$script:SchemaVersion = 1
$script:ApplicationId = 1380075852 # ASCII "RBIL" (0x5242494C)
$script:SourceLanguage = 'zh'
$script:TargetLanguage = 'en'
$script:TranslationMode = 'literal'
$script:MaxRuntimeEntries = 10000
$script:MaxRuntimeStringBytes = 4096
$script:MaxSnapshotBytes = 16 * 1024 * 1024
$script:MaxRuntimeRevision = 2147483647
$script:SqliteOk = 0
$script:SqliteRow = 100
$script:SqliteDone = 101
$script:SqliteInteger = 1
$script:SqliteFloat = 2
$script:SqliteText = 3
$script:SqliteBlob = 4
$script:SqliteNull = 5
$script:SqliteOpenReadOnly = 0x00000001
$script:SqliteOpenReadWrite = 0x00000002
$script:SqliteOpenCreate = 0x00000004
$script:SqliteOpenFullMutex = 0x00010000
$script:SqliteTransient = [IntPtr](-1)
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Initialize-RimeBilingualNativeSqlite {
    if ($null -eq ('RimeBilingual.NativeSqlite' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RimeBilingual
{
    public static class NativeSqlite
    {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_open_v2(IntPtr filename, out IntPtr db, int flags, IntPtr zVfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_close_v2(IntPtr db);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_prepare_v2(IntPtr db, IntPtr sql, int byteCount, out IntPtr statement, IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_parameter_count(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_null(IntPtr statement, int index);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_int(IntPtr statement, int index, int value);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_double(IntPtr statement, int index, double value);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_text(IntPtr statement, int index, IntPtr value, int byteCount, IntPtr destructor);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_blob(IntPtr statement, int index, byte[] value, int byteCount, IntPtr destructor);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_count(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_name(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_type(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_int(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern long sqlite3_column_int64(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern double sqlite3_column_double(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_bytes(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_errmsg(IntPtr db);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_changes(IntPtr db);

        public static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);
    }
}
'@ -Language CSharp
    }
}

Initialize-RimeBilingualNativeSqlite

function Get-RimeBilingualDefaultPaths {
    [CmdletBinding()]
    param(
        [string]$RimeRoot = (Join-Path $env:APPDATA 'Rime')
    )

    if ([string]::IsNullOrWhiteSpace($RimeRoot)) {
        throw 'RimeRoot must not be empty.'
    }

    $cacheRoot = Join-Path $RimeRoot 'rime-bilingual'
    return [pscustomobject]@{
        CacheRoot      = $cacheRoot
        DatabasePath   = Join-Path $cacheRoot 'translations.db'
        SnapshotPath   = Join-Path $cacheRoot 'cache_snapshot.lua'
        SchemaVersion  = $script:SchemaVersion
        ApplicationId  = $script:ApplicationId
        SourceLanguage = $script:SourceLanguage
        TargetLanguage = $script:TargetLanguage
        TranslationMode = $script:TranslationMode
    }
}

function New-RimeBilingualUtf8Buffer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $bytes = $script:Utf8.GetBytes($Value)
    $pointer = [System.IntPtr]::Zero
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length + 1)
        if ($bytes.Length -gt 0) {
            [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $pointer, $bytes.Length)
        }
        [System.Runtime.InteropServices.Marshal]::WriteByte($pointer, $bytes.Length, 0)
        return [pscustomobject]@{
            Pointer = $pointer
            Length  = $bytes.Length
        }
    }
    catch {
        if ($pointer -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
        }
        throw
    }
}

function Remove-RimeBilingualUtf8Buffer {
    param([System.IntPtr]$Pointer)
    if ($Pointer -ne [System.IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Pointer)
    }
}

function Convert-RimeBilingualUtf8Pointer {
    param(
        [System.IntPtr]$Pointer,
        [int]$Length = -1
    )

    if ($Pointer -eq [System.IntPtr]::Zero) {
        return $null
    }

    if ($Length -lt 0) {
        $Length = 0
        while ($Length -lt 1048576 -and
            [System.Runtime.InteropServices.Marshal]::ReadByte($Pointer, $Length) -ne 0) {
            $Length++
        }
    }

    if ($Length -lt 0 -or $Length -gt 1048576) {
        throw 'SQLite returned an invalid UTF-8 string length.'
    }

    $bytes = New-Object byte[] $Length
    if ($Length -gt 0) {
        [System.Runtime.InteropServices.Marshal]::Copy($Pointer, $bytes, 0, $Length)
    }
    try {
        return $script:Utf8.GetString($bytes)
    }
    catch {
        throw 'SQLite returned text that is not valid UTF-8.'
    }
}

function Get-RimeBilingualSqliteError {
    param([System.IntPtr]$Database)
    if ($Database -eq [System.IntPtr]::Zero) {
        return 'SQLite could not open the database.'
    }

    try {
        $message = Convert-RimeBilingualUtf8Pointer ([RimeBilingual.NativeSqlite]::sqlite3_errmsg($Database))
        if ([string]::IsNullOrEmpty($message)) {
            return 'SQLite returned no error message.'
        }
        return $message
    }
    catch {
        return 'SQLite returned an unreadable error message.'
    }
}

function Assert-RimeBilingualSqliteResult {
    param(
        [int]$Result,
        [System.IntPtr]$Database,
        [string]$Operation
    )

    if ($Result -ne $script:SqliteOk) {
        $message = Get-RimeBilingualSqliteError -Database $Database
        throw ("SQLite {0} failed (code {1}): {2}" -f $Operation, $Result, $message)
    }
}

function Open-RimeBilingualDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,
        [switch]$ReadOnly
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        throw 'DatabasePath must not be empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($DatabasePath)
    if ($ReadOnly -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "SQLite database does not exist: '$fullPath'."
    }

    if (-not $ReadOnly) {
        $parent = Split-Path -Parent $fullPath
        if (-not [string]::IsNullOrEmpty($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    $pathBuffer = New-RimeBilingualUtf8Buffer -Value $fullPath
    $database = [System.IntPtr]::Zero
    $flags = $script:SqliteOpenFullMutex
    if ($ReadOnly) {
        $flags = $flags -bor $script:SqliteOpenReadOnly
    }
    else {
        $flags = $flags -bor $script:SqliteOpenReadWrite -bor $script:SqliteOpenCreate
    }

    try {
        $result = [RimeBilingual.NativeSqlite]::sqlite3_open_v2(
            $pathBuffer.Pointer,
            [ref]$database,
            $flags,
            [System.IntPtr]::Zero
        )
        if ($result -ne $script:SqliteOk) {
            $message = Get-RimeBilingualSqliteError -Database $database
            if ($database -ne [System.IntPtr]::Zero) {
                [void][RimeBilingual.NativeSqlite]::sqlite3_close_v2($database)
            }
            throw ("SQLite sqlite3_open_v2 failed (code {0}): {1}" -f $result, $message)
        }

        $result = [RimeBilingual.NativeSqlite]::sqlite3_busy_timeout($database, 5000)
        Assert-RimeBilingualSqliteResult -Result $result -Database $database -Operation 'sqlite3_busy_timeout'
        return $database
    }
    finally {
        Remove-RimeBilingualUtf8Buffer -Pointer $pathBuffer.Pointer
    }
}

function Close-RimeBilingualDatabase {
    param([System.IntPtr]$Database)
    if ($Database -ne [System.IntPtr]::Zero) {
        $result = [RimeBilingual.NativeSqlite]::sqlite3_close_v2($Database)
        if ($result -ne $script:SqliteOk) {
            throw ("SQLite sqlite3_close_v2 failed (code {0})." -f $result)
        }
    }
}

function ConvertTo-RimeBilingualSqliteParameter {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return [pscustomobject]@{ Kind = 'null'; Value = $null }
    }
    if ($Value -is [bool]) {
        return [pscustomobject]@{ Kind = 'int'; Value = [int]$Value }
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32]) {
        return [pscustomobject]@{ Kind = 'int'; Value = [int]$Value }
    }
    if ($Value -is [int64] -or $Value -is [uint64] -or $Value -is [long]) {
        return [pscustomobject]@{ Kind = 'int64'; Value = [long]$Value }
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [pscustomobject]@{ Kind = 'double'; Value = [double]$Value }
    }
    if ($Value -is [byte[]]) {
        return [pscustomobject]@{ Kind = 'blob'; Value = $Value }
    }
    return [pscustomobject]@{ Kind = 'text'; Value = [string]$Value }
}

function Invoke-RimeBilingualSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IntPtr]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [object[]]$Parameters = @(),
        [switch]$Query
    )

    $sqlBuffer = New-RimeBilingualUtf8Buffer -Value $Sql
    $statement = [System.IntPtr]::Zero
    $buffers = @()
    try {
        $result = [RimeBilingual.NativeSqlite]::sqlite3_prepare_v2(
            $Database,
            $sqlBuffer.Pointer,
            $sqlBuffer.Length,
            [ref]$statement,
            [System.IntPtr]::Zero
        )
        Assert-RimeBilingualSqliteResult -Result $result -Database $Database -Operation 'sqlite3_prepare_v2'

        $expectedParameters = [RimeBilingual.NativeSqlite]::sqlite3_bind_parameter_count($statement)
        $actualParameters = @($Parameters).Count
        if ($expectedParameters -ne $actualParameters) {
            throw ("SQLite statement expected {0} parameters but received {1}." -f $expectedParameters, $actualParameters)
        }

        for ($index = 0; $index -lt $actualParameters; $index++) {
            $parameter = ConvertTo-RimeBilingualSqliteParameter -Value $Parameters[$index]
            $bindIndex = $index + 1
            switch ($parameter.Kind) {
                'null' {
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_null($statement, $bindIndex)
                }
                'int' {
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_int($statement, $bindIndex, [int]$parameter.Value)
                }
                'int64' {
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_int64($statement, $bindIndex, [long]$parameter.Value)
                }
                'double' {
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_double($statement, $bindIndex, [double]$parameter.Value)
                }
                'blob' {
                    $bytes = [byte[]]$parameter.Value
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_blob(
                        $statement, $bindIndex, $bytes, $bytes.Length, $script:SqliteTransient
                    )
                }
                default {
                    $buffer = New-RimeBilingualUtf8Buffer -Value ([string]$parameter.Value)
                    $buffers += $buffer
                    $result = [RimeBilingual.NativeSqlite]::sqlite3_bind_text(
                        $statement, $bindIndex, $buffer.Pointer, $buffer.Length, $script:SqliteTransient
                    )
                }
            }
            Assert-RimeBilingualSqliteResult -Result $result -Database $Database -Operation ("sqlite3_bind parameter {0}" -f $bindIndex)
        }

        $rows = @()
        while ($true) {
            $result = [RimeBilingual.NativeSqlite]::sqlite3_step($statement)
            if ($result -eq $script:SqliteRow) {
                if ($Query) {
                    $row = [ordered]@{}
                    $columnCount = [RimeBilingual.NativeSqlite]::sqlite3_column_count($statement)
                    for ($column = 0; $column -lt $columnCount; $column++) {
                        $name = Convert-RimeBilingualUtf8Pointer ([RimeBilingual.NativeSqlite]::sqlite3_column_name($statement, $column))
                        if ([string]::IsNullOrEmpty($name)) {
                            $name = "column$column"
                        }
                        $type = [RimeBilingual.NativeSqlite]::sqlite3_column_type($statement, $column)
                        switch ($type) {
                            $script:SqliteInteger {
                                $value = [RimeBilingual.NativeSqlite]::sqlite3_column_int64($statement, $column)
                            }
                            $script:SqliteFloat {
                                $value = [RimeBilingual.NativeSqlite]::sqlite3_column_double($statement, $column)
                            }
                            $script:SqliteText {
                                $value = Convert-RimeBilingualUtf8Pointer `
                                    ([RimeBilingual.NativeSqlite]::sqlite3_column_text($statement, $column)) `
                                    ([RimeBilingual.NativeSqlite]::sqlite3_column_bytes($statement, $column))
                            }
                            $script:SqliteBlob {
                                $value = $null
                                throw 'Unexpected SQLite BLOB in a text cache query.'
                            }
                            default {
                                $value = $null
                            }
                        }
                        $row[$name] = $value
                    }
                    $rows += [pscustomobject]$row
                }
                continue
            }
            if ($result -eq $script:SqliteDone) {
                break
            }

            $message = Get-RimeBilingualSqliteError -Database $Database
            throw ("SQLite sqlite3_step failed (code {0}): {1}" -f $result, $message)
        }

        if ($Query) {
            return $rows
        }
        return [RimeBilingual.NativeSqlite]::sqlite3_changes($Database)
    }
    finally {
        if ($statement -ne [System.IntPtr]::Zero) {
            [void][RimeBilingual.NativeSqlite]::sqlite3_finalize($statement)
        }
        foreach ($buffer in $buffers) {
            Remove-RimeBilingualUtf8Buffer -Pointer $buffer.Pointer
        }
        Remove-RimeBilingualUtf8Buffer -Pointer $sqlBuffer.Pointer
    }
}

function Invoke-RimeBilingualTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IntPtr]$Database,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $transactionOpen = $false
    try {
        $null = Invoke-RimeBilingualSql -Database $Database -Sql 'BEGIN IMMEDIATE'
        $transactionOpen = $true
        $result = & $Body $Database
        $null = Invoke-RimeBilingualSql -Database $Database -Sql 'COMMIT'
        $transactionOpen = $false
        return $result
    }
    catch {
        if ($transactionOpen) {
            try { $null = Invoke-RimeBilingualSql -Database $Database -Sql 'ROLLBACK' } catch { }
        }
        throw
    }
}

function Get-RimeBilingualSchemaStatements {
    $schemaPath = Join-Path $PSScriptRoot '..\..\data\cache_schema.sql'
    if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
        $schemaText = [System.IO.File]::ReadAllText($schemaPath, $script:Utf8)
    }
    else {
        $schemaText = @"
PRAGMA application_id = $($script:ApplicationId);
PRAGMA user_version = $($script:SchemaVersion);
CREATE TABLE IF NOT EXISTS translations (
    source_text TEXT NOT NULL COLLATE BINARY,
    source_language TEXT NOT NULL COLLATE BINARY,
    target_language TEXT NOT NULL COLLATE BINARY,
    translation_mode TEXT NOT NULL COLLATE BINARY,
    translated_text TEXT NOT NULL,
    source TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY (source_text, source_language, target_language, translation_mode)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS cache_meta (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL,
    updated_at_utc TEXT NOT NULL
);
INSERT OR IGNORE INTO cache_meta (id, revision, updated_at_utc)
VALUES (1, 0, '1970-01-01T00:00:00.000Z');
"@
    }

    # The project schema contains no semicolons in string literals.  Keep the
    # splitter intentionally small so every statement still goes through the
    # prepared/parameterized execution path above.
    return @($schemaText -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-RimeBilingualTableInfo {
    param([System.IntPtr]$Database, [string]$TableName)
    $escaped = $TableName.Replace("'", "''")
    return @(Invoke-RimeBilingualSql -Database $Database -Sql ("PRAGMA table_info('{0}')" -f $escaped) -Query)
}

function Test-RimeBilingualSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IntPtr]$Database
    )

    $applicationRows = @(Invoke-RimeBilingualSql -Database $Database -Sql 'PRAGMA application_id' -Query)
    $versionRows = @(Invoke-RimeBilingualSql -Database $Database -Sql 'PRAGMA user_version' -Query)
    if ($applicationRows.Count -ne 1 -or $versionRows.Count -ne 1) {
        throw 'SQLite did not return application_id and user_version.'
    }
    $applicationId = [long]$applicationRows[0].application_id
    $schemaVersion = [long]$versionRows[0].user_version
    if ($applicationId -ne $script:ApplicationId) {
        throw ("Incompatible SQLite application_id {0}; expected {1}." -f $applicationId, $script:ApplicationId)
    }
    if ($schemaVersion -ne $script:SchemaVersion) {
        throw ("Incompatible SQLite user_version {0}; expected {1}." -f $schemaVersion, $script:SchemaVersion)
    }

    $translationInfo = @(Get-RimeBilingualTableInfo -Database $Database -TableName 'translations')
    $metaInfo = @(Get-RimeBilingualTableInfo -Database $Database -TableName 'cache_meta')
    $translationColumns = @('source_text', 'source_language', 'target_language', 'translation_mode', 'translated_text', 'source', 'updated_at_utc')
    $metaColumns = @('id', 'revision', 'updated_at_utc')
    if ($translationInfo.Count -ne $translationColumns.Count -or
        $metaInfo.Count -ne $metaColumns.Count) {
        throw 'SQLite cache schema is missing required columns.'
    }
    for ($index = 0; $index -lt $translationColumns.Count; $index++) {
        if ([string]$translationInfo[$index].name -ne $translationColumns[$index] -or
            [int]$translationInfo[$index].notnull -ne 1) {
            throw 'SQLite translations schema does not match the V0.2 contract.'
        }
    }
    for ($index = 0; $index -lt $metaColumns.Count; $index++) {
        if ([string]$metaInfo[$index].name -ne $metaColumns[$index] -or
            [int]$metaInfo[$index].notnull -ne 1) {
            throw 'SQLite cache_meta schema does not match the V0.2 contract.'
        }
    }

    $translationPrimaryKey = @($translationInfo | Where-Object { [int]$_.pk -gt 0 } | Sort-Object { [int]$_.pk })
    if ($translationPrimaryKey.Count -ne 4) {
        throw 'SQLite translations table must have a four-column composite primary key.'
    }
    for ($index = 0; $index -lt 4; $index++) {
        if ([string]$translationPrimaryKey[$index].name -ne $translationColumns[$index]) {
            throw 'SQLite translations composite primary key is not source/language/mode ordered.'
        }
    }

    $tableRows = @(Invoke-RimeBilingualSql -Database $Database -Sql `
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN ('translations', 'cache_meta') ORDER BY name" -Query)
    if ($tableRows.Count -ne 2) {
        throw 'SQLite cache tables are missing.'
    }
    $translationSql = [string]($tableRows | Where-Object { $_.name -eq 'translations' } | Select-Object -First 1).sql
    if ($translationSql -notmatch '(?i)WITHOUT\s+ROWID') {
        throw 'SQLite translations table must be WITHOUT ROWID.'
    }

    $metaRows = @(Invoke-RimeBilingualSql -Database $Database -Sql 'SELECT id, revision, updated_at_utc FROM cache_meta' -Query)
    if ($metaRows.Count -ne 1 -or [int64]$metaRows[0].id -ne 1 -or [int64]$metaRows[0].revision -lt 0) {
        throw 'SQLite cache_meta must contain exactly one non-negative revision row.'
    }

    return [pscustomobject]@{
        ApplicationId = $applicationId
        SchemaVersion = $schemaVersion
        Revision      = [int64]$metaRows[0].revision
        UpdatedAtUtc  = [string]$metaRows[0].updated_at_utc
        EntryCount    = [int64](@(Invoke-RimeBilingualSql -Database $Database -Sql 'SELECT COUNT(*) AS entry_count FROM translations' -Query)[0].entry_count)
    }
}

function Ensure-RimeBilingualSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($DatabasePath)
    $wasExisting = Test-Path -LiteralPath $fullPath -PathType Leaf
    $wasNonEmpty = $wasExisting -and ((Get-Item -LiteralPath $fullPath).Length -gt 0)
    $database = Open-RimeBilingualDatabase -DatabasePath $fullPath
    try {
        $applicationRows = @(Invoke-RimeBilingualSql -Database $database -Sql 'PRAGMA application_id' -Query)
        $versionRows = @(Invoke-RimeBilingualSql -Database $database -Sql 'PRAGMA user_version' -Query)
        $applicationId = [long]$applicationRows[0].application_id
        $schemaVersion = [long]$versionRows[0].user_version

        if ($wasNonEmpty -and ($applicationId -ne $script:ApplicationId -or $schemaVersion -ne $script:SchemaVersion)) {
            throw ("Refusing to modify incompatible SQLite database (application_id={0}, user_version={1})." -f $applicationId, $schemaVersion)
        }

        if ($wasNonEmpty -and $applicationId -eq $script:ApplicationId -and $schemaVersion -eq $script:SchemaVersion) {
            # An existing compatible database must already be structurally
            # valid; do not CREATE/INSERT into a malformed file before the
            # caller has had a chance to preserve it.
            $null = Test-RimeBilingualSchema -Database $database
        }
        else {
            foreach ($statement in (Get-RimeBilingualSchemaStatements)) {
                $null = Invoke-RimeBilingualSql -Database $database -Sql $statement
            }
            $null = Test-RimeBilingualSchema -Database $database
        }
        return $database
    }
    catch {
        try { Close-RimeBilingualDatabase -Database $database } catch { }
        throw
    }
}

function Assert-RimeBilingualRuntimeTuple {
    param(
        [string]$SourceLanguage,
        [string]$TargetLanguage,
        [string]$TranslationMode
    )
    if ($SourceLanguage -ne $script:SourceLanguage -or
        $TargetLanguage -ne $script:TargetLanguage -or
        $TranslationMode -ne $script:TranslationMode) {
        throw ("V0.2 only supports source_language='{0}', target_language='{1}', translation_mode='{2}'." -f `
            $script:SourceLanguage, $script:TargetLanguage, $script:TranslationMode)
    }
}

function ConvertTo-RimeBilingualUtcTimestamp {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture))
    }
    try {
        $parsed = [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        )
        return $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "updated_at_utc must be a valid UTC timestamp: '$Value'."
    }
}

function Assert-RimeBilingualText {
    param([string]$Value, [string]$Name, [bool]$AllowEmpty = $false)
    if ($null -eq $Value -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw ("{0} must not be empty." -f $Name)
    }
    # Force strict UTF-8 validation before any data reaches SQLite.
    $encoded = $script:Utf8.GetBytes($Value)
    if ($encoded.Length -gt $script:MaxRuntimeStringBytes) {
        throw ("{0} exceeds the {1}-byte runtime limit." -f $Name, $script:MaxRuntimeStringBytes)
    }
}

function Get-RimeBilingualPropertyValue {
    param([object]$Object, [string[]]$Names)
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $null
}

function ConvertTo-RimeBilingualEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,
        [string]$DefaultSource = 'import'
    )

    $sourceTextValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('source_text', 'text', 'sourceText')
    $translatedValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('translated_text', 'translation', 'target_text', 'target', 'translatedText')
    $sourceValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('source', 'provenance_source', 'provenance')
    $timestampValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('updated_at_utc', 'provenance_utc', 'updatedAtUtc')
    $sourceLanguageValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('source_language', 'sourceLanguage')
    $targetLanguageValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('target_language', 'targetLanguage')
    $modeValue = Get-RimeBilingualPropertyValue -Object $Row -Names @('translation_mode', 'translationMode', 'mode')

    if ($null -eq $sourceLanguageValue) { $sourceLanguageValue = $script:SourceLanguage }
    if ($null -eq $targetLanguageValue) { $targetLanguageValue = $script:TargetLanguage }
    if ($null -eq $modeValue) { $modeValue = $script:TranslationMode }
    if ($null -eq $sourceValue -or [string]::IsNullOrWhiteSpace([string]$sourceValue)) { $sourceValue = $DefaultSource }
    Assert-RimeBilingualRuntimeTuple -SourceLanguage ([string]$sourceLanguageValue) -TargetLanguage ([string]$targetLanguageValue) -TranslationMode ([string]$modeValue)
    Assert-RimeBilingualText -Value ([string]$sourceTextValue) -Name 'source_text'
    if ($null -eq $translatedValue) {
        throw 'translated_text must be present and non-empty.'
    }
    Assert-RimeBilingualText -Value ([string]$translatedValue) -Name 'translated_text'
    Assert-RimeBilingualText -Value ([string]$sourceValue) -Name 'source'
    $normalizedTimestamp = $null
    if ($null -ne $timestampValue) {
        $normalizedTimestamp = [string]$timestampValue
    }
    return [pscustomobject]@{
        source_text      = [string]$sourceTextValue
        source_language  = [string]$sourceLanguageValue
        target_language  = [string]$targetLanguageValue
        translation_mode = [string]$modeValue
        translated_text  = [string]$translatedValue
        source           = [string]$sourceValue
        updated_at_utc   = ConvertTo-RimeBilingualUtcTimestamp -Value $normalizedTimestamp
    }
}

function Update-RimeBilingualRevision {
    param([System.IntPtr]$Database)
    $rows = @(Invoke-RimeBilingualSql -Database $Database -Sql 'SELECT revision FROM cache_meta WHERE id = ?' -Parameters @([int64]1) -Query)
    if ($rows.Count -ne 1) {
        throw 'SQLite cache_meta revision row is missing.'
    }
    $revision = [int64]$rows[0].revision + 1
    $timestamp = ConvertTo-RimeBilingualUtcTimestamp -Value $null
    $null = Invoke-RimeBilingualSql -Database $Database `
        -Sql 'UPDATE cache_meta SET revision = ?, updated_at_utc = ? WHERE id = ?' `
        -Parameters @($revision, $timestamp, [int64]1)
    return $revision
}

function Write-RimeBilingualEntries {
    param(
        [System.IntPtr]$Database,
        [object[]]$Entries
    )

    return Invoke-RimeBilingualTransaction -Database $Database -Body {
        param($transactionDatabase)
        $upsertSql = @'
INSERT INTO translations
    (source_text, source_language, target_language, translation_mode,
     translated_text, source, updated_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (source_text, source_language, target_language, translation_mode)
DO UPDATE SET
    translated_text = excluded.translated_text,
    source = excluded.source,
    updated_at_utc = excluded.updated_at_utc
'@
        foreach ($entry in $Entries) {
            $null = Invoke-RimeBilingualSql -Database $transactionDatabase -Sql $upsertSql -Parameters @(
                $entry.source_text,
                $entry.source_language,
                $entry.target_language,
                $entry.translation_mode,
                $entry.translated_text,
                $entry.source,
                $entry.updated_at_utc
            )
        }
        $runtimeCountRows = @(Invoke-RimeBilingualSql -Database $transactionDatabase -Sql @'
SELECT COUNT(*) AS entry_count
FROM translations
WHERE source_language = ? AND target_language = ? AND translation_mode = ?
'@ -Parameters @($script:SourceLanguage, $script:TargetLanguage, $script:TranslationMode) -Query)
        if ($runtimeCountRows.Count -ne 1 -or [int64]$runtimeCountRows[0].entry_count -gt $script:MaxRuntimeEntries) {
            throw ("The runtime cache cannot exceed {0} entries." -f $script:MaxRuntimeEntries)
        }
        return (Update-RimeBilingualRevision -Database $transactionDatabase)
    }
}

function Initialize-RimeBilingualCache {
    [CmdletBinding()]
    param(
        [string]$DatabasePath = (Get-RimeBilingualDefaultPaths).DatabasePath
    )

    $database = Ensure-RimeBilingualSchema -DatabasePath $DatabasePath
    try {
        $info = Test-RimeBilingualSchema -Database $database
        return $info
    }
    finally {
        Close-RimeBilingualDatabase -Database $database
    }
}

function Put-RimeBilingualCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TranslatedText,
        [string]$Source = 'manual',
        [string]$UpdatedAtUtc,
        [string]$DatabasePath = (Get-RimeBilingualDefaultPaths).DatabasePath
    )

    $database = Ensure-RimeBilingualSchema -DatabasePath $DatabasePath
    try {
        $entry = ConvertTo-RimeBilingualEntry -Row ([pscustomobject]@{
            source_text = $SourceText
            translated_text = $TranslatedText
            source = $Source
            updated_at_utc = $UpdatedAtUtc
        }) -DefaultSource 'manual'
        $revision = Write-RimeBilingualEntries -Database $database -Entries @($entry)
        return [pscustomobject]@{ Revision = [int64]$revision; EntryCount = 1 }
    }
    finally {
        Close-RimeBilingualDatabase -Database $database
    }
}

function Get-RimeBilingualImportRows {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InputPath)

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Import file does not exist: '$InputPath'."
    }
    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    switch ($extension) {
        '.csv' {
            return @(Import-Csv -LiteralPath $InputPath)
        }
        '.tsv' {
            return @(Import-Csv -LiteralPath $InputPath -Delimiter "`t")
        }
        '.json' {
            $json = [System.IO.File]::ReadAllText($InputPath, $script:Utf8)
            $value = ConvertFrom-Json -InputObject $json
            if ($value -is [System.Array]) { return @($value) }
            if ($null -ne $value.PSObject.Properties['entries']) {
                $items = @()
                foreach ($property in $value.entries.PSObject.Properties) {
                    $items += [pscustomobject]@{ source_text = $property.Name; translated_text = [string]$property.Value }
                }
                return $items
            }
            return @($value)
        }
        default {
            throw "Unsupported import format '$extension'; use .csv, .tsv, or .json."
        }
    }
}

function Import-RimeBilingualCacheEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [string]$DatabasePath = (Get-RimeBilingualDefaultPaths).DatabasePath,
        [string]$DefaultSource = 'import'
    )

    $rows = @(Get-RimeBilingualImportRows -InputPath $InputPath)
    if ($rows.Count -eq 0) {
        throw 'Import file contains no entries.'
    }
    $entries = @()
    foreach ($row in $rows) {
        $entries += ConvertTo-RimeBilingualEntry -Row $row -DefaultSource $DefaultSource
    }

    $database = Ensure-RimeBilingualSchema -DatabasePath $DatabasePath
    try {
        $revision = Write-RimeBilingualEntries -Database $database -Entries $entries
        return [pscustomobject]@{ Revision = [int64]$revision; EntryCount = $entries.Count }
    }
    finally {
        Close-RimeBilingualDatabase -Database $database
    }
}

function ConvertTo-RimeBilingualLuaString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append("'")
    :characters for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $code = [int][char]$character
        switch ($code) {
            0x08 { $null = $builder.Append('\b'); continue characters }
            0x09 { $null = $builder.Append('\t'); continue characters }
            0x0A { $null = $builder.Append('\n'); continue characters }
            0x0C { $null = $builder.Append('\f'); continue characters }
            0x0D { $null = $builder.Append('\r'); continue characters }
            0x27 { $null = $builder.Append("\'"); continue characters }
            0x5C { $null = $builder.Append('\\'); continue characters }
        }
        if ($code -lt 0x20 -or $code -eq 0x7F) {
            $null = $builder.Append(('\{0:D3}' -f $code))
        }
        else {
            # Non-ASCII UTF-16 (including surrogate pairs) is emitted as
            # UTF-8 source text.  The final writer validates UTF-8 strictly.
            $null = $builder.Append($character)
        }
    }
    $null = $builder.Append("'")
    return $builder.ToString()
}

function New-RimeBilingualSnapshotText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Revision,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    if ($Revision -lt 0 -or $Revision -gt $script:MaxRuntimeRevision) {
        throw ("Snapshot revision must be between 0 and {0}." -f $script:MaxRuntimeRevision)
    }
    if ($Entries.Count -gt $script:MaxRuntimeEntries) {
        throw ("The runtime cache cannot exceed {0} entries." -f $script:MaxRuntimeEntries)
    }
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine('return {')
    $null = $builder.AppendLine('  format_version = 1,')
    $null = $builder.AppendLine('  db_schema_version = 1,')
    $null = $builder.AppendLine(('  revision = {0},' -f $Revision.ToString([Globalization.CultureInfo]::InvariantCulture)))
    $null = $builder.AppendLine(("  source_language = {0}," -f (ConvertTo-RimeBilingualLuaString -Value $script:SourceLanguage)))
    $null = $builder.AppendLine(("  target_language = {0}," -f (ConvertTo-RimeBilingualLuaString -Value $script:TargetLanguage)))
    $null = $builder.AppendLine(("  translation_mode = {0}," -f (ConvertTo-RimeBilingualLuaString -Value $script:TranslationMode)))
    $null = $builder.AppendLine('  entries = {')
    foreach ($entry in $Entries) {
        $sourceText = [string]$entry.source_text
        $translatedText = [string]$entry.translated_text
        Assert-RimeBilingualText -Value $sourceText -Name 'source_text'
        Assert-RimeBilingualText -Value $translatedText -Name 'translated_text'
        $key = ConvertTo-RimeBilingualLuaString -Value $sourceText
        $value = ConvertTo-RimeBilingualLuaString -Value $translatedText
        $null = $builder.AppendLine(('    [{0}] = {1},' -f $key, $value))
    }
    $null = $builder.AppendLine('  },')
    $null = $builder.AppendLine('}')
    $snapshotText = $builder.ToString()
    if ($script:Utf8.GetByteCount($snapshotText) -gt $script:MaxSnapshotBytes) {
        throw ("The published snapshot cannot exceed {0} bytes." -f $script:MaxSnapshotBytes)
    }
    return $snapshotText
}

function Get-RimeBilingualSnapshotData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IntPtr]$Database
    )

    $null = Test-RimeBilingualSchema -Database $Database
    $transactionOpen = $false
    try {
        $null = Invoke-RimeBilingualSql -Database $Database -Sql 'BEGIN'
        $transactionOpen = $true
        $meta = @(Invoke-RimeBilingualSql -Database $Database -Sql `
            'SELECT revision FROM cache_meta WHERE id = ?' -Parameters @([int64]1) -Query)
        if ($meta.Count -ne 1) {
            throw 'SQLite cache_meta revision row is missing.'
        }
        $entries = @(Invoke-RimeBilingualSql -Database $Database -Sql @'
SELECT source_text, source_language, target_language, translation_mode,
       translated_text, source, updated_at_utc
FROM translations
WHERE source_language = ? AND target_language = ? AND translation_mode = ?
ORDER BY source_text COLLATE BINARY
'@ -Parameters @($script:SourceLanguage, $script:TargetLanguage, $script:TranslationMode) -Query)
        $null = Invoke-RimeBilingualSql -Database $Database -Sql 'COMMIT'
        $transactionOpen = $false
        return [pscustomobject]@{
            Revision = [int64]$meta[0].revision
            Entries  = $entries
        }
    }
    catch {
        if ($transactionOpen) {
            try { $null = Invoke-RimeBilingualSql -Database $Database -Sql 'ROLLBACK' } catch { }
        }
        throw
    }
}

function Write-RimeBilingualAtomicFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if ([string]::IsNullOrEmpty($directory)) { throw 'Snapshot path has no parent directory.' }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tempPath = Join-Path $directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
    $backupPath = $null
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Content)
        $stream = New-Object System.IO.FileStream(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            65536,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            # File.Replace is an atomic same-volume replacement on Windows and
            # leaves the old destination untouched if it cannot complete.  The
            # Windows .NET implementation requires a non-empty backup path,
            # so use a unique same-directory backup and remove it afterwards.
            $backupPath = Join-Path $directory ('.{0}.{1}.bak' -f [System.IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
            [System.IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
        return $fullPath
    }
    finally {
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Publish-RimeBilingualCacheSnapshot {
    [CmdletBinding()]
    param(
        [string]$DatabasePath = (Get-RimeBilingualDefaultPaths).DatabasePath,
        [string]$SnapshotPath = (Get-RimeBilingualDefaultPaths).SnapshotPath
    )

    $database = Open-RimeBilingualDatabase -DatabasePath $DatabasePath -ReadOnly
    try {
        $snapshotData = Get-RimeBilingualSnapshotData -Database $database
        $snapshotText = New-RimeBilingualSnapshotText -Revision $snapshotData.Revision -Entries $snapshotData.Entries
    }
    finally {
        Close-RimeBilingualDatabase -Database $database
    }

    $publishedPath = Write-RimeBilingualAtomicFile -Path $SnapshotPath -Content $snapshotText
    return [pscustomobject]@{
        SnapshotPath = $publishedPath
        Revision     = [int64]$snapshotData.Revision
        EntryCount   = @($snapshotData.Entries).Count
    }
}

function Test-RimeBilingualSnapshotText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int64]$DatabaseRevision
    )

    if ($Text.Length -gt 16MB) { throw 'Snapshot is too large.' }
    if ($Text.Length -eq 0 -or $Text[0] -eq [char]0xFEFF) { throw 'Snapshot must be UTF-8 without a BOM.' }
    if ($Text -notmatch '(?m)^\s*return\s*\{') { throw 'Snapshot does not start with a Lua return table.' }
    if ($Text -notmatch '(?m)format_version\s*=\s*1\s*,') { throw 'Snapshot format_version is invalid.' }
    if ($Text -notmatch '(?m)db_schema_version\s*=\s*1\s*,') { throw 'Snapshot db_schema_version is invalid.' }
    $revisionMatch = [regex]::Match($Text, '(?m)revision\s*=\s*(\d+)\s*,')
    if (-not $revisionMatch.Success -or [int64]$revisionMatch.Groups[1].Value -ne $DatabaseRevision) {
        throw 'Snapshot revision does not match the database.'
    }
    if ($Text -notmatch "(?m)source_language\s*=\s*'zh'\s*," -or
        $Text -notmatch "(?m)target_language\s*=\s*'en'\s*," -or
        $Text -notmatch "(?m)translation_mode\s*=\s*'literal'\s*,") {
        throw 'Snapshot runtime tuple is invalid.'
    }
    if ($Text -notmatch '(?m)entries\s*=\s*\{') { throw 'Snapshot entries table is missing.' }
    return $true
}

function Validate-RimeBilingualCache {
    [CmdletBinding()]
    param(
        [string]$DatabasePath = (Get-RimeBilingualDefaultPaths).DatabasePath,
        [string]$SnapshotPath
    )

    $database = Open-RimeBilingualDatabase -DatabasePath $DatabasePath -ReadOnly
    try {
        $info = Test-RimeBilingualSchema -Database $database
    }
    finally {
        Close-RimeBilingualDatabase -Database $database
    }

    $snapshotValid = $null
    if (-not [string]::IsNullOrEmpty($SnapshotPath)) {
        if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
            throw "Snapshot does not exist: '$SnapshotPath'."
        }
        $snapshotBytes = [System.IO.File]::ReadAllBytes([System.IO.Path]::GetFullPath($SnapshotPath))
        $snapshotText = $script:Utf8.GetString($snapshotBytes)
        $snapshotValid = Test-RimeBilingualSnapshotText -Text $snapshotText -DatabaseRevision ([int64]$info.Revision)
    }
    return [pscustomobject]@{
        Valid         = $true
        ApplicationId = [int64]$info.ApplicationId
        SchemaVersion = [int64]$info.SchemaVersion
        Revision      = [int64]$info.Revision
        EntryCount    = [int64]$info.EntryCount
        SnapshotValid = $snapshotValid
    }
}

Export-ModuleMember -Function @(
    'Get-RimeBilingualDefaultPaths',
    'Initialize-RimeBilingualCache',
    'Put-RimeBilingualCacheEntry',
    'Import-RimeBilingualCacheEntries',
    'Publish-RimeBilingualCacheSnapshot',
    'Validate-RimeBilingualCache'
)
