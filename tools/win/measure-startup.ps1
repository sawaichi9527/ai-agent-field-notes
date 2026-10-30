# STATUS : proven
# PLATFORM: windows
# NEEDS  : PowerShell 7, node on PATH
# ANSWERS: How long until the CLI is ready, and is it computing or waiting?
# SIDE EFFECTS: starts one extra instance on a spare port and kills it when the
#               ready marker appears. Does not touch an already running instance.
#               If the target rewrites its own profile config on boot (dsh does),
#               that file is rewritten once - same as a normal start.
# USED BY: playbooks/0001, cases/2026-10-30-dsh-slow-startup-win/
#
# Usage (example target: dsh web)
#   .\measure-startup.ps1 -Bin "$(npm root -g)\@deepseek-ai\dsh\lib\bin.js" `
#                         -AppArgs 'web' -Port 3099 -Runs 3
#
#   # target with no port concept
#   .\measure-startup.ps1 -Bin .\dist\cli.js -AppArgs 'status' -Port 0
#
# Interpretation
#   >= 90% : computing        (module loading / compile / parsing)
#   50-90% : mixed            (profile the CPU, then look for waits)
#   <  50% : waiting          (I/O, network, filter driver)
#   > 100% : normal for a JS runtime - background threads add CPU time
#
# The ratio is only meaningful OUTSIDE a sandbox - see playbooks/0002.

param(
  [Parameter(Mandatory = $true)][string]$Bin,
  [string[]]$AppArgs = @(),
  [string[]]$ExtraArgs = @(),
  [int]$Port = 3099,
  [string]$PortFlag = '--port',
  [int]$Runs = 3,
  [string]$ReadyPattern = '://127\.0\.0\.1:\d+',
  [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Bin)) { throw "entry script not found: $Bin" }
$node = (Get-Command node).Source

# A sandbox shows up as: piped stdio denied, or the child dying instantly with EPERM.
$sandboxHint = $false
if ($env:DSH_TOOL_SANDBOX -or $env:SANDBOX_MODE) { $sandboxHint = $true }

Write-Host ("node      : {0}" -f (& $node -v))
Write-Host ("entry     : {0}" -f $Bin)
Write-Host ("app args  : {0}" -f ($AppArgs -join ' '))
Write-Host ("runs      : {0}  port base: {1}" -f $Runs, $Port)
if ($sandboxHint) {
  Write-Host 'WARNING   : this looks like a sandboxed shell; CPU/wall will be biased low.' -ForegroundColor Yellow
}
Write-Host ''

$results = @()

for ($i = 1; $i -le $Runs; $i++) {
  $p = if ($Port -gt 0) { $Port + $i - 1 } else { 0 }

  $argList = @($Bin) + $AppArgs + $ExtraArgs
  if ($Port -gt 0) { $argList += @($PortFlag, "$p") }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node
  $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.WorkingDirectory = (Get-Location).Path

  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadLineAsync()
  $errTask = $proc.StandardError.ReadLineAsync()

  $readyMs = -1
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $firstError = $null

  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    if ($outTask.IsCompleted) {
      $line = $outTask.Result
      if ($null -eq $line) { break }
      if ($readyMs -lt 0 -and $line -match $ReadyPattern) { $readyMs = $sw.ElapsedMilliseconds; break }
      $outTask = $proc.StandardOutput.ReadLineAsync()
    }
    if ($errTask.IsCompleted) {
      $line = $errTask.Result
      if ($null -ne $line) {
        if (-not $firstError) { $firstError = $line }
        $errTask = $proc.StandardError.ReadLineAsync()
      }
    }
    Start-Sleep -Milliseconds 25
  }

  try { $proc.Refresh() } catch {}
  $cpuMs = if ($proc.HasExited) { -1 } else { [int]$proc.TotalProcessorTime.TotalMilliseconds }
  if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }

  if ($readyMs -lt 0) {
    Write-Host ("run {0}: never became ready ({1}s timeout)" -f $i, $TimeoutSec) -ForegroundColor Red
    if ($proc.HasExited) { Write-Host ("        child exited with code {0}" -f $proc.ExitCode) }
    if ($firstError) { Write-Host ("        first stderr: {0}" -f $firstError) }
    continue
  }

  $ratio = if ($cpuMs -gt 0) { $cpuMs / [Math]::Max($readyMs, 1) } else { 0 }
  Write-Host ("run {0}: {1,7} ms  (CPU {2,7} ms, CPU/wall {3,6:P0})" -f $i, $readyMs, $cpuMs, $ratio)
  $results += [pscustomobject]@{ Ms = $readyMs; CpuMs = $cpuMs; Ratio = $ratio }
}

if ($results.Count -eq 0) { throw 'no successful run - nothing to report' }

$med = ($results | Sort-Object Ms)[[int][Math]::Floor($results.Count / 2)]
$medCpu = ($results | Sort-Object CpuMs)[[int][Math]::Floor($results.Count / 2)]
$medRatio = $medCpu.CpuMs / [Math]::Max($med.Ms, 1)

$band = if ($medRatio -ge 0.9) { 'COMPUTING (CPU-bound)' }
        elseif ($medRatio -ge 0.5) { 'MIXED (real waiting present)' }
        else { 'WAITING (I/O, network, filter driver)' }

Write-Host ''
Write-Host ('=== median {0} ms ({1:N1} s)  CPU {2} ms  CPU/wall {3:P0}  -> {4} ===' -f `
  $med.Ms, ($med.Ms / 1000), $medCpu.CpuMs, $medRatio, $band) -ForegroundColor Green
Write-Host ''
Write-Host 'Next step for each band:' -ForegroundColor Cyan
Write-Host '  COMPUTING -> count plugins/bundles, compare a minimal config; CPU generation matters'
Write-Host '  MIXED     -> profile CPU (--cpu-prof), then look for waits'
Write-Host '  WAITING   -> disk / AV filter / unreachable endpoints; measure a filesystem baseline'
