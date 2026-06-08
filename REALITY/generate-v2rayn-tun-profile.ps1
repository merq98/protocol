# generate-v2rayn-tun-profile.ps1 — Apply safe v2rayN presets for SOCKS/TUN testing.
#
# Usage (run with v2rayN fully closed):
#   .\generate-v2rayn-tun-profile.ps1 -Preset socks-test
#   .\generate-v2rayn-tun-profile.ps1 -Preset tun-system
#   .\generate-v2rayn-tun-profile.ps1 -Preset tun-gvisor
#   .\generate-v2rayn-tun-profile.ps1 -Preset tun-relaxed
#   .\generate-v2rayn-tun-profile.ps1 -Preset tun-system -FixSingboxUdp443
#   .\generate-v2rayn-tun-profile.ps1 -Preset tun-system -FixTunDns -FixSingboxUdp443
#   .\generate-v2rayn-tun-profile.ps1 -Preset socks-test -EnableFragment
#
# Presets:
#   socks-test   — TUN off, Global proxy, Fragment off, XUDP UDP443=proxy
#   tun-system   — TUN on, stack=system, strict_route=true
#   tun-gvisor   — TUN on, stack=gvisor, strict_route=true
#   tun-relaxed  — TUN on, stack=system, strict_route=false (test routing issues)

param(
    [string]$V2rayNPath = "$env:USERPROFILE\Documents\v2rayN-windows-64",
    [ValidateSet("socks-test", "tun-system", "tun-gvisor", "tun-relaxed")]
    [string]$Preset = "socks-test",
    [string]$VpsIp = "37.220.83.19",
    [switch]$EnableFragment,
    [switch]$FixSingboxUdp443,
    [switch]$FixTunDns,
    [switch]$FixOutboundRouting,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$guiConfigPath = Join-Path $V2rayNPath "guiConfigs\guiNConfig.json"
$configPrePath = Join-Path $V2rayNPath "binConfigs\configPre.json"
$configPath = Join-Path $V2rayNPath "binConfigs\config.json"

if (-not (Test-Path $guiConfigPath)) {
    throw "guiNConfig.json not found: $guiConfigPath"
}

$cfg = Get-Content $guiConfigPath -Raw | ConvertFrom-Json
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$guiConfigPath.bak-$stamp"
Copy-Item $guiConfigPath $backup
Write-Host "Backup: $backup"

# Shared safe defaults (do not touch UUID/keys in server profiles).
# Keep Fragment off by default: on this setup it made local SOCKS/HTTP proxy
# time out, while plain REALITY reached the VPS and returned the VPS IP.
$cfg.CoreBasicItem.EnableFragment = [bool]$EnableFragment
$cfg.CoreBasicItem.MuxEnabled = $false
$cfg.Mux4RayItem.XudpProxyUDP443 = "proxy"
if ($null -eq $cfg.TunModeItem.Mtu -or $cfg.TunModeItem.Mtu -lt 1280) {
    $cfg.TunModeItem.Mtu = 1500
}
$cfg.TunModeItem.AutoRoute = $true
$cfg.TunModeItem.EnableIPv6Address = $false

switch ($Preset) {
    "socks-test" {
        $cfg.TunModeItem.EnableTun = $false
        $cfg.TunModeItem.Stack = "system"
        $cfg.TunModeItem.StrictRoute = $true
        $cfg.SystemProxyItem.SysProxyType = 2   # Global
        Write-Host "Preset socks-test: TUN off, Global proxy, Fragment off, XUDP UDP443=proxy"
    }
    "tun-system" {
        $cfg.TunModeItem.EnableTun = $true
        $cfg.TunModeItem.Stack = "system"
        $cfg.TunModeItem.StrictRoute = $true
        $cfg.SystemProxyItem.SysProxyType = 0   # off when using TUN
        Write-Host "Preset tun-system: TUN on, stack=system, strict_route=true"
    }
    "tun-gvisor" {
        $cfg.TunModeItem.EnableTun = $true
        $cfg.TunModeItem.Stack = "gvisor"
        $cfg.TunModeItem.StrictRoute = $true
        $cfg.SystemProxyItem.SysProxyType = 0
        Write-Host "Preset tun-gvisor: TUN on, stack=gvisor, strict_route=true"
    }
    "tun-relaxed" {
        $cfg.TunModeItem.EnableTun = $true
        $cfg.TunModeItem.Stack = "system"
        $cfg.TunModeItem.StrictRoute = $false
        $cfg.SystemProxyItem.SysProxyType = 0
        Write-Host "Preset tun-relaxed: TUN on, stack=system, strict_route=false"
    }
}

if ($WhatIf) {
    Write-Host "WhatIf: would write $guiConfigPath"
    $cfg | ConvertTo-Json -Depth 20
    exit 0
}

$cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $guiConfigPath -Encoding UTF8
Write-Host "Updated: $guiConfigPath"
Write-Host "Restart v2rayN completely (tray icon too), then run diagnose-v2rayn.ps1"

function Remove-Udp443RejectRule([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) {
        Write-Host "Skip UDP443 fix: not found $JsonPath"
        return
    }
    $raw = Get-Content $JsonPath -Raw | ConvertFrom-Json
    if (-not $raw.route.rules) {
        return
    }
    $before = $raw.route.rules.Count
    $raw.route.rules = @(
        $raw.route.rules | Where-Object {
            -not (
                $_.action -eq "reject" -and
                $_.network -contains "udp" -and
                ($_.port -contains 443 -or $_.port_range -contains "443:443")
            )
        }
    )
    $removed = $before - $raw.route.rules.Count
    if ($removed -gt 0) {
        $bak = "$JsonPath.bak-$stamp"
        Copy-Item $JsonPath $bak
        $raw | ConvertTo-Json -Depth 30 | Set-Content -Path $JsonPath -Encoding UTF8
        Write-Host ("Removed {0} UDP/443 reject rule(s) from {1} (backup: {2})" -f $removed, $JsonPath, $bak)
        Write-Host "Note: v2rayN may regenerate configPre on restart; re-run with -FixSingboxUdp443 if needed"
    }
    else {
        Write-Host "No UDP/443 reject rule in $JsonPath"
    }
}

function Remove-XrayUdp443Block([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) {
        return
    }
    $raw = Get-Content $JsonPath -Raw | ConvertFrom-Json
    if (-not $raw.routing.rules) {
        return
    }
    $before = $raw.routing.rules.Count
    $raw.routing.rules = @(
        $raw.routing.rules | Where-Object {
            -not ($_.outboundTag -eq "block" -and $_.network -eq "udp" -and $_.port -eq "443")
        }
    )
    $removed = $before - $raw.routing.rules.Count
    if ($removed -gt 0) {
        $bak = "$JsonPath.bak-$stamp"
        Copy-Item $JsonPath $bak
        $raw | ConvertTo-Json -Depth 30 | Set-Content -Path $JsonPath -Encoding UTF8
        Write-Host ("Removed {0} xray UDP/443 block rule(s) from {1}" -f $removed, $JsonPath)
    }
}

function Add-VpsBypassRule([string]$JsonPath, [string]$VpsIp) {
    if (-not (Test-Path $JsonPath)) {
        return
    }
    $raw = Get-Content $JsonPath -Raw | ConvertFrom-Json
    if (-not $raw.routing.rules) {
        return
    }
    $hasBypass = $false
    foreach ($rule in $raw.routing.rules) {
        if ($rule.ip -contains $VpsIp -and $rule.outboundTag -eq "direct") {
            $hasBypass = $true
            break
        }
    }
    if ($hasBypass) {
        Write-Host "VPS bypass rule already present in $JsonPath"
        return
    }
    $bypass = [PSCustomObject]@{
        type         = "field"
        ip           = @($VpsIp)
        outboundTag  = "direct"
    }
    $rules = [System.Collections.Generic.List[object]]::new()
    $inserted = $false
    foreach ($rule in $raw.routing.rules) {
        if (-not $inserted -and $rule.port -eq "0-65535" -and $rule.outboundTag -eq "proxy") {
            $rules.Add($bypass) | Out-Null
            $inserted = $true
        }
        $rules.Add($rule) | Out-Null
    }
    if (-not $inserted) {
        $rules.Insert(0, $bypass) | Out-Null
    }
    $raw.routing.rules = $rules.ToArray()
    $bak = "$JsonPath.bak-$stamp"
    Copy-Item $JsonPath $bak
    $raw | ConvertTo-Json -Depth 30 | Set-Content -Path $JsonPath -Encoding UTF8
    Write-Host ("Added VPS bypass {0} -> direct in {1}" -f $VpsIp, $JsonPath)
}

function Set-TunDnsDirect([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) {
        Write-Host "Skip TUN DNS fix: not found $JsonPath"
        return
    }

    $raw = Get-Content $JsonPath -Raw | ConvertFrom-Json
    if (-not $raw.dns) {
        return
    }

    $changed = $false

    foreach ($server in $raw.dns.servers) {
        if ($server.tag -eq "remote_dns") {
            # In TUN mode this path can deadlock through the internal
            # 127.0.0.1 relay. Use direct DNS for resolution; normal TCP/UDP
            # traffic still follows the route.final = proxy path.
            $server.server = "dns.alidns.com"
            $server.path = "/dns-query"
            $server.type = "https"
            $server.PSObject.Properties.Remove("detour")
            $server.PSObject.Properties.Remove("domain_resolver")
            $changed = $true
        }
    }

    if ($raw.dns.final -ne "direct_dns") {
        $raw.dns.final = "direct_dns"
        $changed = $true
    }

    foreach ($rule in $raw.dns.rules) {
        if ($rule.server -eq "remote_dns") {
            $rule.server = "direct_dns"
            $changed = $true
        }
    }

    if ($changed) {
        $bak = "$JsonPath.bak-$stamp"
        Copy-Item $JsonPath $bak
        $raw | ConvertTo-Json -Depth 30 | Set-Content -Path $JsonPath -Encoding UTF8
        Write-Host ("Set TUN DNS to direct_dns in {0} (backup: {1})" -f $JsonPath, $bak)
    }
    else {
        Write-Host "TUN DNS already uses direct path in $JsonPath"
    }
}

if ($FixSingboxUdp443) {
    Remove-Udp443RejectRule $configPrePath
    Remove-XrayUdp443Block $configPath
}

if ($FixTunDns) {
    Set-TunDnsDirect $configPrePath
}

if (-not $WhatIf -and ($FixOutboundRouting -or $Preset -eq "socks-test")) {
    Add-VpsBypassRule $configPath $VpsIp
    Remove-XrayUdp443Block $configPath
}
