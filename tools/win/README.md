# tools/win

All five are PowerShell 7 scripts, single file, no external modules. None of them installs,
deletes, or reconfigures anything. `probe-store-duplicate-keys.ps1` is the one exception in another
sense: it shells out to `node` (and borrows the `yaml` package from an installed CLI) because a
line-based re-implementation of YAML would mis-read block scalars; it writes one temporary `.mjs` and
two capture files under `%TEMP%` and removes all three.

| Script | Status | Touches | Typical runtime | Read first |
|---|---|---|---|---|
| `measure-startup.ps1` | proven | starts one extra instance on a spare port and kills it | 3 × startup time | [playbook 0001](../../playbooks/0001-measure-cpu-vs-wall.md) |
| `watch-console-windows.ps1` | proven | nothing (read-only) | any duration | [playbook 0003](../../playbooks/0003-catch-short-lived-windows.md) |
| `probe-console-visible.ps1` | template | spawns short-lived processes | ~20 s | [playbook 0005](../../playbooks/0005-windows-console-window-rules.md) |
| `isolate-spawn-options.ps1` | template | spawns short-lived processes | ~30 s | [playbook 0005](../../playbooks/0005-windows-console-window-rules.md) |
| `probe-store-duplicate-keys.ps1` | template | nothing on the target (read-only); one temp `.mjs` + two capture files | < 1 s | [playbook 0021](../../playbooks/0021-a-required-plugin-fails-on-its-data-file.md) |

## Choose in one line

- Started slowly and you do not know why → `measure-startup.ps1`
- Something flashes on screen → `watch-console-windows.ps1`
- You have a theory that a spawn chain causes the flash → `probe-console-visible.ps1`
- You have two candidate spawn options and cannot tell which matters → `isolate-spawn-options.ps1`
- A store fails to parse with `DUPLICATE_KEY at line L, column C` and you need the key name → `probe-store-duplicate-keys.ps1`

## Hard requirement

**Run these in a normal terminal, never inside an agent's sandbox.** A sandbox inflates wall time
without inflating CPU time (breaking the ratio), denies piped stdio, denies process metadata, and
can suppress console creation entirely - which silently turns every probe into a false negative.
[Playbook 0002](../../playbooks/0002-sandbox-measurements-lie.md) has the numbers.

## What is deliberately NOT here

Three approaches were tried and abandoned while solving `cases/2026-10-30-dsh-console-flash-win`.
They are documented as snippets in
[playbook 0003](../../playbooks/0003-catch-short-lived-windows.md#why-process-polling-fails)
instead of being shipped, because each produces confident-looking empty results:

- `Get-Process` polling for short-lived processes (loses the race, ~100 ms per call)
- resolving a dead parent PID through CIM (the parent is gone by query time)
- WMI `Win32_ProcessStartTrace` (untested here - needs elevation; noted as a TODO)
