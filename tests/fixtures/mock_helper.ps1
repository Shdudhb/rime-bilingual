param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][ValidateSet('success', 'invalid', 'non2xx')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$ReadyPath
)

$ErrorActionPreference = 'Stop'
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
    [IO.File]::WriteAllText($ReadyPath, 'ready', (New-Object Text.UTF8Encoding($false)))
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
        $terminatorState = 0
        while ($terminatorState -lt 4) {
            $next = $stream.ReadByte()
            if ($next -lt 0) { throw 'request ended before HTTP headers completed' }
            $headerBytes.Add([byte]$next)
            if (($terminatorState -eq 0 -or $terminatorState -eq 2) -and $next -eq 13) { $terminatorState++ }
            elseif (($terminatorState -eq 1 -or $terminatorState -eq 3) -and $next -eq 10) { $terminatorState++ }
            elseif ($next -eq 13) { $terminatorState = 1 }
            else { $terminatorState = 0 }
        }
        $headers = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
        $contentLength = 0
        if ($headers -match '(?im)^Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
        $bodyBuffer = New-Object byte[] $contentLength
        $bodyRead = 0
        while ($bodyRead -lt $contentLength) {
            $count = $stream.Read($bodyBuffer, $bodyRead, $contentLength - $bodyRead)
            if ($count -le 0) { throw 'request ended before HTTP body completed' }
            $bodyRead += $count
        }
        if ($Mode -eq 'success') {
            $status = '200 OK'
            $body = '{"protocol_version":1,"request_id":"test-params","translations":["I","You","He","Today"],"model":"mock-model","elapsed_ms":7}'
        } elseif ($Mode -eq 'invalid') {
            $status = '200 OK'
            $body = '{"protocol_version":1,"request_id":"test-params","translations":["I"],"model":"mock-model","elapsed_ms":7}'
        } else {
            $status = '503 Service Unavailable'
            $body = '{"protocol_version":1,"request_id":"test-params","error":{"code":"MODEL_UNAVAILABLE","message":"offline","retryable":true}}'
        }
        $bodyBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($body)
        $header = "HTTP/1.1 $status`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()
    } finally { $client.Dispose() }
} finally { $listener.Stop() }
