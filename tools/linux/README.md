# tools/linux — status: 1 probe

The agent-CLI probes below are still unwritten; the first Linux probe that does exist answers a
different question (desktop entry identity), because that is where the first Linux case came from.

## Written

| Probe | Question | Needs |
|---|---|---|
| [`probe-desktop-match.sh`](probe-desktop-match.sh) | does a window's `app_id` resolve to a **usable** `.desktop` entry — by which rule, with every matched entry's `Icon` resolving, and with no invalid entry hiding from GLib? | python3 + PyGObject + Gtk 3 typelib |

Exit code is `0` when identity resolves, every matching entry's `Icon` resolves at at least one
standard size, and no explicit/exec-referencing entry is invalid; `1` when the window would fall back
to the generic icon or could bind to an entry with a missing icon. It also reports hidden duplicates
(`NoDisplay=true` may still match windows) and structurally invalid entries that
`Gio.AppInfo.get_all()` silently drops. Used by [playbook 0006](../../playbooks/0006-window-identity-not-icon.md),
[`cases/2026-11-02-appimage-dock-gear-linux/`](../../cases/2026-11-02-appimage-dock-gear-linux/) and
[`cases/2026-11-02-appimage-desktop-structural-repair/`](../../cases/2026-11-02-appimage-desktop-structural-repair/).

## What is still needed (agent-CLI probes)

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
