# firegraph daemon: auto-restart on exit, logs to file
$ErrorActionPreference = "SilentlyContinue"
$ROOT = Split-Path -Parent $PSScriptRoot
$BIN = Join-Path $ROOT "bin\firegraph.exe"
$CONFIG = Join-Path $ROOT "configs\firegraph.yaml"
$LOG_DIR = Join-Path $ROOT "logs"
$APP_LOG = Join-Path $LOG_DIR "firegraph.log"
$APP_ERR = Join-Path $LOG_DIR "firegraph.err"
$DAEMON_LOG = Join-Path $LOG_DIR "daemon.log"
$PID_FILE = Join-Path $LOG_DIR "firegraph.pid"

New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

function Write-DLog {
    param([string]$msg)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $DAEMON_LOG -Value $line
    Write-Host $line
}

Write-DLog "===== firegraph daemon started ====="
Write-DLog "bin: $BIN"
Write-DLog "config: $CONFIG"

Get-Process -Name firegraph -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$restartCount = 0

while ($restartCount -lt 999) {
    $restartCount++
    $startTime = Get-Date
    Write-DLog "[$restartCount] starting firegraph..."

    $proc = Start-Process -FilePath $BIN -ArgumentList "-config", $CONFIG -WorkingDirectory $ROOT -WindowStyle Hidden -PassThru -RedirectStandardOutput $APP_LOG -RedirectStandardError $APP_ERR

    $proc.Id | Out-File -FilePath $PID_FILE -Encoding ascii
    Write-DLog "[$restartCount] firegraph started PID=$($proc.Id)"

    while ($true) {
        Start-Sleep -Seconds 5
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $p) {
            Write-DLog "[$restartCount] firegraph exited ExitCode=$($proc.ExitCode)"
            break
        }
        $r = $null
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:8080/healthz" -TimeoutSec 2 -ErrorAction SilentlyContinue
    }

    $uptime = (Get-Date) - $startTime
    $upStr = "{0}h {1}m {2}s" -f $uptime.Hours, $uptime.Minutes, $uptime.Seconds
    Write-DLog "[$restartCount] uptime: $upStr"
    Write-DLog "[$restartCount] restart in 3s..."
    Start-Sleep -Seconds 3
}

Write-DLog "===== daemon exit ====="
