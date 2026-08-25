[CmdletBinding()]
param(
    [string]$ServerPath = 'C:\Program Files\Rime\weasel-0.17.4\WeaselServer.exe',
    [string]$RimeUserDir = (Join-Path $env:APPDATA 'Rime')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$bridgePath = [IO.Path]::GetFullPath((Join-Path $RimeUserDir 'rime-bilingual\native\rime_bilingual_bridge.dll'))
$serverPathFull = [IO.Path]::GetFullPath($ServerPath)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RimeBilingualWeaselSmokeNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CallNamedPipeW")]
    public static extern bool CallNamedPipeW(
        string pipeName,
        byte[] input,
        uint inputSize,
        byte[] output,
        uint outputSize,
        out uint bytesRead,
        uint timeout);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(
        IntPtr process,
        IntPtr address,
        [Out] byte[] buffer,
        UIntPtr size,
        out UIntPtr bytesRead);

    private static byte[] Read(IntPtr process, long address, int length) {
        byte[] buffer = new byte[length];
        UIntPtr read;
        if (!ReadProcessMemory(process, new IntPtr(address), buffer, new UIntPtr((uint)length), out read) ||
            read.ToUInt64() != (ulong)length) {
            throw new InvalidOperationException("ReadProcessMemory failed at 0x" + address.ToString("X"));
        }
        return buffer;
    }

    private static string ReadAsciiZ(IntPtr process, long address, int maxLength) {
        byte[] bytes = Read(process, address, maxLength);
        int end = Array.IndexOf(bytes, (byte)0);
        if (end < 0) throw new InvalidOperationException("Unterminated remote ASCII string.");
        return Encoding.ASCII.GetString(bytes, 0, end);
    }

    public static ulong FindImportPointer(IntPtr process, long moduleBase, string dllName, string importName) {
        byte[] headers = Read(process, moduleBase, 4096);
        if (BitConverter.ToUInt16(headers, 0) != 0x5a4d)
            throw new InvalidOperationException("Remote image is not MZ.");
        int nt = BitConverter.ToInt32(headers, 0x3c);
        if (nt < 0 || nt + 144 >= headers.Length || BitConverter.ToUInt32(headers, nt) != 0x00004550)
            throw new InvalidOperationException("Remote image is not PE.");
        int optional = nt + 24;
        if (BitConverter.ToUInt16(headers, optional) != 0x020b)
            throw new InvalidOperationException("Remote image is not PE32+.");
        uint importRva = BitConverter.ToUInt32(headers, optional + 112 + 8);
        if (importRva == 0) throw new InvalidOperationException("Remote image has no import directory.");

        for (int descriptorIndex = 0; descriptorIndex < 512; descriptorIndex++) {
            long descriptorAddress = moduleBase + importRva + descriptorIndex * 20L;
            byte[] descriptor = Read(process, descriptorAddress, 20);
            uint originalFirstThunk = BitConverter.ToUInt32(descriptor, 0);
            uint nameRva = BitConverter.ToUInt32(descriptor, 12);
            uint firstThunk = BitConverter.ToUInt32(descriptor, 16);
            if (originalFirstThunk == 0 && nameRva == 0 && firstThunk == 0) break;
            string currentDll = ReadAsciiZ(process, moduleBase + nameRva, 128);
            if (!currentDll.Equals(dllName, StringComparison.OrdinalIgnoreCase)) continue;
            if (originalFirstThunk == 0 || firstThunk == 0)
                throw new InvalidOperationException("Unsupported import table without OriginalFirstThunk.");

            for (int index = 0; index < 8192; index++) {
                ulong thunk = BitConverter.ToUInt64(Read(process, moduleBase + originalFirstThunk + index * 8L, 8), 0);
                if (thunk == 0) break;
                if ((thunk & 0x8000000000000000UL) != 0) continue;
                string currentImport = ReadAsciiZ(process, moduleBase + (long)thunk + 2, 128);
                if (!currentImport.Equals(importName, StringComparison.Ordinal)) continue;
                return BitConverter.ToUInt64(Read(process, moduleBase + firstThunk + index * 8L, 8), 0);
            }
            break;
        }
        return 0;
    }
}
'@

function Invoke-WeaselMessage {
    param(
        [Parameter(Mandatory = $true)][uint32]$Command,
        [uint32]$WParam = 0,
        [uint32]$LParam = 0,
        [AllowNull()][string]$Body = $null
    )

    $input = if ($null -eq $Body) { New-Object byte[] 12 } else { New-Object byte[] 65536 }
    [BitConverter]::GetBytes($Command).CopyTo($input, 0)
    [BitConverter]::GetBytes($WParam).CopyTo($input, 4)
    [BitConverter]::GetBytes($LParam).CopyTo($input, 8)
    if ($null -ne $Body) {
        $bodyBytes = [Text.Encoding]::Unicode.GetBytes($Body)
        if ($bodyBytes.Length -gt ($input.Length - 12)) { throw 'Weasel smoke client metadata is too large.' }
        [Array]::Copy($bodyBytes, 0, $input, 12, $bodyBytes.Length)
    }

    $output = New-Object byte[] 65536
    [uint32]$bytesRead = 0
    $pipe = '\\.\pipe\' + [Environment]::UserName + '\WeaselNamedPipe'
    $ok = [RimeBilingualWeaselSmokeNative]::CallNamedPipeW(
        $pipe,
        $input,
        [uint32]$input.Length,
        $output,
        [uint32]$output.Length,
        [ref]$bytesRead,
        1000)
    if (-not $ok) {
        throw "CallNamedPipeW failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }
    if ($bytesRead -lt 4) { throw "Weasel response is truncated: $bytesRead bytes." }
    [BitConverter]::ToUInt32($output, 0)
}

$servers = @(Get-Process WeaselServer -ErrorAction SilentlyContinue | Where-Object {
        try { [IO.Path]::GetFullPath($_.Path) -ieq $serverPathFull } catch { $false }
    })
if ($servers.Count -ne 1) { throw "Expected exactly one supported WeaselServer; found $($servers.Count)." }
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { throw "Managed bridge is missing: '$bridgePath'." }

$WM_APP = [uint32]0x8000
[uint32]$sessionId = 0
try {
    $metadata = "action=session`nsession.client_app=rime-bilingual-smoke.exe`nsession.client_type=tsf`n.`n"
    $sessionId = Invoke-WeaselMessage -Command ($WM_APP + 2) -Body $metadata
    if ($sessionId -eq 0) { throw 'START_SESSION returned session id 0.' }
    Write-Host "PASS: START_SESSION returned $sessionId." -ForegroundColor Green

    Start-Sleep -Milliseconds 250
    $server = Get-Process -Id $servers[0].Id -ErrorAction Stop
    $bridgeModules = @($server.Modules | Where-Object { [IO.Path]::GetFullPath($_.FileName) -ieq $bridgePath })
    if ($bridgeModules.Count -ne 1) { throw 'Bridge DLL was not loaded by the test Rime session.' }
    Write-Host 'PASS: bridge DLL is loaded in official WeaselServer.exe.' -ForegroundColor Green

    $bridgeBase = [uint64]$bridgeModules[0].BaseAddress.ToInt64()
    $bridgeEnd = $bridgeBase + [uint64]$bridgeModules[0].ModuleMemorySize
    $iatPointer = [RimeBilingualWeaselSmokeNative]::FindImportPointer(
        $server.Handle,
        $server.MainModule.BaseAddress.ToInt64(),
        'KERNEL32.dll',
        'ReadFile')
    if ($iatPointer -lt $bridgeBase -or $iatPointer -ge $bridgeEnd) {
        throw ('ReadFile IAT is not mounted into the bridge: 0x{0:X}' -f $iatPointer)
    }
    Write-Host ('PASS: ReadFile IAT points inside bridge module at 0x{0:X}.' -f $iatPointer) -ForegroundColor Green

    $echo = Invoke-WeaselMessage -Command ($WM_APP + 1) -LParam $sessionId
    if ($echo -ne $sessionId) { throw "ECHO mismatch: expected $sessionId, got $echo." }
    Write-Host 'PASS: hooked ReadFile path preserves official ECHO behavior.' -ForegroundColor Green
}
finally {
    if ($sessionId -ne 0 -and (Get-Process WeaselServer -ErrorAction SilentlyContinue)) {
        try { [void](Invoke-WeaselMessage -Command ($WM_APP + 3) -LParam $sessionId) }
        catch { Write-Warning "Could not end smoke session ${sessionId}: $($_.Exception.Message)" }
    }
}

Start-Sleep -Milliseconds 250
if (-not (Get-Process -Id $servers[0].Id -ErrorAction SilentlyContinue)) {
    throw 'WeaselServer exited during mount smoke test.'
}
Write-Host 'PASS: WeaselServer remains alive after START/ECHO/END smoke test.' -ForegroundColor Green
