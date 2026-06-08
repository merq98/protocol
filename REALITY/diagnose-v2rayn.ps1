# diagnose-v2rayn.ps1 — Collect direct / SOCKS / TUN diagnostics for v2rayN on Windows.
#
# Usage:
#   .\diagnose-v2rayn.ps1
#   .\diagnose-v2rayn.ps1 -V2rayNPath "C:\Users\Stas\Documents\v2rayN-windows-64"
#   .\diagnose-v2rayn.ps1 -OutFile "$HOME\Desktop\v2rayn-diag.txt"
#
# Run three times for best results:
#   1) v2rayN OFF  — direct baseline
#   2) v2rayN ON, TUN OFF, Global — SOCKS test
#   3) v2rayN ON, TUN ON — full VPN test

param(
    [string]$V2rayNPath = "$env:USERPROFILE\Documents\v2rayN-windows-64",
    [string]$OutFile = "",
    [int]$SocksPort = 10808,
    [int]$TimeoutSec = 10
)

$ErrorActionPreference = "Continue"
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$Text) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text"
    $lines.Add($line) | Out-Null
    Write-Host $line
}

function Test-CurlIp([string]$Label, [string[]]$CurlArgs) {
    Add-Line "=== $Label ==="
    try {
        $out = & curl.exe @CurlArgs 2>&1
        $text = ($out | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Add-Line "FAIL exit=$LASTEXITCODE"
            Add-Line $text
            return $null
        }
        Add-Line "OK: $text"
        return $text
    }
    catch {
        Add-Line "ERROR: $_"
        return $null
    }
}

Add-Line "v2rayN diagnostics"
Add-Line "V2rayNPath: $V2rayNPath"
Add-Line "Note: run with v2rayN OFF, then ON (TUN off), then ON (TUN on) for full picture"
Add-Line ""

# Port listeners
Add-Line "=== Listening ports ==="
$portCheck = netstat -an | Select-String ":$SocksPort\s"
if ($portCheck) {
    Add-Line "Port $SocksPort is listening"
    $portCheck | ForEach-Object { Add-Line $_.Line.Trim() }
}
else {
    Add-Line "Port $SocksPort is NOT listening (v2rayN likely off or wrong port)"
}

# GUI config snapshot
$guiConfig = Join-Path $V2rayNPath "guiConfigs\guiNConfig.json"
if (Test-Path $guiConfig) {
    Add-Line "=== guiNConfig.json ==="
    $cfg = Get-Content $guiConfig -Raw | ConvertFrom-Json
    Add-Line "EnableTun: $($cfg.TunModeItem.EnableTun)"
    Add-Line "Tun Stack: $($cfg.TunModeItem.Stack)"
    Add-Line "Tun StrictRoute: $($cfg.TunModeItem.StrictRoute)"
    Add-Line "Tun MTU: $($cfg.TunModeItem.Mtu)"
    Add-Line "SysProxyType: $($cfg.SystemProxyItem.SysProxyType) (1=PAC, 2=Global)"
    Add-Line "EnableFragment: $($cfg.CoreBasicItem.EnableFragment)"
    Add-Line "XudpProxyUDP443: $($cfg.Mux4RayItem.XudpProxyUDP443)"
}
else {
    Add-Line "guiNConfig.json not found: $guiConfig"
}

Add-Line ""

# Connectivity tests
Test-CurlIp "Direct (no proxy)" @(
    "--connect-timeout", "$TimeoutSec",
    "--max-time", "$([int]($TimeoutSec + 5))",
    "https://api.ipify.org"
) | Out-Null

Test-CurlIp "SOCKS5 127.0.0.1:$SocksPort" @(
    "--connect-timeout", "$TimeoutSec",
    "--max-time", "$([int]($TimeoutSec + 5))",
    "--socks5", "127.0.0.1:$SocksPort",
    "https://api.ipify.org"
) | Out-Null

Test-CurlIp "HTTP proxy 127.0.0.1:$SocksPort" @(
    "--connect-timeout", "$TimeoutSec",
    "--max-time", "$([int]($TimeoutSec + 5))",
    "--proxy", "http://127.0.0.1:$SocksPort",
    "https://api.ipify.org"
) | Out-Null

Add-Line "=== DNS youtube.com ==="
try {
    Resolve-DnsName youtube.com -ErrorAction Stop | Select-Object -First 3 | ForEach-Object {
        Add-Line "$($_.Name) -> $($_.IPAddress)"
    }
}
catch {
    Add-Line "DNS FAIL: $_"
}

Add-Line "=== Default routes ==="
Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Select-Object -First 5 |
    ForEach-Object {
        Add-Line "if=$($_.InterfaceAlias) next=$($_.NextHop) metric=$($_.RouteMetric)"
    }

Add-Line "=== DNS servers (IPv4) ==="
Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.ServerAddresses } |
    Select-Object -First 8 |
    ForEach-Object {
        Add-Line "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')"
    }

# sing-box TUN config hints
$configPre = Join-Path $V2rayNPath "binConfigs\configPre.json"
if (Test-Path $configPre) {
    Add-Line "=== configPre.json (sing-box) ==="
    $pre = Get-Content $configPre -Raw | ConvertFrom-Json
    $tun = $pre.inbounds | Where-Object { $_.type -eq "tun" } | Select-Object -First 1
    if ($tun) {
        Add-Line "tun stack=$($tun.stack) strict_route=$($tun.strict_route) mtu=$($tun.mtu)"
    }
    $udpReject = $pre.route.rules | Where-Object {
        $_.network -contains "udp" -and $_.port -contains 443 -and $_.action -eq "reject"
    }
    if ($udpReject) {
        Add-Line "WARNING: sing-box route rejects UDP/443 (breaks YouTube QUIC)"
    }
}

Add-Line ""
Add-Line "=== Interpretation ==="
Add-Line "Direct=home IP, SOCKS=VPS IP -> outbound works, fix TUN next"
Add-Line "Direct=home, SOCKS=timeout -> fix REALITY/outbound before enabling TUN"
Add-Line "SOCKS=VPS, TUN curl=home IP -> TUN route/DNS issue"
Add-Line "Port 10808 closed -> start v2rayN or check mixed port setting"

if ($OutFile) {
    $lines | Set-Content -Path $OutFile -Encoding UTF8
    Add-Line "Saved to $OutFile"
}
