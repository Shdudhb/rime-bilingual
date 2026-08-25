[CmdletBinding()]
param([string]$InputText = 'ni')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RbCandidateInspectNative {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CallNamedPipeW")]
    public static extern bool CallNamedPipeW(string name, byte[] input, uint inputSize,
        byte[] output, uint outputSize, out uint bytesRead, uint timeout);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
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
        [Array]::Copy($bodyBytes, 0, $input, 12, $bodyBytes.Length)
    }
    $output = New-Object byte[] 65536
    [uint32]$read = 0
    $pipe = '\\.\pipe\' + [Environment]::UserName + '\WeaselNamedPipe'
    $ok = $false
    $lastError = 0
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $read = 0
        $ok = [RbCandidateInspectNative]::CallNamedPipeW($pipe, $input, [uint32]$input.Length,
                $output, [uint32]$output.Length, [ref]$read, 1000)
        if ($ok) { break }
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($lastError -notin @(2, 109, 231, 233)) { break }
        Start-Sleep -Milliseconds 25
    }
    if (-not $ok) {
        throw "CallNamedPipeW failed: $lastError"
    }
    [pscustomobject]@{
        Result = if ($read -ge 4) { [BitConverter]::ToUInt32($output, 0) } else { 0 }
        Body = if ($read -gt 4) { [Text.Encoding]::Unicode.GetString($output, 4, [int]$read - 4).TrimEnd([char]0) } else { '' }
    }
}

function Show-WeaselWindows([uint32]$ProcessId) {
    $callback = [RbCandidateInspectNative+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$ignored)
        [uint32]$windowProcessId = 0
        [void][RbCandidateInspectNative]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ($windowProcessId -eq $ProcessId) {
            $class = New-Object Text.StringBuilder 256
            $text = New-Object Text.StringBuilder 2048
            [void][RbCandidateInspectNative]::GetClassNameW($hwnd, $class, $class.Capacity)
            [void][RbCandidateInspectNative]::GetWindowTextW($hwnd, $text, $text.Capacity)
            Write-Host ('HWND=0x{0:X} Visible={1} Class="{2}" Text="{3}"' -f
                $hwnd.ToInt64(), [RbCandidateInspectNative]::IsWindowVisible($hwnd),
                $class.ToString(), $text.ToString())
        }
        return $true
    }
    [void][RbCandidateInspectNative]::EnumWindows($callback, [IntPtr]::Zero)
}

$server = Get-Process WeaselServer -ErrorAction Stop
$WM_APP = [uint32]0x8000
$session = 0
try {
    $metadata = "action=session`nsession.client_app=rime-bilingual-ui-inspect.exe`nsession.client_type=ime`n.`n"
    $session = (Invoke-WeaselMessage -Command ($WM_APP + 2) -Body $metadata).Result
    if ($session -eq 0) { throw 'START_SESSION failed.' }
    Write-Host "Session=$session"
    [void](Invoke-WeaselMessage -Command ($WM_APP + 6) -LParam $session)
    foreach ($char in $InputText.ToCharArray()) {
        $response = Invoke-WeaselMessage -Command ($WM_APP + 4) -WParam ([uint32][char]$char) -LParam $session
        Write-Host ("Key={0} Result={1}" -f $char, $response.Result)
        if ($response.Body) {
            $interesting = @($response.Body -split "`n" | Where-Object { $_ -match '^action=|^status\.|^ctx\.preedit=|^ctx\.cand=' })
            $interesting | ForEach-Object { Write-Host ('RESP ' + $_.TrimEnd("`r")) }
        }
    }
    Start-Sleep -Milliseconds 300
    Write-Host '--- WINDOWS ---'
    Show-WeaselWindows -ProcessId ([uint32]$server.Id)
    Start-Sleep -Seconds 2
    Write-Host '--- WINDOWS AFTER 2S (NO MORE KEY EVENTS) ---'
    Show-WeaselWindows -ProcessId ([uint32]$server.Id)
}
finally {
    if ($session -ne 0) {
        try { [void](Invoke-WeaselMessage -Command ($WM_APP + 3) -LParam ([uint32]$session)) } catch {}
    }
}
