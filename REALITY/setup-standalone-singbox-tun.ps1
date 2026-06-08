# setup-standalone-singbox-tun.ps1 - Create a standalone sing-box TUN over v2rayN SOCKS.
#
# This avoids v2rayN's built-in TUN config generator. v2rayN stays responsible
# only for the already working VLESS+REALITY outbound on 127.0.0.1:10808.
#
# Usage (run with v2rayN closed):
#   .\setup-standalone-singbox-tun.ps1
#   .\setup-standalone-singbox-tun.ps1 -Stack system
#   .\setup-standalone-singbox-tun.ps1 -StrictRoute:$false
#   .\setup-standalone-singbox-tun.ps1 -SingBoxExe C:\path\to\sing-box.exe
#
# Then:
#   1. Start v2rayN with TUN/VPN off and Global profile selected.
#   2. Run generated start script as Administrator:
#        C:\Users\Stas\Documents\v2rayN-windows-64\standalone-singbox-tun\start-singbox-tun.ps1
#   3. Verify:
#        curl.exe https://api.ipify.org

param(
    [string]$V2rayNPath = "$env:USERPROFILE\Documents\v2rayN-windows-64",
    [string]$InstallDir = "$env:USERPROFILE\Documents\v2rayN-windows-64\standalone-singbox-tun",
    [int]$UpstreamSocksPort = 10808,
    [string]$VpsIp = "37.220.83.19",
    [string]$SingBoxExe = "",
    [ValidateSet("system", "gvisor", "mixed")]
    [string]$Stack = "system",
    [bool]$StrictRoute = $true,
    [switch]$SkipDownload,
    [switch]$SkipV2rayNConfig
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Assert-AdminHint {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Note: setup can run without admin, but start-singbox-tun.ps1 must run as Administrator." -ForegroundColor Yellow
    }
}

function Disable-V2rayNTun([string]$ConfigPath) {
    if (-not (Test-Path $ConfigPath)) {
        throw "v2rayN config not found: $ConfigPath"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$ConfigPath.bak-standalone-tun-$stamp"
    Copy-Item $ConfigPath $backup

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $cfg.TunModeItem.EnableTun = $false
    $cfg.CoreBasicItem.EnableFragment = $false
    $cfg.CoreBasicItem.MuxEnabled = $false
    $cfg.Mux4RayItem.XudpProxyUDP443 = "proxy"
    $cfg.SystemProxyItem.SysProxyType = 2
    Write-Utf8NoBom $ConfigPath ($cfg | ConvertTo-Json -Depth 30)

    Write-Step "Disabled v2rayN built-in TUN and kept Global system proxy preset"
    Write-Host "Backup: $backup"
}

function Download-SingBox([string]$TargetDir) {
    $exe = Join-Path $TargetDir "sing-box.exe"
    if (Test-Path $exe) {
        Write-Step "sing-box already exists: $exe"
        return $exe
    }

    if ($SingBoxExe) {
        if (-not (Test-Path $SingBoxExe)) {
            throw "Provided sing-box.exe not found: $SingBoxExe"
        }
        Copy-Item $SingBoxExe $exe -Force
        Write-Step "Copied provided sing-box.exe to $exe"
        return $exe
    }

    if ($SkipDownload) {
        throw "sing-box.exe not found in $TargetDir and -SkipDownload was set"
    }

    Write-Step "Downloading latest sing-box windows-amd64 release"
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/SagerNet/sing-box/releases/latest" -Headers @{ "User-Agent" = "protocol-setup" }
    }
    catch {
        Write-Host "GitHub API download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Trying winget package SagerNet.sing-box..." -ForegroundColor Yellow

        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw "GitHub download failed and winget.exe was not found. Install sing-box manually or pass -SingBoxExe."
        }

        & winget install -e --id SagerNet.sing-box --accept-package-agreements --accept-source-agreements
        $installed = Get-Command sing-box.exe -ErrorAction SilentlyContinue
        if (-not $installed) {
            $candidates = @(
                "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\SagerNet.sing-box_Microsoft.Winget.Source_8wekyb3d8bbwe",
                "$env:ProgramFiles\sing-box",
                "$env:LOCALAPPDATA\Programs\sing-box"
            )
            foreach ($candidate in $candidates) {
                if (Test-Path $candidate) {
                    $found = Get-ChildItem -Path $candidate -Recurse -Filter "sing-box.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) {
                        $installed = $found
                        break
                    }
                }
            }
        }
        if (-not $installed) {
            throw "winget completed but sing-box.exe was not found. Re-run with -SingBoxExe C:\path\to\sing-box.exe."
        }
        $installedPath = if ($installed.Source) { $installed.Source } else { $installed.FullName }
        Copy-Item $installedPath $exe -Force
        Write-Step "Installed $exe from winget package"
        return $exe
    }

    $asset = $release.assets |
        Where-Object { $_.name -match "windows-amd64.*\.zip$" -and $_.name -notmatch "legacy" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find windows-amd64 sing-box release asset"
    }

    $zipPath = Join-Path $TargetDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath

    $extractDir = Join-Path $TargetDir "extract"
    if (Test-Path $extractDir) {
        Remove-Item $extractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $downloadedExe = Get-ChildItem -Path $extractDir -Recurse -Filter "sing-box.exe" | Select-Object -First 1
    if (-not $downloadedExe) {
        throw "Downloaded archive does not contain sing-box.exe"
    }

    Copy-Item $downloadedExe.FullName $exe -Force
    Write-Step "Installed $exe"
    return $exe
}

function New-Config([string]$ConfigPath) {
    $config = [ordered]@{
        log = [ordered]@{
            level = "info"
            timestamp = $true
        }
        dns = [ordered]@{
            servers = @(
                [ordered]@{
                    tag = "remote"
                    type = "https"
                    server = "1.1.1.1"
                    path = "/dns-query"
                    detour = "proxy"
                },
                [ordered]@{
                    tag = "local"
                    type = "udp"
                    server = "223.5.5.5"
                    detour = "direct"
                }
            )
            rules = @(
                [ordered]@{
                    query_type = @(64, 65)
                    action = "predefined"
                    rcode = "NOERROR"
                }
            )
            final = "remote"
            independent_cache = $true
        }
        inbounds = @(
            [ordered]@{
                type = "tun"
                tag = "tun-in"
                interface_name = "protocol_tun"
                address = @("172.19.0.1/30")
                mtu = 1500
                auto_route = $true
                strict_route = $StrictRoute
                stack = $Stack
                route_exclude_address = @(
                    "$VpsIp/32",
                    "127.0.0.0/8",
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "192.168.0.0/16"
                )
            }
        )
        outbounds = @(
            [ordered]@{
                type = "socks"
                tag = "proxy"
                server = "127.0.0.1"
                server_port = $UpstreamSocksPort
                version = "5"
            },
            [ordered]@{
                type = "direct"
                tag = "direct"
            },
            [ordered]@{
                type = "block"
                tag = "block"
            }
        )
        route = [ordered]@{
            auto_detect_interface = $true
            default_domain_resolver = "local"
            rules = @(
                [ordered]@{
                    inbound = @("tun-in")
                    action = "sniff"
                    timeout = "1s"
                },
                [ordered]@{
                    protocol = @("dns")
                    action = "hijack-dns"
                },
                [ordered]@{
                    process_name = @(
                        "v2rayN.exe",
                        "v2ray.exe",
                        "xray.exe",
                        "sing-box.exe"
                    )
                    outbound = "direct"
                },
                [ordered]@{
                    ip_cidr = @("$VpsIp/32")
                    outbound = "direct"
                },
                [ordered]@{
                    ip_is_private = $true
                    outbound = "direct"
                }
            )
            final = "proxy"
        }
    }

    Write-Utf8NoBom $ConfigPath ($config | ConvertTo-Json -Depth 40)
    Write-Step "Wrote config: $ConfigPath"
}

function New-HelperScripts([string]$TargetDir, [string]$SingBoxExe, [string]$ConfigPath) {
    $startPath = Join-Path $TargetDir "start-singbox-tun.ps1"
    $stopPath = Join-Path $TargetDir "stop-singbox-tun.ps1"

    @"
`$ErrorActionPreference = "Stop"
`$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not `$isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ```"`$PSCommandPath```""
    exit
}
Set-Location "$TargetDir"
& "$SingBoxExe" run -c "$ConfigPath"
"@ | ForEach-Object { Write-Utf8NoBom $startPath $_ }

    @"
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
"@ | ForEach-Object { Write-Utf8NoBom $stopPath $_ }

    Write-Step "Wrote helper scripts:"
    Write-Host "  $startPath"
    Write-Host "  $stopPath"
}

Assert-AdminHint

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

if (-not $SkipV2rayNConfig) {
    Disable-V2rayNTun (Join-Path $V2rayNPath "guiConfigs\guiNConfig.json")
}

$singBoxExe = Download-SingBox $InstallDir
$configPath = Join-Path $InstallDir "config.json"
New-Config $configPath
New-HelperScripts $InstallDir $singBoxExe $configPath

Write-Host ""
Write-Step "Next steps"
Write-Host "1. Start v2rayN with built-in TUN/VPN OFF."
Write-Host "2. Verify upstream proxy: curl.exe --socks5-hostname 127.0.0.1:$UpstreamSocksPort https://api.ipify.org"
Write-Host "3. Run as Administrator: $InstallDir\start-singbox-tun.ps1"
Write-Host "4. Verify TUN: curl.exe https://api.ipify.org"
