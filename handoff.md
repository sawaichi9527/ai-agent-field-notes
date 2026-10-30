# handoff

State transfer document. `README.md` says what this repo is; **this file says where things stand**
and what the next person (usually future me) has to do.

Last updated: 2026-10-30 (Asia/Taipei)

## Baseline environment

| | |
|---|---|
| Agent CLI | `@deepseek-ai/dsh` **0.2.1-rc.5** |
| Node | v24.21.0 (npm 11.19.0) |
| OS | Windows 10 Enterprise LTSC 2019, build 17763.9376 |
| CPU | Intel Core 2 Quad Q9500 @ 2.83 GHz (4 threads, 2008) |
| Profile | 10 bundles = 2 official + 8 third-party |
| Install size | global `node_modules` 63,689 files; profile `node_modules` 16,582 files |

This machine is slow but not broken: `C:` is an Intel SSD, Windows Defender real-time is **stopped**,
no third-party AV, no proxy environment variables. Anything attributed to "antivirus" or "spinning
disk" on this box is almost certainly wrong.

## Settled

### 1. Slow startup is CPU-bound, and the cost scales with bundle count

- median **21.6 s** to first URL, CPU **23.3 s**, **CPU/wall 106–109 %**
- the same measurement on a faster reference machine (i7-4900MQ, 9 bundles) was 16.1 s
- ≈ **0.6 s per third-party bundle**; cutting 10 → 2 bundles should save **5–6 s**, not more
- ruled out by measurement: Defender, disk type, proxy/DNS, port contention, power plan,
  `NODE_COMPILE_CACHE`

Details and the falsified hypotheses: [`cases/2026-10-30-dsh-slow-startup-win/`](cases/2026-10-30-dsh-slow-startup-win/)

### 2. The "console flashes every few seconds" bug is `dsh-gitea`, and it is fixed locally

Chain: browser status chip polls every 4000 ms → `/git-status` → `isGitDir()` →
`git rev-parse --show-toplevel` via `exec()` **without `windowsHide`** → a console window
appears, and while visible it **steals foreground focus** (that is why typing in the browser
lost characters).

Fix: add `windowsHide: true` to the `exec` options in `git-local.js` (`readGit` and `writeGit`).
Verified: **three consecutive restarts, no flash**.

Details, evidence and the ready-to-send upstream draft:
[`cases/2026-10-30-dsh-console-flash-win/`](cases/2026-10-30-dsh-console-flash-win/)

Also falsified in that case: the earlier theory that `open` / `dsh-web-app` missing `windowsHide`
causes the flash. That chain never creates a console at all (four combinations + control group).

## Open

| # | Item | Why it matters | Starting point |
|---|---|---|---|
| 1 | **Send the upstream issue to `@goodandready/dsh-gitea`** | the local patch lives in `node_modules` and **will be overwritten on the next plugin upgrade** | draft in `cases/2026-10-30-dsh-console-flash-win/handoff.html` §14 |
| 2 | **A/B `dsh` 0.2.0 vs 0.2.1 startup** | proves or disproves "the upgrade made it slower" — never measured, only assumed | npm cache still holds a `dsh-0.2.0` tarball; install to a separate prefix, measure both against one isolated `DSH_HOME` |
| 3 | Re-check after every `dsh` upgrade | patch #2 is silently reverted by upgrades | if the flash returns at ~4 s intervals, it is this |
| 4 | Suggest a configurable poll interval to `dsh-gitea` | 4000 ms is hard-coded = 900 `git` spawns/hour for nothing | — |

## Traps that already cost time here

Keep these in mind before starting a new investigation.

1. **Measuring from inside the agent is structurally invalid.** Every write outside the session
   workspace is denied (`EPERM` at `prepareProfile`), piped-stdout capture is denied, and process
   enumeration (`Get-Process` by name, `tasklist`, CIM) is denied. A sandboxed run of a
   console-flash probe produced "all four combinations identical" — a **meaningless** result that
   looked like evidence against a real bug.
2. **A sandboxed measurement of a stock profile read 37–48 s / 55–70 % CPU** while the same real
   object outside the sandbox was 21.6 s / 108 %. The sandbox inflates wall time without inflating
   CPU, so the ratio lands in the wrong band. See [playbook 0002](playbooks/0002-sandbox-measurements-lie.md).
3. **`Get-Process` polling cannot see a process that lives < 50 ms** — and on this CPU one
   `Get-Process` call costs ~100 ms, so the real polling period is far worse than configured.
   Enumerate **windows** and map back to a PID instead
   ([playbook 0003](playbooks/0003-catch-short-lived-windows.md)).
4. **Two independent pollers can coexist.** Stopping one changed the flash cadence from 5.2 s to
   4.0 s — that change is what proved they were different culprits.
5. **`restart-helper-<pid>.log` containing only `loaded` does not mean "has a console".** It means
   the helper module loaded. Only `MainWindowHandle` answers the console question.
6. **`dsh-web.log` has no timestamps.** It can tell you *whether* something was skipped, never
   *how long* a startup took. Use the restart-helper log for wall-clock, and measure for real numbers.

## Handing this over

If you are picking this up: read `README.md` for the map, then
`docs/methodology.md` for the reasoning order, then the case you care about. Do not start by
changing settings — start by measuring the ratio, because every wrong-direction fix in this
repo cost hours and produced zero effect.
