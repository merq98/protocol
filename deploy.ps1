<#
.SYNOPSIS
  Build Xray from local source and deploy to VPS.

.DESCRIPTION
  1. Cross-compiles xray for linux/amd64 from the local Xray-core + REALITY fork.
  2. Builds xray.exe for local Windows client (v2rayN replacement).
  3. SCPs the linux binary to the server and restarts the service.

.PARAMETER ServerHost
  SSH destination (user@host or host). Default: merq@45.144.30.147

.PARAMETER ServerPort
  SSH port. Default: 22

.PARAMETER SkipServer
  Skip server deploy, only build locally.

.PARAMETER SkipClient
  Skip Windows client build.

.PARAMETER V2rayNPath
  Path to v2rayN's xray.exe to replace. If set, copies the new xray.exe there.

.EXAMPLE
  .\deploy.ps1
  .\deploy.ps1 -SkipClient
  .\deploy.ps1 -V2rayNPath "$env:LOCALAPPDATA\v2rayN\bin\Xray\xray.exe"
#>
param(
    [string]$ServerHost = "merq@45.144.30.147",
    [int]$ServerPort = 22,
    [switch]$SkipServer,
    [switch]$SkipClient,
    [string]$V2rayNPath
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$XrayCoreDir = Join-Path $ProjectRoot "Xray-core"
$BuildDir    = Join-Path $XrayCoreDir "build_assets"
$LinuxBin    = Join-Path $BuildDir "xray-linux"
$WindowsBin  = Join-Path $BuildDir "xray.exe"

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

# --- Validate ---
if (-not (Test-Path (Join-Path $XrayCoreDir "go.mod"))) {
    Write-Error "Xray-core/go.mod not found. Run from project root."
}

# --- Build Linux binary ---
if (-not $SkipServer) {
    Write-Step "Building xray for linux/amd64"
    Push-Location $XrayCoreDir
    try {
        $env:GOOS = "linux"
        $env:GOARCH = "amd64"
        $env:CGO_ENABLED = "0"
        go build -trimpath -ldflags='-s -w' -o $LinuxBin ./main
        if ($LASTEXITCODE -ne 0) { throw "Linux build failed" }
    }
    finally {
        Remove-Item Env:GOOS -ErrorAction SilentlyContinue
        Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
        Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
        Pop-Location
    }
    $size = [math]::Round((Get-Item $LinuxBin).Length / 1MB, 1)
    Write-Host "  Built: xray-linux ($size MB)"
}

# --- Build Windows binary ---
if (-not $SkipClient) {
    Write-Step "Building xray.exe for windows/amd64"
    Push-Location $XrayCoreDir
    try {
        go build -trimpath -ldflags='-s -w' -o $WindowsBin ./main
        if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }
    }
    finally {
        Pop-Location
    }
    $size = [math]::Round((Get-Item $WindowsBin).Length / 1MB, 1)
    Write-Host "  Built: xray.exe ($size MB)"

    if ($V2rayNPath) {
        Write-Step "Copying xray.exe to v2rayN"
        Copy-Item -Path $WindowsBin -Destination $V2rayNPath -Force
        Write-Host "  Copied to: $V2rayNPath"
    }
}

# --- Deploy to server ---
if (-not $SkipServer) {
    Write-Step "Uploading xray-linux to $ServerHost"
    scp -P $ServerPort $LinuxBin "${ServerHost}:/tmp/xray"
    if ($LASTEXITCODE -ne 0) { throw "SCP failed" }

    Write-Step "Installing and restarting on server"
    ssh -p $ServerPort $ServerHost @"
set -e
sudo install -m 0755 /tmp/xray /usr/local/bin/xray
/usr/local/bin/xray version
sudo systemctl restart xray
sleep 1
sudo systemctl is-active xray
echo '--- Last 5 log lines ---'
sudo journalctl -u xray -n 5 --no-pager
"@
    if ($LASTEXITCODE -ne 0) { throw "Remote deploy failed" }
}

Write-Step "Done"
if (-not $SkipServer) { Write-Host "  Server: updated and restarted" }
if (-not $SkipClient) { Write-Host "  Client: $WindowsBin" }
