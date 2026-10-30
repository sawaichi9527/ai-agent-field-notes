# STATUS : template (models the DSH browser-handoff chain; adapt the hops to your case)
# PLATFORM: windows
# NEEDS  : PowerShell 7, node, Windows PowerShell 5.1 (for the probe)
# ANSWERS: Does a two-hop spawn chain create a VISIBLE console window?
# SIDE EFFECTS: spawns processes only; writes temp files under %TEMP%.
#               Does NOT touch any installed product.
# USED BY: playbooks/0005, cases/2026-10-30-dsh-console-flash-win/
#
# Why the four combinations
#   The naive theory is "no windowsHide => console flashes". Testing it means varying
#   windowsHide at EACH hop independently, because fixing one hop can simply move the
#   console creation to the other hop.
#
# Why the CONTROL GROUP matters more than the experiment
#   If every combination reports "no console", you cannot tell "the bug is absent"
#   from "this environment cannot create consoles at all". The control group (parent
#   DOES have a console) must report has=True / visible=True / attached>=2, otherwise
#   the whole run is meaningless. A sandboxed shell fails exactly this way.
#
# MUST run in a normal terminal, never inside an agent sandbox.

param(
  [int]$PauseSeconds = 2
)

$ErrorActionPreference = 'Stop'
$node = (Get-Command node).Source
$work = Join-Path $env:TEMP ("probe-console-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---- probe: reports its own console state ----
$probePath = Join-Path $work 'console-probe.ps1'
@'
Add-Type -Name K -Namespace N -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetConsoleProcessList(uint[] list, uint count);
"@
Add-Type -Name U -Namespace N -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);'
$h = [N.K]::GetConsoleWindow()
$has = $h -ne [IntPtr]::Zero
$vis = $false
$attached = 0
if ($has) {
  $vis = [N.U]::IsWindowVisible($h)
  $buf = New-Object uint32[] 32
  $attached = [N.K]::GetConsoleProcessList($buf, 32)
}
"{0}|{1}|{2}|{3}" -f $env:PROBE_LABEL, $has, $vis, $attached | Out-File -Append -Encoding ascii $env:PROBE_OUT
'@ | Set-Content $probePath -Encoding utf8

# ---- hop 1: the intermediate launcher (mirrors a browser-launcher spawn) ----
$driverPath = Join-Path $work 'chain.mjs'
@'
import { spawn } from 'node:child_process';
const [, , hop2, mode, out] = process.argv;
const hide1 = mode === 'chain-hide1' || mode === 'chain-hide12';
spawn(process.execPath, [hop2], {
  stdio: ['ignore', 'inherit', 'inherit'],
  env: { ...process.env, ROLE: 'p1', CHAIN_HIDE2: (mode === 'chain-hide2' || mode === 'chain-hide12') ? '1' : '0', CHAIN_OUT: out },
  ...(hide1 ? { windowsHide: true } : {}),
});
await new Promise((r) => setTimeout(r, 2600));
'@ | Set-Content $driverPath -Encoding utf8

# ---- hop 2: the final launcher (mirrors `open` spawning powershell) ----
$hop2 = Join-Path $work 'hop2.mjs'
@'
import { spawn } from 'node:child_process';
const hide2 = process.env.CHAIN_HIDE2 === '1';
spawn(process.env.PROBE_PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', process.env.PROBE_SCRIPT], {
  stdio: 'ignore',
  env: { ...process.env, PROBE_OUT: process.env.CHAIN_OUT, PROBE_LABEL: 'P2' },
  ...(hide2 ? { windowsHide: true } : {}),
});
await new Promise((r) => setTimeout(r, 1500));
'@ | Set-Content $hop2 -Encoding utf8

$env:PROBE_PS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:PROBE_SCRIPT = $probePath

function Invoke-Chain([string]$mode) {
  $out = Join-Path $work "result-$mode.txt"
  if (Test-Path $out) { Remove-Item $out -Force }
  $env:CHAIN_OUT = $out
  Write-Host ''
  Write-Host ("--- {0} ---" -f $mode) -ForegroundColor Cyan
  Write-Host '    watch the desktop for the next 2 seconds' -ForegroundColor DarkGray
  Start-Sleep -Seconds $PauseSeconds

  # console-less parent: same situation as a helper-restarted agent
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node
  $psi.Arguments = '"{0}" "{1}" {2} "{3}"' -f $driverPath, $hop2, $mode, $out
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit(20000) | Out-Null
  Start-Sleep -Milliseconds 300

  if (Test-Path $out) {
    $parts = (Get-Content $out -Raw).Trim().Split('|')
    $has = $parts[1]; $vis = $parts[2]; $att = $parts[3]
    Write-Host ("    console has={0} visible={1} attached={2}" -f $has, $vis, $att) -ForegroundColor Yellow
    return [pscustomobject]@{ Mode = $mode; Has = $has; Visible = $vis; Attached = $att }
  }
  Write-Host '    no report - spawn blocked or probe did not run' -ForegroundColor Red
  return [pscustomobject]@{ Mode = $mode; Has = '?'; Visible = '?'; Attached = '?' }
}

Write-Host '=====================================================' -ForegroundColor Yellow
Write-Host ' CONTROL: parent HAS a console (must report visible=True)' -ForegroundColor Yellow
Write-Host '=====================================================' -ForegroundColor Yellow
$env:PROBE_OUT = Join-Path $work 'result-control.txt'
if (Test-Path $env:PROBE_OUT) { Remove-Item $env:PROBE_OUT -Force }
$env:PROBE_LABEL = 'control'
& $env:PROBE_PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath
Start-Sleep -Milliseconds 200
$ctrl = (Get-Content $env:PROBE_OUT -Raw).Trim().Split('|')
Write-Host ("    console has={0} visible={1} attached={2}" -f $ctrl[1], $ctrl[2], $ctrl[3]) -ForegroundColor Yellow
if ($ctrl[2] -ne 'True') {
  Write-Host ''
  Write-Host 'ABORT: the control group could not see a console either.' -ForegroundColor Red
  Write-Host '       This environment cannot create consoles (sandbox?). Numbers below would be meaningless.' -ForegroundColor Red
  return
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Yellow
Write-Host ' EXPERIMENT: parent has NO console' -ForegroundColor Yellow
Write-Host '=====================================================' -ForegroundColor Yellow
$results = @()
foreach ($m in 'chain-none', 'chain-hide1', 'chain-hide2', 'chain-hide12') { $results += Invoke-Chain $m }

Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Green
$results | Format-Table -AutoSize
Write-Host 'chain-none visible=True  -> this chain DOES flash; fix the hop that creates it'
Write-Host 'chain-none visible=False -> this chain never creates a console; the flash is elsewhere'
Write-Host 'Also record what your eyes saw; the visible/attached columns can disagree with perception.'
Write-Host ''
Write-Host ("scratch dir (safe to delete): {0}" -f $work) -ForegroundColor DarkGray
