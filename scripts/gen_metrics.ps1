# 持续向 firegraph 发送测试 trace，让 Prometheus/Grafana 仪表盘有实时曲线
# 用法：后台运行，停止用 stop_all.ps1 或 kill PID（logs\gen_metrics.pid）
$ErrorActionPreference = "SilentlyContinue"
$API = "http://127.0.0.1:8080/api/traces/batch"
$cmds = @("Login", "Attack", "Query", "Logout", "Chat")
$svcs = @("gamesrv", "battlesrv", "dbsrv", "chatsrv")
$log = "d:\MyPoj\firegraph\logs\gen_metrics.log"
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] gen_metrics started (interval 3s)" | Out-File $log -Append -Encoding ascii
$count = 0
while ($true) {
  try {
    $lines = @()
    for ($i = 0; $i -lt 8; $i++) {
      $cmd = $cmds | Get-Random
      $svc = $svcs | Get-Random
      # 模拟延迟分布：大部分快，少量慢
      $r = Get-Random -Minimum 1 -Maximum 100
      if ($r -lt 70) { $cost = Get-Random -Minimum 10 -Maximum 120 }
      elseif ($r -lt 90) { $cost = Get-Random -Minimum 120 -Maximum 400 }
      else { $cost = Get-Random -Minimum 400 -Maximum 1500 }
      $ok = (Get-Random -Minimum 0 -Maximum 100) -gt 8  # ~92% 成功
      $ts = [DateTimeOffset]::Now.ToUnixTimeSeconds()
      $lines += "{`"cmd`":`"$cmd`",`"service`":`"$svc`",`"cost_ms`":$cost,`"ok`":$ok,`"ts`":$ts}"
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $r = Invoke-WebRequest -Uri $API -Method POST -Body $body -ContentType "text/plain" -UseBasicParsing -TimeoutSec 5
    $count++
    if ($count % 20 -eq 0) {
      "[$(Get-Date -Format 'HH:mm:ss')] sent batches=$count last=$($r.Content)" | Out-File $log -Append -Encoding ascii
    }
  } catch {
    "[$(Get-Date -Format 'HH:mm:ss')] ERROR: $_" | Out-File $log -Append -Encoding ascii
  }
  Start-Sleep -Seconds 3
}
