# STATUS : proven
# PLATFORM: windows
# NEEDS  : PowerShell 7 (no external modules)
# ANSWERS: Which process creates the console window that keeps flashing?
# SIDE EFFECTS: none - read-only. Enumerates top-level windows, queries process
#               metadata, writes nothing outside %TEMP% and stdout.
# USED BY: playbooks/0003, cases/2026-10-30-dsh-console-flash-win/
#
# Why windows instead of processes
#   The process that owns a flashing console can live < 50 ms, while one Get-Process
#   call costs ~100 ms on an old CPU - so process polling always loses the race and
#   the parent PID resolves to nothing. A window that exists proves its owner exists,
#   and EnumWindows is fast. See playbooks/0003 for the three failures that led here.
#
# watch-console-windows.ps1 — 用「列舉視窗」抓閃爍的 console，不靠輪詢行程
#
#   .\watch-console-windows.ps1
#   .\watch-console-windows.ps1 -Seconds 60
#
# 為什麼改用視窗：
#   前幾版用 Get-Process 輪詢，但 console 的主人（cmd.exe）只活幾十毫秒，
#   而且舊 CPU 上 Get-Process 一次就要上百毫秒 → 幾乎必然漏掉。
#   視窗是「出現就會存在一小段時間」的物件，EnumWindows 又很快，能穩定抓到。
#
# 做法：每 30ms 列舉一次頂層視窗，找出 console 類別的新視窗，
#       用 GetWindowThreadProcessId 反查擁有它的 PID，再查那個 PID 的名字、命令列、父行程。
#       擁有視窗的行程一定還活著，所以這次一定查得到。

param(
  [int]$Seconds = 40,
  [int]$IntervalMs = 30
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinEnum
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    // 回傳 "hwnd|class|visible|pid|title"
    public static List<string> Snapshot()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            var t = new StringBuilder(512);
            GetWindowText(h, t, 512);
            list.Add(h.ToInt64() + "|" + sb.ToString() + "|" + (IsWindowVisible(h) ? "1" : "0") + "|" + pid + "|" + t.ToString());
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@ -ErrorAction Stop

$consoleClasses = @('ConsoleWindowClass', 'PseudoConsoleWindow', 'CASCADIA_HOSTING_WINDOW_CLASS')

function Get-ProcDetail([uint32]$procId) {
  $r = [pscustomobject]@{ Name = $null; Cmd = $null; ParentId = $null; ParentName = $null }
  try {
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction Stop
    $r.Name = [string]$ci.Name
    $r.Cmd  = $ci.CommandLine
    $r.ParentId = [int]$ci.ParentProcessId
    $pi = Get-CimInstance Win32_Process -Filter "ProcessId = $($r.ParentId)" -ErrorAction SilentlyContinue
    if ($pi) { $r.ParentName = [string]$pi.Name }
  } catch {}
  return $r
}

Write-Host '=== 暖機 EnumWindows ===' -ForegroundColor Cyan
$null = [WinEnum]::Snapshot()

$known = @{}
foreach ($line in [WinEnum]::Snapshot()) {
  $hwnd = ($line -split '\|')[0]
  $known[$hwnd] = $true
}

Write-Host ("=== 基準：已存在 {0} 個視窗 ===" -f $known.Count)
Write-Host ''
Write-Host ("=== 監看 {0} 秒（每 {1} ms）===" -f $Seconds, $IntervalMs) -ForegroundColor Yellow
Write-Host ''

$events = [System.Collections.Generic.List[object]]::new()
$end = (Get-Date).AddSeconds($Seconds)

while ((Get-Date) -lt $end) {
  foreach ($line in [WinEnum]::Snapshot()) {
    $parts = $line -split '\|', 5
    $hwnd = $parts[0]
    if ($known.ContainsKey($hwnd)) { continue }
    $known[$hwnd] = $true

    $cls = $parts[1]; $vis = $parts[2]; $ownerPid = [uint32]$parts[3]; $title = $parts[4]
    $isConsole = $consoleClasses -contains $cls
    if (-not $isConsole -and $vis -ne '1') { continue }   # 非 console 且不可見 -> 略過

    $d = Get-ProcDetail $ownerPid
    $ev = [pscustomobject]@{
      Time      = (Get-Date).ToString('HH:mm:ss.fff')
      Hwnd      = $hwnd
      Class     = $cls
      Visible   = ($vis -eq '1')
      OwnerPid  = $ownerPid
      Owner     = $d.Name
      ParentId  = $d.ParentId
      Parent    = $d.ParentName
      Title     = $title
      Cmd       = $d.Cmd
    }
    $events.Add($ev)

    $tag = if ($isConsole) { 'CONSOLE' } else { 'WINDOW ' }
    $col = if ($ev.Visible) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  [{0}] {1} visible={2,-5} pid={3,-6} owner={4}" -f $ev.Time, $tag, $ev.Visible, $ev.OwnerPid, $ev.Owner) -ForegroundColor $col
    if ($ev.Cmd) {
      $s = $ev.Cmd.Substring(0, [Math]::Min(120, $ev.Cmd.Length))
      Write-Host ("         {0}" -f $s) -ForegroundColor DarkGray
    }
  }
  Start-Sleep -Milliseconds $IntervalMs
}

Write-Host ''
Write-Host '==================== 結果 ====================' -ForegroundColor Cyan
if ($events.Count -eq 0) {
  Write-Host '  沒有任何新的 console／可見視窗。' -ForegroundColor Yellow
  Write-Host '  → 那你看到的閃爍不是「新視窗」，可能是舊視窗重繪或別的效果。' -ForegroundColor Yellow
  return
}

$events | Select-Object Time, Class, Visible, OwnerPid, Owner, Parent, Title | Format-Table -AutoSize

Write-Host '=== 依擁有者分組 ===' -ForegroundColor Green
$events | Group-Object Owner | Sort-Object Count -Descending | ForEach-Object {
  Write-Host ("  {0,-26} {1} 次" -f $(if ($_.Name) { $_.Name } else { '(空)' }), $_.Count) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 命令列（指名道姓）===' -ForegroundColor Green
foreach ($grp in ($events | Group-Object Owner)) {
  $g = $grp.Group[0]
  Write-Host ("  [{0}] pid={1} parent={2}({3})" -f $g.Owner, $g.OwnerPid, $g.Parent, $g.ParentId)
  $shown = if ($g.Cmd) { $g.Cmd } else { '(取不到)' }
  Write-Host ("       {0}" -f $shown) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== 節奏（秒）===' -ForegroundColor Green
$times = @($events | ForEach-Object { [datetime]::ParseExact($_.Time, 'HH:mm:ss.fff', $null) })
if ($times.Count -ge 2) {
  $gaps = @()
  for ($i = 1; $i -lt $times.Count; $i++) { $gaps += [math]::Round(($times[$i] - $times[$i-1]).TotalSeconds, 2) }
  Write-Host ("  {0}" -f ($gaps -join ', ')) -ForegroundColor Yellow
}

$outFile = Join-Path $env:TEMP ("dsh-windows-" + (Get-Date).ToString('HHmmss') + ".json")
$events | ConvertTo-Json -Depth 3 | Set-Content -Path $outFile -Encoding utf8
Write-Host ''
Write-Host ("已存檔：{0}" -f $outFile) -ForegroundColor DarkGray
