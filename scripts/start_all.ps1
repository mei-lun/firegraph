#一键启动 firegraph + skynet + 监控（全部后台守护）
$ErrorActionPreference = "SilentlyContinue"
$ROOT = Split-Path -Parent $PSScriptRoot
$LOG_DIR = Join-Path $ROOT "logs"
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

Write-Host "===== firegraph one-key start =====" -ForegroundColor Green

# 1. 清理残留（精确 kill，不用 pkill -f 避免误伤）
Write-Host "[1/4] cleaning..." -ForegroundColor Cyan
Get-Process -Name firegraph -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'daemon_firegraph|daemon_skynet|monitor\.ps1' } | Stop-Process -Force
wsl -d Ubuntu-24.04 -- bash -c "for p in \$(pgrep -f 'skynet examples/config.firegraph'); do kill \$p 2>/dev/null; done; for p in \$(pgrep -f daemon_skynet.sh); do kill \$p 2>/dev/null; done" 2>$null
Start-Sleep -Seconds 2

# 2. 启动 firegraph 守护（Hidden 后台）
Write-Host "[2/4] starting firegraph daemon..." -ForegroundColor Cyan
$fg = Start-Process powershell -ArgumentList "-ExecutionPolicy", "Bypass", "-File", "$ROOT\scripts\daemon_firegraph.ps1" -WindowStyle Hidden -PassThru
$fg.Id | Out-File (Join-Path $LOG_DIR "fg_daemon.pid") -Encoding ascii
Write-Host "  daemon PID=$($fg.Id)" -ForegroundColor Gray

# 3. 启动 skynet 守护（WSL nohup 后台）
Write-Host "[3/4] starting skynet daemon (WSL)..." -ForegroundColor Cyan
wsl -d Ubuntu-24.04 -- bash -c "cd /mnt/d/MyPoj/myskynet && nohup bash daemon_skynet.sh >> /mnt/d/MyPoj/firegraph/logs/skynet_daemon.out 2>&1 &" 2>$null
Start-Sleep -Seconds 2

# 4. 启动监控（新窗口）
Write-Host "[4/4] starting monitor..." -ForegroundColor Cyan
$mon = Start-Process powershell -ArgumentList "-ExecutionPolicy", "Bypass", "-File", "$ROOT\scripts\monitor.ps1" -PassThru
$mon.Id | Out-File (Join-Path $LOG_DIR "monitor.pid") -Encoding ascii

Start-Sleep -Seconds 5

Write-Host ""
Write-Host "===== started =====" -ForegroundColor Green
$fgp = Get-Process -Name firegraph -ErrorAction SilentlyContinue
$skp = wsl -d Ubuntu-24.04 -- bash -c "pgrep -f 'skynet examples' | head -1" 2>$null
if ($fgp) { Write-Host "  firegraph: running PID=$($fgp.Id)" -ForegroundColor Green }
else { Write-Host "  firegraph: starting..." -ForegroundColor Yellow }
if ($skp) { Write-Host "  skynet:    running PID=$skp" -ForegroundColor Green }
else { Write-Host "  skynet:    starting..." -ForegroundColor Yellow }
Write-Host ""
Write-Host "dashboard:" -ForegroundColor White
Write-Host "  http://localhost:8080/           (home)"
Write-Host "  http://localhost:8080/traces.html (latency)"
Write-Host "  http://localhost:8080/profiles.html (flamegraph)"
Write-Host ""
Write-Host "logs:" -ForegroundColor White
Write-Host "  logs\firegraph.log      (app)"
Write-Host "  logs\daemon.log         (firegraph daemon)"
Write-Host "  logs\skynet.log         (skynet app)"
Write-Host "  logs\daemon_skynet.log  (skynet daemon)"
Write-Host "  logs\monitor.log        (monitor)"
Write-Host ""
Write-Host "stop: powershell -ExecutionPolicy Bypass -File scripts\stop_all.ps1" -ForegroundColor Yellow
