# set-v2rayn-ws-relay.ps1 — Patch v2rayN Xray client config to use wsRelay.
#
# Usage (run with v2rayN fully closed):
#   .\set-v2rayn-ws-relay.ps1 -WsRelayUrl "wss://relay.example.com/ws"
#   .\set-v2rayn-ws-relay.ps1 -Clear
#
# Then restart v2rayN and test:
#   curl.exe --max-time 20 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org -v

param(
    [string]$V2rayNPath = "$env:USERPROFILE\Documents\v2rayN-windows-64",
    [string]$WsRelayUrl = "",
    [string]$VpsIp = "37.220.83.19",
    [switch]$Clear,
    [switch]$ApplySafePreset,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if ($ApplySafePreset -and -not $WhatIf) {
    $presetScript = Join-Path $PSScriptRoot "generate-v2rayn-tun-profile.ps1"
    if (Test-Path $presetScript) {
        Write-Host "Applying socks-test preset first"
        & $presetScript -Preset socks-test -FixOutboundRouting -FixSingboxUdp443 -V2rayNPath $V2rayNPath
    }
}

$configPath = Join-Path $V2rayNPath "binConfigs\config.json"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

if (-not (Test-Path $configPath)) {
    throw "config.json not found: $configPath. Start v2rayN once, then close it and retry."
}

if (-not $Clear) {
    if ([string]::IsNullOrWhiteSpace($WsRelayUrl)) {
        throw "WsRelayUrl is required unless -Clear is set. Example: wss://relay.example.com/ws"
    }
    if ($WsRelayUrl -notmatch '^wss://') {
        throw "WsRelayUrl must start with wss://"
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$configPath.bak-wsrelay-$stamp"
Copy-Item $configPath $backup
Write-Host "Backup: $backup"

$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
$proxy = $cfg.outbounds | Where-Object { $_.tag -eq "proxy" } | Select-Object -First 1
if (-not $proxy) {
    throw "Outbound tag=proxy not found in $configPath"
}

if (-not $proxy.streamSettings) {
    $proxy | Add-Member -NotePropertyName streamSettings -NotePropertyValue ([PSCustomObject]@{})
}
if (-not $proxy.streamSettings.realitySettings) {
    $proxy.streamSettings | Add-Member -NotePropertyName realitySettings -NotePropertyValue ([PSCustomObject]@{})
}

if ($Clear) {
    $proxy.streamSettings.realitySettings.PSObject.Properties.Remove("wsRelay")
    Write-Host "Removed wsRelay from client config"
}
else {
    $proxy.streamSettings.realitySettings | Add-Member -NotePropertyName wsRelay -NotePropertyValue $WsRelayUrl -Force
    Write-Host "Set wsRelay = $WsRelayUrl"
}

# Keep VPS IP reachable directly to avoid self-proxy loops when routing is enabled.
if ($cfg.routing -and $cfg.routing.rules) {
    $hasBypass = $false
    foreach ($rule in $cfg.routing.rules) {
        if ($rule.ip -contains $VpsIp -and $rule.outboundTag -eq "direct") {
            $hasBypass = $true
            break
        }
    }
    if (-not $hasBypass) {
        $bypass = [PSCustomObject]@{
            type        = "field"
            ip          = @($VpsIp)
            outboundTag = "direct"
        }
        $rules = [System.Collections.Generic.List[object]]::new()
        $inserted = $false
        foreach ($rule in $cfg.routing.rules) {
            if (-not $inserted -and $rule.port -eq "0-65535" -and $rule.outboundTag -eq "proxy") {
                $rules.Add($bypass) | Out-Null
                $inserted = $true
            }
            $rules.Add($rule) | Out-Null
        }
        if (-not $inserted) {
            $rules.Insert(0, $bypass) | Out-Null
        }
        $cfg.routing.rules = $rules.ToArray()
        Write-Host "Added VPS bypass $VpsIp -> direct"
    }
}

if ($WhatIf) {
    $cfg | ConvertTo-Json -Depth 30
    exit 0
}

Write-Utf8NoBom $configPath ($cfg | ConvertTo-Json -Depth 30)

Write-Host ""
Write-Host "Restart v2rayN completely (tray icon too)."
Write-Host "Test:"
Write-Host "  curl.exe --max-time 20 --connect-timeout 10 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org -v"
