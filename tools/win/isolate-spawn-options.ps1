# STATUS : template (single-variable isolation; adapt the combos to your question)
# PLATFORM: windows
# NEEDS  : PowerShell 7, node, Windows PowerShell 5.1
# ANSWERS: Which ONE spawn option changes the behaviour? (windowsHide / detached / cwd / stdio)
# SIDE EFFECTS: spawns short-lived processes only; writes temp files under %TEMP%.
# USED BY: playbooks/0005, cases/2026-10-30-dsh-console-flash-win/
#
# Why this exists
#   Guessing which spawn flag matters is unreliable, and this repo has a scar to prove it:
#   `detached: true` was suspected of creating a console, but in the library under
#   investigation it only existed on the Linux branch. One variable at a time settles it.
#
# Method
#   A: cmd.exe, no detached        (control - proves the harness works)
#   B: cmd.exe, detached           (separates "detached in general" from "PowerShell")
#   C: PowerShell, detached        (the combination under suspicion)
#   D: PowerShell, no detached     (the control that must succeed)
#   E: PowerShell, detached, -File (rules out -Command parsing as a confounder)
#
# Each combo records: pid, spawnError, exit code, whether the side effect happened,
# and the child's own stdout/stderr (captured to files, never through a pipe).

param(
  [int]$SettleMs = 2600,
  [int]$LateCheckMs = 4000
)

$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TEMP ("isolate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$probe = Join-Path $work 'probe-file.ps1'
@'
"probe ran in -File mode" | Set-Content -LiteralPath $env:FLAG_OUT -Encoding ascii
'@ | Set-Content $probe -Encoding utf8

$diag = Join-Path $work 'isolate.mjs'
@'
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const PS = process.env.DIAG_PS;
const CMD = process.env.DIAG_CMD;
const WORK = process.env.DIAG_WORK;
const PROBE = process.env.DIAG_PROBE;
const SETTLE = Number(process.env.DIAG_SETTLE || 2600);
const LATE = Number(process.env.DIAG_LATE || 4000);

const read = (p, n = 400) => { try { const s = fs.readFileSync(p, 'utf8'); return s.length > n ? s.slice(0, n) + '…' : s; } catch { return null; } };

async function run(name, exe, args, opts, flag) {
  try { fs.unlinkSync(flag); } catch {}
  const outP = path.join(WORK, `out-${name}.txt`);
  const errP = path.join(WORK, `err-${name}.txt`);
  const outFd = fs.openSync(outP, 'w');
  const errFd = fs.openSync(errP, 'w');
  const rec = { combo: name, exitCode: null, sideEffect: false, sideEffectLate: false, spawnError: null };

  let child;
  try {
    child = spawn(exe, args, { ...opts, stdio: ['ignore', outFd, errFd] });
    rec.pid = child.pid ?? null;
  } catch (e) {
    rec.spawnError = String(e && e.message || e);
    fs.closeSync(outFd); fs.closeSync(errFd);
    return rec;
  }
  const errs = [];
  child.on('error', (e) => errs.push(String(e && e.message || e)));
  child.on('exit', (code) => { rec.exitCode = code; });

  await new Promise((r) => setTimeout(r, SETTLE));
  rec.sideEffect = fs.existsSync(flag);
  if (!rec.sideEffect) {
    await new Promise((r) => setTimeout(r, LATE));
    rec.sideEffectLate = fs.existsSync(flag);
  }
  rec.spawnError = errs.length ? errs.join(' | ') : null;
  try { fs.closeSync(outFd); } catch {}
  try { fs.closeSync(errFd); } catch {}
  rec.stdout = read(outP);
  rec.stderr = read(errP);
  return rec;
}

const rows = [];
const flagOf = (n) => path.join(WORK, `flag-${n}.txt`);

rows.push(await run('A-cmd-plain', CMD, ['/c', 'copy', 'NUL', flagOf('A')], {}, flagOf('A')));
rows.push(await run('B-cmd-detached', CMD, ['/c', 'copy', 'NUL', flagOf('B')], { detached: true }, flagOf('B')));

const psCmd = (flag) => ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
  "Set-Content -LiteralPath '" + flag.replace(/'/g, "''") + "' -Value 'ok'"];

rows.push(await run('C-ps-detached', PS, psCmd(flagOf('C')), { detached: true }, flagOf('C')));
rows.push(await run('D-ps-plain', PS, psCmd(flagOf('D')), {}, flagOf('D')));
rows.push(await run('E-ps-detached-file', PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', PROBE],
  { detached: true, env: { ...process.env, FLAG_OUT: flagOf('E') } }, flagOf('E')));

console.log(JSON.stringify(rows, null, 2));
'@ | Set-Content $diag -Encoding utf8

$env:DIAG_PS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:DIAG_CMD = $env:ComSpec
$env:DIAG_WORK = $work
$env:DIAG_PROBE = $probe
$env:DIAG_SETTLE = "$SettleMs"
$env:DIAG_LATE = "$LateCheckMs"

Write-Host 'Running 5 isolated combinations; nothing is installed or modified.' -ForegroundColor Cyan

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command node).Source
$psi.Arguments = '"{0}"' -f $diag
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($psi)
$stdout = $p.StandardOutput.ReadToEnd()
$stderr = $p.StandardError.ReadToEnd()
$p.WaitForExit(120000) | Out-Null

Write-Host ''
Write-Host $stdout
if ($stderr.Trim()) { Write-Host '--- driver stderr ---' -ForegroundColor DarkYellow; Write-Host $stderr }

Write-Host 'How to read it:' -ForegroundColor Green
Write-Host '  A false                -> the harness itself is broken; stop'
Write-Host '  B true, C false        -> the behaviour is specific to the exe, not detached in general'
Write-Host '  C false, D true        -> detached is what changes the outcome'
Write-Host '  exit 0 + no side effect -> the child "succeeded" without doing anything (silent failure)'
Write-Host ''
Write-Host ("scratch dir (safe to delete): {0}" -f $work) -ForegroundColor DarkGray
