# measure-dsh-web.ps1 — 量測 `dsh web` 從啟動到開始監聽要多久
#
# 用法（在任一台上執行，不需要管理員）：
#   pwsh -File .\measure-dsh-web.ps1
#   pwsh -File .\measure-dsh-web.ps1 -Runs 3 -Port 3099
#
# 它做的事：用另外一個 port 起一個暫時的 dsh web（--no-open），
# 量到第一次印出 "dsh web: http://..." 的時間，然後把那個 process 殺掉。
# 不會動到原本在 3080 跑著的實例，也不會改任何設定檔（只會像平常啟動一樣重寫 profile 的 cordis.yml）。
param(
  [int]$Runs = 2,
  [int]$Port = 3099,
  [string]$Profile = 'web'
)
$ErrorActionPreference = 'Stop'

$bin = Join-Path (npm root -g) '@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path $bin)) { throw "找不到 dsh 的 bin.js：$bin" }
$node = (Get-Command node).Source
Write-Host "node   : $(& $node -v)"
Write-Host "dsh bin: $bin"
Write-Host "profile: $Profile"
Write-Host ''

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
  $p = $Port + $i - 1
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node
  $psi.Arguments = '"{0}" "{1}" --port {2} --no-open' -f $bin, $Profile, $p
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.WorkingDirectory = (Get-Location).Path
  $proc = [System.Diagnostics.Process]::Start($psi)

  $outTask = $proc.StandardOutput.ReadLineAsync()
  $errTask = $proc.StandardError.ReadLineAsync()
  $urlMs = -1
  $deadline = (Get-Date).AddSeconds(180)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    if ($outTask.IsCompleted) {
      $line = $outTask.Result
      if ($null -eq $line) { break }
      if ($urlMs -lt 0 -and $line -match '://127\.0\.0\.1:\d+') { $urlMs = $sw.ElapsedMilliseconds; break }
      $outTask = $proc.StandardOutput.ReadLineAsync()
    }
    if ($errTask.IsCompleted) {
      $line = $errTask.Result
      if ($null -ne $line) { $errTask = $proc.StandardError.ReadLineAsync() }
    }
    Start-Sleep -Milliseconds 25
  }

  try { $proc.Refresh() } catch {}
  $cpuMs = if ($proc.HasExited) { -1 } else { [int]$proc.TotalProcessorTime.TotalMilliseconds }
  if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }

  if ($urlMs -lt 0) { Write-Host ("run {0}: 逾時，沒有看到網址列" -f $i) }
  else {
    Write-Host ("run {0}: {1,7} ms  (CPU {2} ms, CPU/wall {3:P0})" -f $i, $urlMs, $cpuMs, ($cpuMs / [Math]::Max($urlMs, 1)))
    $results += $urlMs
  }
}

if ($results.Count -gt 0) {
  $sorted = $results | Sort-Object
  $median = if ($sorted.Count % 2 -eq 1) { $sorted[($sorted.Count - 1) / 2] } else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
  Write-Host ''
  Write-Host ("=== 中位數 {0} ms（{1:N1} 秒）  min {2} / max {3} ===" -f $median, ($median / 1000), $sorted[0], $sorted[-1])
}
