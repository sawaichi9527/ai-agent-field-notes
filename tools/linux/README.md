# tools/linux — status: empty

No Linux probes have been written yet. Nothing here is tested on Ubuntu; treat this directory as a
placeholder so the layout does not silently become Windows-only.

## What is needed before the first Linux case is written

| Windows probe | Linux equivalent | Notes |
|---|---|---|
| `measure-dsh-web.ps1` (time to first URL + CPU time) | shell script reading `/proc/<pid>/stat` fields 14+15 (utime+stime) before signal | must sample before the process is stopped; `/proc` disappears on exit |
| `watch-console-windows.ps1` (who created the window) | `bpftrace`/`execsnoop`, or `auditd` `-a always,exit -S execve` | no window object exists; attribute via parent PID of `execve` |
| `observe-consoles.ps1` (who is polling) | `perf trace -e syscalls:sys_enter_execve` over a fixed window | same idea, different observation surface |
| `Get-Process … MainWindowHandle` | not applicable | no console concept; "terminal" is the TTY of the session |

## Rules that carry over unchanged

- CPU time ÷ wall time classifies busy vs waiting on every OS.
- Validate the instrument before trusting a negative result (see
  [playbook 0002](../../playbooks/0002-sandbox-measurements-lie.md)).
- Cadence is a fingerprint; match it to source code (see
  [playbook 0004](../../playbooks/0004-separate-correlated-causes.md)).

## Rules that do not carry over

- `windowsHide`, `detached`, `CREATE_NO_WINDOW`, `conhost.exe` — Windows-only concepts.
- Anything about focus stealing: on Linux the analogue is a terminal window raised by the window
  manager, which is a different mechanism entirely.

If you add a probe here, include the exact command used to collect the evidence in the case
write-up — the value of this repo is reproducibility.
