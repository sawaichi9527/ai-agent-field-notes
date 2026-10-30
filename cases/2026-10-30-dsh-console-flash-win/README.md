# Case: a console window flashes every ~4 s and steals focus from the browser

**Tool:** `@deepseek-ai/dsh` 0.2.1-rc.5 + `@goodandready/dsh-gitea` 0.7.39 · **OS:** Windows 10 LTSC 2019 · **Date:** 2026-10-30
**Full write-up:** [`handoff.html`](handoff.html) (includes the falsified hypothesis and the upstream issue draft)

## Symptom

After restarting the agent from its GUI ("restart" button), a console window appears and disappears
roughly every 4 seconds. While it is visible it takes foreground focus, so typing into the browser
loses characters.

It looks like a restart bug. It is not — the restart is what **starts the browser**, and the browser
is what starts polling.

## Root cause

```
browser UI (dsh-gitea status chip)
  client.js:1905 / :1918    setInterval(fetchStatus, 4000)      ← hard-coded, not configurable
        ↓  GET /git-status
  routes.js:246 / :294      isGitDir(dir, execFile)
        ↓
  git-local.js:64           readGit(..., ['rev-parse', '--show-toplevel'])
        ↓
  git-local.js:39           exec('git', args, { cwd, timeout: 20_000, maxBuffer })   ← no windowsHide
        ↓
  git.exe spawns a console window → visible → steals foreground focus
```

`windowsHide` does not appear anywhere in `git-local.js`; the only occurrence in the package is
`plugin-updater.js:192`, which is unrelated.

## Fix

Add `windowsHide: true` to the two `exec()` option objects in `lib/git-local.js`
(`readGit`, timeout `20_000`; `writeGit`, timeout `30_000`):

```diff
- await exec('git', args, { cwd, timeout: 20_000, maxBuffer: 2 * 1024 * 1024 })
+ await exec('git', args, { cwd, timeout: 20_000, maxBuffer: 2 * 1024 * 1024, windowsHide: true })
```

**Verified:** three consecutive restarts, no flash, no focus loss.

> The patch lives in `node_modules` and **will be lost when the plugin updates**. The real fix is
> upstream — draft ready in `handoff.html` §14.

## Evidence

| Item | Value |
|---|---|
| Cadence | 3.96 / 4.32 / 3.68 / 4.03 / 4.01 / 4.04 / 3.98 / 3.98 / 4.08 s |
| Console owner | `git.exe`, parent = the agent's `node.exe` |
| Command line | `git rev-parse --show-toplevel` |
| Visibility | 4 of 7 observed windows `visible = True` |

## What made this hard

1. **The owning process lived under 50 ms**, and `Get-Process` polling on this CPU costs ~100 ms per
   call, so the parent was always dead by lookup time. Solved by enumerating **windows** and mapping
   back to a PID — see [playbook 0003](../../playbooks/0003-catch-short-lived-windows.md).
2. **Two independent pollers existed.** `NVIDIA Sync` polled every 5.2 s; this one every 4.0 s.
   Stopping the first changed the cadence to 4.0 s — the change is what proved there were two.
   See [playbook 0004](../../playbooks/0004-separate-correlated-causes.md).
3. **A plausible wrong answer had already been published.** An earlier analysis blamed
   `open`/`dsh-web-app` for spawning PowerShell without `windowsHide`. That chain was measured
   with four combinations plus a control group and **never creates a console** — the deciding
   factor is stdio redirection, not `windowsHide`. See
   [playbook 0005](../../playbooks/0005-windows-console-window-rules.md). Keeping that falsification in
   the write-up is deliberate: it prevents the same dead end from being re-run.

## Open

- Upstream issue not yet filed (draft in `handoff.html` §14).
- Worth suggesting to the author: make the 4000 ms interval configurable, or drive it from events —
  900 `git` invocations per hour is pure waste.
- If the flash returns at a ~4 s cadence after a plugin upgrade, this patch was reverted.
