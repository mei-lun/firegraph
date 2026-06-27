# 一键停止 firegraph + skynet + 监控
$ErrorActionPreference = "SilentlyContinue"
$ROOT = Split-Path -Parent $PSScriptRoot
$LOG_DIR = Join-Path $ROOT "logs"

Write-Host "===== stop all =====" -ForegroundColor Yellow

# 1. 停止监控
Write-Host "[1/3] stopping monitor..." -ForegroundColor Cyan
$monPid = Get-Content (Join-Path $LOG_DIR "monitor.pid") -ErrorAction SilentlyContinue
if ($monPid) { Stop-Process -Id $monPid -Force -ErrorAction SilentlyContinue }
Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'monitor\.ps1' } | Stop-Process -Force

# 2. 停止 firegraph 守护 + 应用
Write-Host "[2/3] stopping firegraph..." -ForegroundColor Cyan
$fgDaemonPid = Get-Content (Join-Path $LOG_DIR "fg_daemon.pid") -ErrorAction SilentlyContinue
if ($fgDaemonPid) { Stop-Process -Id $fgDaemonPid -Force -ErrorAction SilentlyContinue }
Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'daemon_firegraph' } | Stop-Process -Force
Get-Process -Name firegraph -ErrorAction SilentlyContinue | Stop-Process -Force

# 3. 停止 skynet 守护 + 应用（精确 kill，不用 pkill -f 避免误伤自身）
Write-Host "[3/3] stopping skynet..." -ForegroundColor Cyan
wsl -d Ubuntu-24.04 -- bash -c "for p in \$(pgrep -f 'skynet examples/config.firegraph'); do kill \$p 2>/dev/null; done; for p in \$(pgrep -f daemon_skynet.sh); do kill \$p 2>/dev/null; done" 2>$null

Start-Sleep -Seconds 2

# 确认
$fg = Get-Process -Name firegraph -ErrorAction SilentlyContinue
$sk = wsl -d Ubuntu-24.04 -- bash -c "pgrep -f 'skynet examples'" 2>$null
Write-Host ""
if ($fg) { Write-Host "  firegraph: still running" -ForegroundColor Red }
else { Write-Host "  firegraph: stopped" -ForegroundColor Green }
if ($sk) { Write-Host "  skynet: still running" -ForegroundColor Red }
else { Write-Host "  skynet: stopped" -ForegroundColor Green }
Write-Host ""
Write-Host "===== done =====" -ForegroundColor Green
