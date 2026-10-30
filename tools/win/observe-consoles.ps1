# observe-consoles.ps1 — 只回答一件事：現在這段時間，是誰在建立 console 視窗？
#
#   .\observe-consoles.ps1
#   .\observe-consoles.ps1 -Seconds 60
#
# 做法：監看「新出現的 conhost.exe」。conhost 的父行程＝擁有那個 console 的程式
#       （通常是 cmd.exe），再往上一層＝真正發起的人。這樣就能指名道姓。
#
# 不需要碰 dsh。這段時間請正常使用電腦即可。

param(
  [int]$Seconds = 40,
  [int]$IntervalMs = 120
)

Write-Host '==================== 目前相關行程 ====================' -ForegroundColor Cyan
foreach ($n in @('NVIDIA Sync', 'NvBackend', 'nvcontainer', 'NVDisplay.Container')) {
  $ps = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
  if ($ps.Count -gt 0) {
    foreach ($p in $ps) {
      Write-Host ("  執行中: {0,-22} pid={1}" -f $p.ProcessName, $p.Id) -ForegroundColor Green
    }
  } else {
    Write-Host ("  未執行: {0}" -f $n) -ForegroundColor DarkGray
  }
}

Write-Host ''
Write-Host ("==================== 監看 {0} 秒：誰在建立 console ====================" -f $Seconds) -ForegroundColor Yellow
Write-Host '  （請照平常使用，這段與 dsh 無關）'

$watch = 'conhost'
$seen = @{}
foreach ($p in @(Get-Process -Name $watch -ErrorAction SilentlyContinue)) { $seen[$p.Id] = $true }
$baseline = $seen.Count
Write-Host ("  基準 conhost 數: {0}" -f $baseline)
Write-Host ''

$hits = @()
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  foreach ($c in @(Get-Process -Name $watch -ErrorAction SilentlyContinue)) {
    if ($seen.ContainsKey($c.Id)) { continue }
    $seen[$c.Id] = $true

    $ownerPid = $null; $ownerName = $null; $ownerCmd = $null
    $rootPid = $null;  $rootName = $null;  $rootCmd = $null
    try {
      $ci = Get-CimInstance Win32_Process -Filter "ProcessId = $($c.Id)" -ErrorAction Stop
      $ownerPid = [int]$ci.ParentProcessId
      $oi = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
      if ($oi) {
        $ownerName = $oi.Name; $ownerCmd = $oi.CommandLine
        $rootPid = [int]$oi.ParentProcessId
        $ri = Get-CimInstance Win32_Process -Filter "ProcessId = $rootPid" -ErrorAction SilentlyContinue
        if ($ri) { $rootName = $ri.Name; $rootCmd = $ri.CommandLine }
      }
    } catch {}

    $hits += [pscustomobject]@{
      Time      = (Get-Date).ToString('HH:mm:ss.fff')
      Conhost   = $c.Id
      OwnerPid  = $ownerPid
      OwnerName = $ownerName
      RootPid   = $rootPid
      RootName  = $rootName
      OwnerCmd  = $ownerCmd
      RootCmd   = $rootCmd
    }
    Write-Host ("  [{0}] conhost {1} <- {2}({3}) <- {4}({5})" -f (Get-Date).ToString('HH:mm:ss.fff'), $c.Id, $ownerName, $ownerPid, $rootName, $rootPid) -ForegroundColor Green
  }
  Start-Sleep -Milliseconds $IntervalMs
}

Write-Host ''
Write-Host '==================== 結果 ====================' -ForegroundColor Cyan
if ($hits.Count -eq 0) {
  Write-Host '  這段時間內沒有新的 conhost。' -ForegroundColor Yellow
  Write-Host '  → 若你眼睛還是看到閃爍，那閃的可能不是 console 視窗（例如瀏覽器自己的啟動視窗）。' -ForegroundColor Yellow
  return
}

Write-Host ("  共 {0} 個新 console" -f $hits.Count) -ForegroundColor Yellow
$hits | Select-Object Time, Conhost, OwnerName, OwnerPid, RootName, RootPid | Format-Table -AutoSize

Write-Host '=== 依「發起者」分組 ===' -ForegroundColor Green
$hits | Group-Object RootName | Sort-Object Count -Descending | ForEach-Object {
  Write-Host ("  {0,-28} {1} 次" -f $_.Name, $_.Count) -ForegroundColor Yellow
}
Write-Host ''
Write-Host '=== 每個發起者的真實身分與命令列 ===' -ForegroundColor Green
$hits | Group-Object RootName | ForEach-Object {
  $g = $_.Group[0]
  Write-Host ("  [{0}] pid={1}" -f $g.RootName, $g.RootPid)
  Write-Host ("       {0}" -f $(if ($g.RootCmd) { $g.RootCmd } else { '(取不到命令列)' })) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== 節奏（秒）===' -ForegroundColor Green
$times = $hits | ForEach-Object { [datetime]::ParseExact($_.Time, 'HH:mm:ss.fff', $null) } | Sort-Object
if ($times.Count -ge 2) {
  $gaps = @()
  for ($i = 1; $i -lt $times.Count; $i++) { $gaps += [math]::Round(($times[$i] - $times[$i-1]).TotalSeconds, 2) }
  Write-Host ("  {0}" -f ($gaps -join ', ')) -ForegroundColor Yellow
}

$outFile = Join-Path $env:TEMP ("dsh-consoles-" + (Get-Date).ToString('HHmmss') + ".json")
$hits | Select-Object Time, Conhost, OwnerPid, OwnerName, OwnerCmd, RootPid, RootName, RootCmd |
  ConvertTo-Json -Depth 3 | Set-Content -Path $outFile -Encoding utf8
Write-Host ''
Write-Host ("已存檔：{0}" -f $outFile) -ForegroundColor DarkGray
