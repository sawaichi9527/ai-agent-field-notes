# handoff

State transfer document. `README.md` says what this repo is; **this file says where things stand**
and what the next person (usually future me) has to do.

Last updated: 2026-11-09 (Asia/Taipei)

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

**Recurrence confirmed 2026-11-09:** upgrading `dsh-gitea` 0.7.39 → **0.7.41** replaced the patched
file and the flash came back (12 `git.exe` console windows in 36 s, 11 visible). Upstream is still
unfixed — 0.7.41 is `latest`, and `main` still lacks `windowsHide`. Re-applied + restarted:
**0 console windows in 30 s**. The patch is now
[`reapply-windowsHide-patch.ps1`](cases/2026-10-30-dsh-console-flash-win/reapply-windowsHide-patch.ps1);
run it after every `dsh-gitea` update.

Details, evidence and the ready-to-send upstream draft:
[`cases/2026-10-30-dsh-console-flash-win/`](cases/2026-10-30-dsh-console-flash-win/)

Also falsified in that case: the earlier theory that `open` / `dsh-web-app` missing `windowsHide`
causes the flash. That chain never creates a console at all (four combinations + control group).

### 3. A plugin that "does not show up" is usually not installed badly

`@maxhsu/dsh-forge` never appears in the marketplace's installed list because it is a host-only
tool plugin with no client panel, and because the panel labels it by its entry id (`forge-tools`)
instead of its package name. The only reliable test is to **call a tool it registers**.

Details: [`cases/2026-09-18-dsh-plugin-not-showing/`](cases/2026-09-18-dsh-plugin-not-showing/)

## Open

| # | Item | Why it matters | Starting point |
|---|---|---|---|
| 1 | **Send the upstream issue to `@goodandready/dsh-gitea`** | the local patch lives in `node_modules` and is **overwritten on every plugin upgrade** — this already happened once (0.7.41) | draft in `cases/2026-10-30-dsh-console-flash-win/handoff.html` §14 |
| 2 | **A/B `dsh` 0.2.0 vs 0.2.1 startup** | proves or disproves "the upgrade made it slower" — never measured, only assumed | npm cache still holds a `dsh-0.2.0` tarball; install to a separate prefix, measure both against one isolated `DSH_HOME` |
| 3 | Re-check after every `dsh-gitea` upgrade | patch #2 is silently reverted by upgrades — confirmed on 0.7.41 | run `cases/2026-10-30-dsh-console-flash-win/reapply-windowsHide-patch.ps1`, restart, probe 30 s |
| 4 | Suggest a configurable poll interval to `dsh-gitea` | 4000 ms is hard-coded = 900 `git` spawns/hour for nothing | — |

## Linux track (added 2026-11-02; second pass same day)

| | |
|---|---|
| OS | Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland |
| Apps | Token Monitor **0.87.0** (0.84.1 → 0.87.0; both updates handled by the guard), eyeShell **0.1.5** (jpackage/Compose AppImage) |
| Integrator | **AppImageLauncher 3.0.0-beta-2** (git `96cb937`) on this workstation. The first Linux case documents Gear Lever 4.6.2; Gear Lever is **not installed** here, and the generated entry shapes differ (`token_monitor.desktop` vs `appimagekit_<id>-Token_Monitor.desktop`). |

**Settled — identity:** GNOME matches a window by `id == app_id + .desktop` or
`StartupWMClass == app_id`; hand edits expire when the integrator regenerates the entry. The first
case covers that.

**Settled — identity is not sufficient:** the second pass found two more failure modes that the
two-rule test cannot see:

- a structurally invalid entry (no `Type`/`Exec`) is dropped by GLib, so both rules miss and the
  app disappears from the menu; `desktop-file-validate` names the missing key;
- two entries can match the same `StartupWMClass`, and the one GNOME binds to can point at an
  `Icon=` name that was never installed (AppImageLauncher's extraction failed on the eyeShell
  AppDir). `NoDisplay=true` hides it from the menu, but it did not clear the existing window
  binding.

**Local fix:** a generic idempotent repairer in the maintenance workspace rebuilds invalid entries,
normalises every matching entry, hides duplicates, and installs 16–512 icons plus the
`appimagekit_<id>_<icon>` aliases; a systemd user path unit watches applications + hicolor. Verified
against a simulated AppImageLauncher rewrite and a simulated 0.84.1 update.
`probe-desktop-match.sh` now also checks the icon of every match and validates explicitly named
entries that GLib drops. Details:
[`cases/2026-11-02-appimage-desktop-structural-repair/`](cases/2026-11-02-appimage-desktop-structural-repair/)
and [playbook 0006](playbooks/0006-window-identity-not-icon.md).

**Verified on real updates:** Token Monitor 0.84.1 installed at 2026-11-02 21:47, and 0.87.0 at
2026-11-06 22:34. AppImageLauncher wrote the new entries in stages; the guard patched them and
removed the old 0.84.0 entry. The 0.87.0 update produced two `appimagekit_*` entries; the guard kept
one visible and hid the duplicate. The probe returns exit 0 in both cases. No manual edit was needed.

**Open:** (1) AppImageLauncher 3.0.0-beta-2 fails to extract the eyeShell icon from a jpackage AppDir
that only has root `eyeshell.png` + `.DirIcon`; packaging the seven sizes under
`usr/share/icons/hicolor/<size>/apps/eyeshell.png` fixes extraction (verified with `ail-cli`), but
the AppImage in use was not rebuilt. (2) Token Monitor's bundle still ships
`StartupWMClass=Token Monitor` while its app_id is `token-monitor`. (3) GNOME may keep the old icon
in the running window's app object; restart the app / re-login. (4) A silently broken guard looks
exactly like the original bug — re-verify after updates.

**Settled — RustDesk (2026-11-04):** "RustDesk asks for screen-capture consent again after
updating to 1.5.1" is not a regression. The unattended capability ships in a **separate package**
(`rustdesk-unattended-wayland`) that is `Conflicts/Replaces` with the standard `rustdesk` package
**at the same version number**; installing the standard deb silently removed it and capture fell
back to the XDG Desktop Portal. Fixed by reinstalling the variant deb for 1.5.1 and confirming the
DRM backend line (`drm: consumer cache warmed`) plus the absence of portal requests. New probe:
`tools/linux/probe-package-variant.sh`. Details:
[`cases/2026-11-04-rustdesk-wayland-unattended/`](cases/2026-11-04-rustdesk-wayland-unattended/)
and [playbook 0007](playbooks/0007-same-version-different-artifact.md).

**Verified end-to-end (2026-11-06):** two live sessions from a separate Ubuntu 26.04.1 / Wayland
machine. Both took the DRM path (`libdrmtap` 0.5.12, `h264_vaapi`, cursor calibration), **0** portal
requests across every log since the switch, picture normal, reconnect normal.

**Open (RustDesk):** (1) every future upgrade must take the
`rustdesk-unattended-wayland-<version>-x86_64.deb` asset, and nothing enforces that — a wrapper that
refuses the standard deb would; (2) the variant is x86_64-only as of 1.5.1.

## Self-hosted service maintenance (added 2026-11-08)

Upgraded a self-hosted ForgeJo on a LAN host (`<LAN-IP>`) from 16.0.4 to **17.0.1** — single
`docker-compose` service, SQLite data volume bind-mounted at `/data/forgejo/data`, reached over SSH
with a password service account (no sudo).

**Settled — the procedure:** check (read-only) → back up the whole volume *and prove the backup exists*
(`tar -tzf` + grep for DB/app.ini, not exit code) → `docker compose pull` while the old container runs
→ `docker compose up -d`. Migrations ran clean, web HTTP 200 on 17.0.1. The six per-owner git symlinks
were already broken (pointing at a deleted path); rebuilt each to the real `git/repositories/<owner>` —
all resolve, repo count unchanged at 31. A stale 252 MB dump in the volume was removed (~241 MB freed).

**Settled — the trap:** a backup's writable location and readable subtree are never what you assume.
`/data/forgejo` was root-owned (write there fails); `data/ssh` was root-`700` (a live `tar` then exits
non-zero, which *looks* like "no backup"). Write the archive to a path the operator owns (`~/`) and
`--exclude` the unreadable subtree, then **prove** it with `tar -tzf` + grep. Details:
[`cases/2026-11-08-forgejo-self-hosted-upgrade/`](cases/2026-11-08-forgejo-self-hosted-upgrade/) and
[playbook 0008](playbooks/0008-maintain-self-hosted-docker-over-ssh.md).

**Open:** (1) the compose image tag is `17.0` (auto-follows patches) — pin to `17.0.1` if a frozen
version is wanted; (2) verify no external webhook relies on the deprecated Action-run events, and that
no document is deep-linked via an absolute repo-root path (both 17.0 breaking changes).

## Traps that already cost time here

Keep these in mind before starting a new investigation.

1. **Measuring from inside the agent is structurally invalid.** Writes outside the session
   workspace are denied (`EPERM` at `prepareProfile`, and `--dump-config` hits the same wall),
   piped-stdout capture is denied, `tasklist` and several WMI system classes are denied, and TLS
   from a child fails with `SEC_E_NO_CREDENTIALS`. A sandboxed run of a console-flash probe
   produced "all four combinations identical" — a **meaningless** result that looked like evidence
   against a real bug. Full measured table: [docs/dsh-sandbox.md](docs/dsh-sandbox.md).
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
7. **Version-dependent claims rot silently.** One older note in this repo said a patch edit reloads
   live via `patchReload: live`; on 0.2.1-rc.5 that key does not exist anywhere in the shipped code.
   When you write "no restart needed", record the version — see
   [docs/dsh-diagnostics.md](docs/dsh-diagnostics.md).
8. **An identity-only probe can say `RESOLVED` while the dock still shows a gear.** It checks which
   entry matches, not whether that entry is loadable or whether its `Icon=` resolves. The
   AppImageLauncher case found both: a GLib-null entry and a matched entry with zero icon sizes.
   Also check `desktop-file-validate` and `GtkIconTheme.lookup_icon()`
   ([playbook 0006](playbooks/0006-window-identity-not-icon.md)).
9. **`NoDisplay=true` does not guarantee an entry stops matching windows.** Hidden entries can
   still match by `StartupWMClass`, and hiding an entry does not clear an existing binding; if the
   hidden duplicate has a broken `Icon=`, the dock can still show a gear.
10. **Agent-driven AppImage testing accumulates menu entries.** Every AppImage dropped into
    `~/Applications` is integrated as its own `appimagekit_*` entry; deleting the entry alone makes
    AppImageLauncher re-create it on its next pass. Trash/move the test AppImage too. On 2026-11-03
    an eyePageFlow test session left seven `eyePageFlow` entries plus a synthetic `mini` AppImage
    (`AppRun` was literally `echo "mini ok: $@"`); all were trashed on 2026-11-06.
11. **A self-hosted service backup can fail silently in two directions.** The archive's *write* target
    may be a directory the SSH user cannot write (root-owned data root), and a live `tar` may hit a
    subtree it cannot read (`700`); `tar` then exits non-zero, which *looks* like "no backup" but is
    only one skipped branch. Write to a path the operator owns and `--exclude` the unreadable subtree,
    then **prove** the archive with `tar -tzf` + grep for the DB/config/repos — never by exit code. See
    [playbook 0008](playbooks/0008-maintain-self-hosted-docker-over-ssh.md).
12. **A `node_modules` patch has an expiry date: the next upgrade.** The `dsh-gitea` fix was wiped by
    0.7.39 → 0.7.41 and the symptom returned unchanged. Write the re-apply step down at the same time
    as the patch (here: `reapply-windowsHide-patch.ps1`), or the second occurrence costs the whole
    investigation again.

## Handing this over

If you are picking this up: read `README.md` for the map, then
`docs/methodology.md` for the reasoning order, then the case you care about. Do not start by
changing settings — start by measuring the ratio, because every wrong-direction fix in this
repo cost hours and produced zero effect.
