# Case: a console window flashes every ~4 s and steals focus from the browser

**Tool:** `@deepseek-ai/dsh` 0.2.1-rc.5 + `@goodandready/dsh-gitea` 0.7.39 · **OS:** Windows 10 LTSC 2019 · **Date:** 2026-10-30
**Re-checked:** 2026-11-09 on `dsh-gitea` **0.7.41** — the upgrade reverted the patch and the flash came back; upstream still unfixed
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

## Recurrence: the upgrade reverted it (2026-11-09)

`dsh-gitea` was upgraded **0.7.39 → 0.7.41**, which replaced `lib/git-local.js` and wiped the patch —
exactly the failure mode predicted above. The flash returned, so the same probe was re-run on the
new version:

| | 0.7.39 (2026-10-30) | 0.7.41 (2026-11-09) |
|---|---|---|
| `windowsHide` in `git-local.js` | absent → patched | absent again (only `plugin-updater.js:192` has it) |
| 30–40 s probe | 7 windows, 4 visible | **12 windows in 36 s, 11 visible — all `git.exe`** |
| Patch + restart | 3 restarts, no flash | re-applied, 1 restart → **0 console windows in 30 s** |

New detail: 0.7.41's `/git-status` handler calls `buildGitSnapshot()` (`git-local.js:171`), which
runs **six `git` commands in parallel** per request (`rev-parse` ×3, `status`, `log`, `remote`),
plus `isGitDir()`'s `rev-parse`. The snapshot cache TTL is **2500 ms < the 4000 ms poll**, so it
never hits — every poll spawns ~7 consoles, which is why the windows arrive in bursts rather than
one clean 4 s beat.

Upstream status checked 2026-11-09:

- npm `dist-tags.latest` = **0.7.41** (also the installed version)
- `lib/git-local.js` on `main` still has no `windowsHide`
- no fix upstream yet; the issue has not been filed by us (draft in `handoff.html` §14)

Because this will happen on every upgrade, the patch is now a script:
[`reapply-windowsHide-patch.ps1`](reapply-windowsHide-patch.ps1) (idempotent, backs up, `-DryRun`).
Run it after any `dsh-gitea` update, restart `dsh web`, and re-probe for 30 s.

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

- Upstream issue not yet filed (draft in `handoff.html` §14) — still unfixed in the latest release
  (0.7.41) as of 2026-11-09.
- Worth suggesting to the author: make the 4000 ms interval configurable, or drive it from events —
  900 `git` invocations per hour is pure waste. 0.7.41 made it worse: ~7 spawns per poll.
- **Recurrence is confirmed, not hypothetical:** if the flash returns after a plugin upgrade,
  `git-local.js` was replaced. Run `reapply-windowsHide-patch.ps1`, restart, and re-probe.
