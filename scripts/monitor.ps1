# firegraph real-time monitor: query API, log changes, alert on anomalies
param([int]$Interval = 10)

$ErrorActionPreference = "SilentlyContinue"
$ROOT = Split-Path -Parent $PSScriptRoot
$LOG_DIR = Join-Path $ROOT "logs"
$MONITOR_LOG = Join-Path $LOG_DIR "monitor.log"

New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

$API = "http://127.0.0.1:8080"

function Write-Mon {
    param([string]$msg, [string]$level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $MONITOR_LOG -Value "[$ts] [$level] $msg"
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$level] $msg"
    switch ($level) {
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Get-SkynetStatus {
    $r = wsl -d Ubuntu-24.04 -- bash -c "pgrep -f './skynet examples' | head -1" 2>$null
    if ($r -match '^\d+$') { return "running(PID=$r)" }
    return "stopped"
}

$prevTrace = 0
$prevProfile = 0

Write-Mon "===== monitor started (interval ${Interval}s) =====" "OK"
Write-Mon "API: $API"
Write-Mon "dashboard: $API/traces.html | $API/profiles.html"
Write-Host ""

while ($true) {
    $ts = Get-Date -Format "HH:mm:ss"

    # backend health
    $health = "DOWN"
    try {
        $h = Invoke-RestMethod -Uri "$API/healthz" -TimeoutSec 2 -ErrorAction Stop
        if ($h -eq "ok") { $health = "UP" }
    } catch { $health = "DOWN" }

    # skynet status
    $sk = Get-SkynetStatus

    # profiles
    $profileCount = 0
    $latestProfile = "-"
    if ($health -eq "UP") {
        try {
            $p = Invoke-RestMethod -Uri "$API/api/profiles" -TimeoutSec 3 -ErrorAction Stop
            $profileCount = ($p.items | Measure-Object).Count
            if ($profileCount -gt 0) {
                $latest = $p.items | Select-Object -Last 1
                $latestProfile = "id=$($latest.id) samples=$($latest.sample_count)"
            }
        } catch {}
    }

    # traces
    $traceGroups = 0
    $totalTrace = 0
    $statsLine = ""
    $slowCmds = @()
    if ($health -eq "UP") {
        try {
            $t = Invoke-RestMethod -Uri "$API/api/traces/stats" -TimeoutSec 3 -ErrorAction Stop
            $traceGroups = ($t.items | Measure-Object).Count
            foreach ($g in $t.items) {
                $totalTrace += $g.count
                $statsLine += "$($g.cmd)=$($g.count)/P95=$($g.p95_ms)ms "
                if ($g.p95_ms -ge 500) { $slowCmds += "$($g.cmd)(P95=$($g.p95_ms)ms)" }
            }
        } catch {}
    }

    # alerts
    if ($health -ne "UP") { Write-Mon "backend DOWN" "ERROR" }
    if ($sk -eq "stopped") { Write-Mon "skynet stopped" "ERROR" }
    if ($totalTrace -gt $prevTrace -and $prevTrace -gt 0) {
        $d = $totalTrace - $prevTrace
        Write-Mon "trace +$d ($prevTrace -> $totalTrace)" "OK"
    }
    if ($profileCount -gt $prevProfile -and $prevProfile -gt 0) {
        $d = $profileCount - $prevProfile
        Write-Mon "profile +$d latest: $latestProfile" "OK"
    }
    if ($slowCmds.Count -gt 0) {
        Write-Mon "slow cmd: $($slowCmds -join ', ')" "WARN"
    }

    # status line
    $line = "[$ts] backend=$health | skynet=$sk | profile=$profileCount | trace_groups=$traceGroups total=$totalTrace"
    if ($statsLine) { $line += " | $statsLine" }
    Write-Host $line -ForegroundColor White

    $prevTrace = $totalTrace
    $prevProfile = $profileCount

    Start-Sleep -Seconds $Interval
}
