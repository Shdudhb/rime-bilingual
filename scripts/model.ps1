[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('install', 'import', 'start', 'stop', 'status', 'health')]
    [string]$Action,

    [ValidateSet('runtime', 'model', 'all')]
    [string]$Component = 'runtime',

    [ValidateSet('gemma', 'qwen')]
    [string]$Profile = 'gemma',

    [string]$SourcePath,
    [string]$Token,
    [ValidateRange(1024, 65535)]
    [int]$Port = 18080,
    [ValidateRange(256, 512)]
    [int]$ContextSize = 512,
    [ValidateRange(0, 999)]
    [int]$GpuLayers = 999,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'RimeBilingual'),
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Runtime = [ordered]@{
    Version = 'b10516'
    FileName = 'llama-b10516-bin-win-vulkan-x64.zip'
    Url = 'https://github.com/ggml-org/llama.cpp/releases/download/b10516/llama-b10516-bin-win-vulkan-x64.zip'
    Size = [int64]34861181
    Sha256 = '530f57d2a874ce017827c1e5a926812b9d5de4667248575d1372b1c0acf94d83'
}

$script:Profiles = @{
    gemma = [ordered]@{
        Identity = 'gemma-3-1b-it-qat-q4_0'
        Repository = 'google/gemma-3-1b-it-qat-q4_0-gguf'
        Commit = 'd1be121d36172a4b0b964657e2ee859d61138593'
        FileName = 'gemma-3-1b-it-q4_0.gguf'
        Size = [int64]1003541152
        Sha256 = '95e5b8d891cd6a794f66c2a6fb59a41e9562b4660560b854274eceffb628b22a'
    }
    qwen = [ordered]@{
        Identity = 'qwen3-0.6b-q4_0'
        Repository = 'ggml-org/Qwen3-0.6B-GGUF'
        Commit = 'b5f37287796e5be0ea3dab2e7430873fb3f73e49'
        FileName = 'Qwen3-0.6B-Q4_0.gguf'
        Size = [int64]428970080
        Sha256 = 'da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4'
    }
}

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Get-Layout([string]$Root, [string]$SelectedProfile) {
    $rootFull = Get-FullPath $Root
    $profileData = $script:Profiles[$SelectedProfile]
    return [ordered]@{
        Root = $rootFull
        RuntimeDir = Join-Path $rootFull ('runtime\llama.cpp\' + $script:Runtime.Version)
        ModelDir = Join-Path $rootFull ('models\' + $profileData.Identity)
        Config = Join-Path $rootFull 'config.json'
        Pid = Join-Path $rootFull 'llama-server.pid.json'
        Logs = Join-Path $rootFull 'logs'
        Temp = Join-Path $rootFull '.downloads'
    }
}

function Test-FileIntegrity([string]$Path, [int64]$ExpectedSize, [string]$ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $ExpectedSize) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -eq $ExpectedSha256.ToLowerInvariant()
}

function Move-FileAtomic([string]$Source, [string]$Destination) {
    if (-not ('RimeBilingual.NativeFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RimeBilingual {
    public static class NativeFile {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(string existingName, string newName, int flags);
    }
}
'@
    }
    # MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH. Both paths are on the
    # same local data volume, so replacement is atomic from readers' perspective.
    if (-not [RimeBilingual.NativeFile]::MoveFileEx($Source, $Destination, 0x9)) {
        throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
}

function Write-JsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-FileAtomic $temporary $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-AssetDownload([string]$Uri, [string]$Destination, [string]$BearerToken) {
    $parameters = @{ Uri = $Uri; OutFile = $Destination; UseBasicParsing = $true }
    if ($BearerToken) { $parameters.Headers = @{ Authorization = 'Bearer ' + $BearerToken } }
    Invoke-WebRequest @parameters
}

function Receive-VerifiedAsset($Asset, [string]$Destination, [string]$BearerToken) {
    $layoutRoot = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($layoutRoot) | Out-Null
    $temporary = Join-Path $layoutRoot ('.' + [IO.Path]::GetFileName($Destination) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Invoke-AssetDownload -Uri $Asset.Url -Destination $temporary -BearerToken $BearerToken
        if (-not (Test-FileIntegrity $temporary $Asset.Size $Asset.Sha256)) {
            throw "Downloaded asset failed size or SHA-256 verification: $($Asset.FileName)"
        }
        Move-FileAtomic $temporary $Destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Expand-ZipSafely([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destinationFull = (Get-FullPath $Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    [IO.Directory]::CreateDirectory($destinationFull) | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { throw "Archive contains a symbolic link: $($entry.FullName)" }
            $target = Get-FullPath (Join-Path $destinationFull $entry.FullName)
            if (-not $target.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes destination: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            if (Test-Path -LiteralPath $target) { throw "Archive contains duplicate output path: $($entry.FullName)" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    } finally {
        $zip.Dispose()
    }
}

function Install-Runtime($Layout) {
    $destination = $Layout.RuntimeDir
    $server = Join-Path $destination 'llama-server.exe'
    if ((Test-Path -LiteralPath $server -PathType Leaf) -and -not $Force) {
        Write-Output "llama.cpp $($script:Runtime.Version) is already installed."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'download, verify, and install llama.cpp runtime')) { return }
    [IO.Directory]::CreateDirectory($Layout.Temp) | Out-Null
    $archive = Join-Path $Layout.Temp $script:Runtime.FileName
    Receive-VerifiedAsset $script:Runtime $archive $null
    $staging = $destination + '.staging.' + [guid]::NewGuid().ToString('N')
    try {
        Expand-ZipSafely $archive $staging
        if (-not (Test-Path -LiteralPath (Join-Path $staging 'llama-server.exe') -PathType Leaf)) {
            throw 'Verified runtime archive does not contain llama-server.exe at its root.'
        }
        $backup = $null
        if (Test-Path -LiteralPath $destination) {
            $backup = $destination + '.backup.' + [guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($destination, $backup)
        }
        try {
            [IO.Directory]::Move($staging, $destination)
            if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force }
        } catch {
            if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $destination)) {
                [IO.Directory]::Move($backup, $destination)
            }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
    Write-Output "Installed llama.cpp $($script:Runtime.Version)."
}

function Get-ModelAsset([string]$SelectedProfile) {
    $profileData = $script:Profiles[$SelectedProfile]
    return [ordered]@{
        FileName = $profileData.FileName
        Size = $profileData.Size
        Sha256 = $profileData.Sha256
        Url = 'https://huggingface.co/' + $profileData.Repository + '/resolve/' + $profileData.Commit + '/' + $profileData.FileName + '?download=true'
    }
}

function Save-Configuration($Layout, [string]$SelectedProfile) {
    $profileData = $script:Profiles[$SelectedProfile]
    $configuration = [ordered]@{
        schema_version = 1
        bind_host = '127.0.0.1'
        port = $Port
        runtime_version = $script:Runtime.Version
        runtime_path = Join-Path $Layout.RuntimeDir 'llama-server.exe'
        model_profile = $SelectedProfile
        model_identity = $profileData.Identity
        model_repository = $profileData.Repository
        model_commit = $profileData.Commit
        model_path = Join-Path $Layout.ModelDir $profileData.FileName
        context_size = $ContextSize
        temperature = 0.1
        timeout_seconds = 30
        gpu_layers = $GpuLayers
    }
    Write-JsonAtomic $Layout.Config $configuration
}

function Install-Model($Layout, [string]$SelectedProfile) {
    $asset = Get-ModelAsset $SelectedProfile
    $destination = Join-Path $Layout.ModelDir $asset.FileName
    if ((Test-FileIntegrity $destination $asset.Size $asset.Sha256) -and -not $Force) {
        Write-Output "Model $SelectedProfile is already installed and verified."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'download, verify, and install model')) { return }
    [IO.Directory]::CreateDirectory($Layout.ModelDir) | Out-Null
    Receive-VerifiedAsset $asset $destination $Token
    Save-Configuration $Layout $SelectedProfile
    Write-Output "Installed and verified model $SelectedProfile."
}

function Import-Model($Layout, [string]$SelectedProfile, [string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'import requires -SourcePath.' }
    $source = Get-FullPath $InputPath
    $asset = Get-ModelAsset $SelectedProfile
    if (-not (Test-FileIntegrity $source $asset.Size $asset.Sha256)) {
        throw "Source model failed size or SHA-256 verification for profile $SelectedProfile."
    }
    $destination = Join-Path $Layout.ModelDir $asset.FileName
    if (-not $PSCmdlet.ShouldProcess($destination, 'import verified model')) { return }
    [IO.Directory]::CreateDirectory($Layout.ModelDir) | Out-Null
    $temporary = Join-Path $Layout.ModelDir ('.' + $asset.FileName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        if (-not (Test-FileIntegrity $temporary $asset.Size $asset.Sha256)) { throw 'Copied model failed verification.' }
        Move-FileAtomic $temporary $destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Save-Configuration $Layout $SelectedProfile
    Write-Output "Imported and verified model $SelectedProfile."
}

function Read-Configuration($Layout) {
    if (-not (Test-Path -LiteralPath $Layout.Config -PathType Leaf)) { throw 'Configuration is missing; install or import a model first.' }
    return (Get-Content -LiteralPath $Layout.Config -Raw | ConvertFrom-Json)
}

function Get-ProcessCommandLine([int]$Id) {
    $escaped = $Id.ToString([Globalization.CultureInfo]::InvariantCulture)
    $row = Get-CimInstance Win32_Process -Filter "ProcessId = $escaped" -ErrorAction SilentlyContinue
    if ($null -eq $row) { return $null }
    return [string]$row.CommandLine
}

function Test-ManagedProcess($PidRecord, $Configuration) {
    if ($null -eq $PidRecord -or $null -eq $PidRecord.pid) { return $false }
    $process = Get-Process -Id ([int]$PidRecord.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try { $actualPath = Get-FullPath $process.Path } catch { return $false }
    if ($actualPath -ne (Get-FullPath ([string]$PidRecord.executable_path))) { return $false }
    if ($actualPath -ne (Get-FullPath ([string]$Configuration.runtime_path))) { return $false }
    $commandLine = Get-ProcessCommandLine ([int]$PidRecord.pid)
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    if ($commandLine.IndexOf([string]$Configuration.model_path, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    if ($commandLine -notmatch '(?:^|\s)--host\s+127\.0\.0\.1(?:\s|$)') { return $false }
    if ($commandLine -notmatch ('(?:^|\s)--port\s+' + [regex]::Escape(([int]$Configuration.port).ToString()) + '(?:\s|$)')) { return $false }
    return $true
}

function Get-PidRecord($Layout) {
    if (-not (Test-Path -LiteralPath $Layout.Pid -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Layout.Pid -Raw | ConvertFrom-Json) } catch { return $null }
}

function Quote-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-ModelServer($Layout) {
    $configuration = Read-Configuration $Layout
    if ([string]$configuration.bind_host -ne '127.0.0.1') { throw 'Configuration must bind llama-server to 127.0.0.1.' }
    $existing = Get-PidRecord $Layout
    if (Test-ManagedProcess $existing $configuration) { Write-Output "llama-server is already running (PID $($existing.pid))."; return }
    if (-not (Test-FileIntegrity ([string]$configuration.model_path) $script:Profiles[[string]$configuration.model_profile].Size $script:Profiles[[string]$configuration.model_profile].Sha256)) {
        throw 'Configured model is missing or failed integrity verification.'
    }
    if (-not (Test-Path -LiteralPath ([string]$configuration.runtime_path) -PathType Leaf)) { throw 'llama-server.exe is missing.' }
    if (-not $PSCmdlet.ShouldProcess($configuration.runtime_path, 'start loopback llama-server')) { return }
    [IO.Directory]::CreateDirectory($Layout.Logs) | Out-Null
    $stdout = Join-Path $Layout.Logs 'llama-server.stdout.log'
    $stderr = Join-Path $Layout.Logs 'llama-server.stderr.log'
    $argumentValues = @('--host', '127.0.0.1', '--port', ([string]$configuration.port), '--model', [string]$configuration.model_path, '--ctx-size', ([string]$configuration.context_size), '--temp', ([string]$configuration.temperature), '--n-gpu-layers', ([string]$configuration.gpu_layers), '--no-webui', '--log-disable')
    $argumentLine = (($argumentValues | ForEach-Object { Quote-NativeArgument ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath ([string]$configuration.runtime_path) -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $record = [ordered]@{ pid = $process.Id; executable_path = Get-FullPath ([string]$configuration.runtime_path); started_utc = [DateTime]::UtcNow.ToString('o') }
    Write-JsonAtomic $Layout.Pid $record
    Start-Sleep -Milliseconds 400
    $process.Refresh()
    if ($process.HasExited) {
        if (Test-Path -LiteralPath $Layout.Pid) { Remove-Item -LiteralPath $Layout.Pid -Force }
        throw "llama-server exited during startup (exit code $($process.ExitCode)); check port availability and local runtime compatibility."
    }
    Write-Output "Started llama-server on 127.0.0.1:$($configuration.port) (PID $($process.Id))."
}

function Stop-ModelServer($Layout) {
    $configuration = Read-Configuration $Layout
    $record = Get-PidRecord $Layout
    if ($null -eq $record) { Write-Output 'llama-server is not managed or already stopped.'; return }
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        if ($PSCmdlet.ShouldProcess($Layout.Pid, 'remove stale PID record')) { Remove-Item -LiteralPath $Layout.Pid -Force }
        Write-Output 'llama-server is already stopped.'
        return
    }
    if (-not (Test-ManagedProcess $record $configuration)) { throw "Refusing to stop PID $($record.pid): process identity does not match the managed llama-server." }
    if (-not $PSCmdlet.ShouldProcess("PID $($record.pid)", 'stop managed llama-server')) { return }
    Stop-Process -Id ([int]$record.pid) -ErrorAction Stop
    try { Wait-Process -Id ([int]$record.pid) -Timeout 10 -ErrorAction SilentlyContinue } catch { }
    Remove-Item -LiteralPath $Layout.Pid -Force
    Write-Output 'Stopped managed llama-server.'
}

function Get-ModelStatus($Layout) {
    $result = [ordered]@{ configured = $false; running = $false; healthy = $false; pid = $null; endpoint = $null; model = $null }
    try { $configuration = Read-Configuration $Layout } catch { return [pscustomobject]$result }
    $result.configured = $true
    $result.endpoint = 'http://127.0.0.1:' + [string]$configuration.port
    $result.model = [string]$configuration.model_identity
    $record = Get-PidRecord $Layout
    if (Test-ManagedProcess $record $configuration) { $result.running = $true; $result.pid = [int]$record.pid }
    if (-not $result.running) { return [pscustomobject]$result }
    try {
        $response = Invoke-WebRequest -Uri ($result.endpoint + '/health') -UseBasicParsing -TimeoutSec 2
        $result.healthy = $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
    } catch { $result.healthy = $false }
    return [pscustomobject]$result
}

if ($env:RIME_BILINGUAL_MODEL_TEST_MODE -eq '1') { return }

$layout = Get-Layout $DataRoot $Profile
switch ($Action) {
    install {
        if ($Component -eq 'runtime' -or $Component -eq 'all') { Install-Runtime $layout }
        if ($Component -eq 'model' -or $Component -eq 'all') { Install-Model $layout $Profile }
    }
    import { Import-Model $layout $Profile $SourcePath }
    start { Start-ModelServer $layout }
    stop { Stop-ModelServer $layout }
    status { Get-ModelStatus $layout | ConvertTo-Json -Depth 4 }
    health {
        $status = Get-ModelStatus $layout
        $status | ConvertTo-Json -Depth 4
        if (-not $status.healthy) { exit 1 }
    }
}
