# skynet daemon (PowerShell): launch skynet via WSL, monitor, auto-restart on exit
$ErrorActionPreference = "SilentlyContinue"
$ROOT = Split-Path -Parent $PSScriptRoot
$SKYNET_DIR = "D:\MyPoj\myskynet"
$LOG_DIR = Join-Path $ROOT "logs"
$APP_LOG = Join-Path $LOG_DIR "skynet.log"
$DAEMON_LOG = Join-Path $LOG_DIR "daemon_skynet.log"
$PID_FILE = Join-Path $LOG_DIR "skynet.pid"

New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

function Write-SDLog {
    param([string]$msg)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $DAEMON_LOG -Value $line
    Write-Host $line
}

Write-SDLog "===== skynet daemon started ====="
Write-SDLog "skynet dir: $SKYNET_DIR"
Write-SDLog "config: examples/config.firegraph"

$restartCount = 0

while ($restartCount -lt 999) {
    $restartCount++
    $startTime = Get-Date
    Write-SDLog "[$restartCount] starting skynet..."

    # 通过 WSL 启动 skynet（前台运行，日志重定向到文件）
    # 用 Start-Process wsl 让它在独立进程运行
    $proc = Start-Process wsl -ArgumentList "-d", "Ubuntu-24.04", "--", "bash", "-c", "cd /mnt/d/MyPoj/myskynet && ./skynet examples/config.firegraph >> /mnt/d/MyPoj/firegraph/logs/skynet.log 2>&1" -WindowStyle Hidden -PassThru

    $proc.Id | Out-File -FilePath $PID_FILE -Encoding ascii
    Write-SDLog "[$restartCount] skynet started (wsl wrapper PID=$($proc.Id))"

    # 等待进程退出
    while ($true) {
        Start-Sleep -Seconds 5
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $p) {
            Write-SDLog "[$restartCount] skynet exited"
            break
        }
    }

    $uptime = (Get-Date) - $startTime
    $upStr = "{0}h {1}m {2}s" -f $uptime.Hours, $uptime.Minutes, $uptime.Seconds
    Write-SDLog "[$restartCount] uptime: $upStr"
    Write-SDLog "[$restartCount] restart in 3s..."
    Start-Sleep -Seconds 3
}

Write-SDLog "===== daemon exit ====="
