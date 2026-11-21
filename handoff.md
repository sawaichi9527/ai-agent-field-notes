# handoff

State transfer document. `README.md` says what this repo is; **this file says where things stand**
and what the next person (usually future me) has to do.

Last updated: 2026-11-22 (Asia/Taipei)

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

### 4. `dsh-gitea` installed ≠ connected: install leaves `config: {}`; config must be supplied, typed, and reloaded (2026-11-13)

Installing `@goodandready/dsh-gitea` registers the entry with an **empty config**, so every
`gitea_*` call returns "Configure the Gitea instance URL in Settings." until a profile overlay
supplies `baseUrl` / `tokenEnv` / `defaultOwner` / `defaultRepo`. Traps on the way:

- **Type-strict validation.** `defaultOwner: 829522` (unquoted YAML number) fails
  `expected string but got 829522` and the plugin is **not loaded at all** — the tools disappear
  (`unknown tool`) instead of erroring. Quote it: `"829522"`.
- **Restart is the load.** The overlay's live patch reload does not re-arm a plugin whose config
  failed validation at load; a full harness restart is required, then verify by calling
  `gitea_whoami` (never by panels/lists).
- **Credential stays separate.** The token lives in DSH Credentials and is referenced by
  `tokenEnv`; the overlay never contains the value.

Result: connected to the LAN Forgejo host; `gitea_whoami` → 829522 (admin), `gitea_flavor` →
Forgejo 17.0.1 OK, the empty `829522/comfyui-gfx1151-rocm` repo confirmed reachable (clone/recipe
work pending explicit ask).

Details: [`cases/2026-11-13-dsh-gitea-config-file-windows/`](cases/2026-11-13-dsh-gitea-config-file-windows/) ·
method: [playbook 0010](playbooks/0010-verify-a-plugin-we-can-call-its-tool.md)

### 5. LM Studio's frozen token counter was a tool-call repetition loop, not a hang (2026-11-18)

- the loaded-model card sat at **`125 tok`** for 62 minutes while the engine's own log went
  **`n_gen` 0 → 159,261** at 42.7 t/s; the only thing that ended it was
  `Model unloaded by user or API request`
- **125 = 110 `reasoning_content` + 15 `content` chunks.** The 23,272 `tool_calls` chunks are not
  part of that count — the card counts rendered text, not decoded tokens
- the model looped `,"limit":6` ≈10,500 times inside one `web_search` argument object
  (`{"query":"","limit":6` …), never emitting `}` and never a `finish_reason`
- the request carried **no `max_tokens`** and the context was **262144**, i.e. up to ~100 minutes
  before the loop would end by itself
- ruled out by measurement: MTP/speculative decoding (0 error lines), swap (0 B of 31 GiB used),
  server death (HTTP API answered throughout), GPU stall (smooth 60 → 42 t/s)
- `+2 QUEUED` was the caller retrying every ~15 min **without cancelling** the previous request —
  queue depth is not backpressure when the head never finishes

Details: [`cases/2026-11-18-lmstudio-token-counter-frozen/`](cases/2026-11-18-lmstudio-token-counter-frozen/) ·
method: [playbook 0014](playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md) ·
probe: [`tools/linux/probe-sse-delta-mix.py`](tools/linux/probe-sse-delta-mix.py)

### 6. ROCm 10.2 runs beside 10.1 on `gfx1151`, and rollback is a pointer change (2026-11-20)

- Box: Ryzen AI Max+ PRO 495 / Radeon 8065S (`gfx1151`), Ubuntu 26.04.1, kernel `7.0.0-44-generic`,
  inbox `amdgpu`. The other machine in this fleet is a Ryzen AI Max+ 395 — same `gfx1151`, same
  packages, same procedure.
- `apt full-upgrade` **cannot** move between ROCm minors here: the meta-package name carries the
  version, so 10.2 is a *co-install*. Simulation said `0 upgraded, 55 newly installed, 0 to remove`.
- Current version is whatever `update-alternatives` says (`core`, `core-10`, `hipcc`, `rocminfo`,
  `amd-smi`, …). The 10.2 postinst switched all 26 groups itself; rollback is `--use 10.1`, no download.
- Performance is equal: paired A/B/B/A (50 samples, 20 s cooldown) → 0.8414 vs 0.8418 ms, **+0.05 %**;
  steady-state bandwidth 239 GB/s. Two earlier "regressions" (34 % and 2.2 %) were measurement
  artefacts — see playbook 0017.
- PyTorch 2.15.0+rocm10.2.0 works (eager 12.87 ms/step, `torch.compile` 1.09 ms/step after a 2.0 s
  compile). Since 10.2 the wheel installs its **own** ROCm into the venv, so a system rollback does
  not disturb it. `torch.compile` needs `python3.14-dev` (`Python.h`).
- Reusable artifacts: [`cases/2026-11-20-rocm-10.2-coexist-upgrade/`](cases/2026-11-20-rocm-10.2-coexist-upgrade/),
  [`tools/linux/rocm/`](tools/linux/rocm/), [`docs/rocm-gfx1151.md`](docs/rocm-gfx1151.md),
  [playbook 0016](playbooks/0016-version-you-can-undo.md).

### 7. Grace C1 boot kernel switched 1043 → 1067, with an autoremove-proof rollback (2026-11-20)

- Box: NVIDIA Grace C1 (72-core Neoverse V2, arm64 **64K-page** requirement), Ubuntu 24.04
  `nvidia-64k` flavor. Boot was `6.8.0-1043-nvidia-64k`; moved the default to
  **`6.8.0-1067-nvidia-64k`** (same lineage, NVIDIA-validated).
- The boot default is a **string pointer**, not the newest install: `GRUB_DEFAULT="Advanced options
  for Ubuntu>Ubuntu, with Linux 6.8.0-1067-nvidia-64k"`. `update-grub` regenerates grub.cfg and
  **keeps** the 1043 entry (including recovery), so rollback is flipping that one string and rebooting.
- The fallback lineage is shielded from ordinary `apt autoremove` by `apt-mark manual` on the 7
  6.8.0-1043 packages (verified via `apt-mark showmanual`). This matters: 1055 → 1064 kernels on this
  box are already `rc` (autoremove consumed them) — without the manual mark the rollback kernel would
  share their fate.
- Generic (4K) kernels coexist on the box (`linux-image-7.0.0-43-generic`, GRUB offers them,
  `needrestart` calls them "expected") but are **not bootable** on Grace — page size. Kernel choice
  here is flavor-first.
- Verified from the boot itself: `uname -r` = 1067, `/proc/cmdline` `BOOT_IMAGE=/vmlinuz-6.8.0-1067…`,
  `PAGE_SIZE` = 65536. Boot-log comparison: kernel warn/err/fail = **4 on boot 0 (1067) and 4 on boot -1
  (1043)** — identical, all pre-existing known lines; `systemctl --failed` = 0.
- Reusable: [`cases/2026-11-20-grace-c1-kernel-undo-switch/`](cases/2026-11-20-grace-c1-kernel-undo-switch/),
  [`tools/linux/grace/kernel-default-status.sh`](tools/linux/grace/kernel-default-status.sh),
  [playbook 0018](playbooks/0018-boot-default-is-a-pointer.md).

### 8. The sidebar terminal is owned by the host `webTerminals` service; its shell comes from the host `terminal-controller` config (2026-11-21)

DSH's `pwsh` tool already ran portable PowerShell **7.6.10** (`dsh-power-xc` `pwshPath`), but a
terminal opened from `dsh-better-sidebar` **0.32.1** still spawned the built-in Windows PowerShell
**5.1**. Two facts make this a general trap:

- **The plugin has no PTY** in 0.32.1. It drives the host `ctx.webTerminals`
  (`@deepseek-ai/dsh-api-terminal-controller` client half) and its `service.view(sessionId,
  contentId, contentId)` call carries **no shellPath**. The shell decision chain — source `shells.ts`
  / `client/model.ts` on CLI **0.2.2-rc.5** — is: `Config.shell` of the `terminal-controller` entry →
  else the environment default (Windows → built-in PowerShell); a new terminal without an explicit
  shell takes `discoverShells()[0]` (configured/default first), **unless** localStorage
  `dsh.terminal.shell` matches by exact path.
- **The fix is a profile overlay for the host service entry**, never the plugin:
  `config.shell = {path: C:/workspace/bin/pwsh7-7.6.10/pwsh.exe, name: …, args: ["-NoLogo"]}`.
  On 0.2.2-rc.5 the profile's `patchReload: "live"` hot-applies a config change that **passes
  validation** — no restart (this differs from a config that fails validation; that still needs a
  restart, see the 2026-11-13 dsh-gitea case). Composed tree verified with
  `dsh --profile web --dump-config` (needs full access: the agent sandbox EPERMs on the `.dsh` read);
  spawn verified with `$PSVersionTable.PSVersion.ToString(); (Get-Process -Id $PID).Path`
  → `7.6.10` + `C:\workspace\bin\pwsh7-7.6.10\pwsh.exe`, in a **NEW** terminal (already-open terminals
  keep their old process).
- **Portable-pack trap:** portable pwsh's `PSModulePath` is relative to the exe dir
  (`<exe dir>\Modules`); a mixed or damaged pack folder (the earlier `pwsh7` 7.4.6 folder) poisons
  every host that loads it — replace it whole, never repair in place.

Details: [`cases/2026-11-21-dsh-portable-pwsh-terminal-win/`](cases/2026-11-21-dsh-portable-pwsh-terminal-win/)
and [playbook 0020](playbooks/0020-the-terminal-is-owned-by-the-host-service.md).

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
| Apps | Token Monitor **0.91.0** (0.84.1 → 0.87.0 → 0.91.0; all updates handled by the guard), eyeShell **0.2.2** (0.1.9 → 0.2.2; visible entry now runs the version-free wrapper `~/.local/bin/eyeshell`) |
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
  AppDir). `NoDisplay=true` hides it from the menu but not from window matching; remove
  `StartupWMClass` from the hidden duplicate so only the visible entry matches.

**Local fix:** a generic idempotent repairer in the maintenance workspace rebuilds invalid entries,
normalises every matching entry, hides duplicates, and installs 16–512 icons plus the
`appimagekit_<id>_<icon>` aliases; a systemd user path unit watches applications + hicolor. Verified
against a simulated AppImageLauncher rewrite and a simulated 0.84.1 update.
`probe-desktop-match.sh` now also checks the icon of every match and validates explicitly named
entries that GLib drops. Details:
[`cases/2026-11-02-appimage-desktop-structural-repair/`](cases/2026-11-02-appimage-desktop-structural-repair/)
and [playbook 0006](playbooks/0006-window-identity-not-icon.md).

**Verified on real updates:** Token Monitor 0.84.1 installed at 2026-11-02 21:47, 0.87.0 at
2026-11-06 22:34, and 0.91.0 at 2026-11-12 20:39. AppImageLauncher wrote the new entries in stages;
the guard patched them and removed the old entry. The 0.87.0 update produced two `appimagekit_*`
entries; the guard kept one visible and hid the duplicate. The probe returns exit 0 in all cases.

**Verified — eyeShell 0.1.9 (2026-11-12):** clicking the menu entry did nothing while double-clicking
the AppImage worked. The entry on disk was already 0.1.9, but (a) the hidden AL duplicate still
shared `StartupWMClass` and (b) the running GNOME Shell had the 0.1.8 `ShellApp` command cached
(journal showed the old path; a fresh `Gio` read 0.1.9). Dropping `StartupWMClass` from the hidden
entry and rebooting fixed both; the user confirmed the menu and dock afterwards.

**Verified — the eyeShell 0.1.9 fix was only a state reset (2026-11-22):** the same symptom came back
after 0.2.2 was integrated **inside a live session** (login 20:30, update 01:29). The guard had
already re-pointed `eyeshell.desktop` at 0.2.2 at 01:29:46 — `desktop-file-validate` passed and a
fresh `Gio` read returned 0.2.2 — but the 01:30:58 click still ran the login-time command and died in
`env: '/home/…/Applications/eyeShell-0.1.9-x86_64.AppImage': No such file or directory`. Root cause:
`Exec=` carried the version number, so the cached `ShellApp` string expired with the file. Permanent
fix: `Exec=/home/<you>/.local/bin/eyeshell`, a wrapper that resolves the newest
`~/Applications/eyeShell-*.AppImage` at run time (skips `*.part`/empty/non-executable) and exports
`APPIMAGELAUNCHER_DISABLE=1`; the guard learned `custom_exec` so it never rewrites `Exec=` back to a
versioned path, and falls back to `env … "<AppImage>"` if the wrapper is missing. Verified before the
reboot with `eyeshell --appimage-version` (`APPIMAGELAUNCHER_DISABLE set, launching AppImage directly`)
and after it by the user's click at 01:52:41 (journal: wrapper executed by gnome-shell, `app-gnome-
eyeshell-*.scope`, app log `eyeShell=0.2.2`). Details:
[`cases/2026-11-22-eyeshell-in-session-update-shell-cache/`](cases/2026-11-22-eyeshell-in-session-update-shell-cache/),
[playbook 0012](playbooks/0012-bisect-the-launch-chain.md).

**Settled — a menu click is a five-stage chain, and all three of its silent failures were live at once
(2026-11-13).** Token Monitor 0.91.0 + AppImageLauncher 3.0.0-beta-2: clicking the app-grid icon did
nothing while double-clicking the AppImage worked, and closing the window left the app running as a
background widget. Three independent layers, each able to fail silently:

1. **the integrator's Qt GUI swallows `second-instance`** — AppImageLauncher's binfmt interpreter hands
   the AppImage to `/usr/bin/AppImageLauncher` unless `APPIMAGELAUNCHER_DISABLE` is set; a launch that
   way never delivers the app's `second-instance` event, so a click while the app is alive cannot
   restore its window (direct execution of the app binary maps the hidden window immediately:
   `IsUnMapped` → `IsViewable`);
2. **a stale Chromium singleton lock** — after a dirty exit, or a reboot while the app was running
   (`/tmp` wiped), `SingletonLock` points at a dead pid and `SingletonSocket` at a removed path; the
   next launch takes the "second instance" path, fails to notify, and exits **0** in ~1.3 s with no
   window and empty stderr;
3. **the shell cache** — GNOME Shell kept executing the pre-edit `Exec=` while a fresh
   `gtk-launch <desktop-id>` ran the new wrapper (playbook 0012, and the same trap as the eyeShell
   0.1.9 case).

Fix: a wrapper as `Exec=` (`~/.local/bin/token-monitor`) that picks the newest
`~/Applications/Token-Monitor-*.AppImage`, clears a dead/missing singleton lock, exports
`APPIMAGELAUNCHER_DISABLE=1`, then execs; plus `enable_daemon = false` and
`systemctl --user disable --now appimagelauncherd` so the integrator stops rewriting the entry; plus a
`.path` unit and a login oneshot that re-point `Exec=` and clear locks (verified: a hand-rewritten
`Exec=` reverted in ≤3 s); plus one session reload for layer 3. After the reboot the journal shows the
wrapper executed by gnome-shell and `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly`; the
user confirmed the menu click works. Probe:
`tools/linux/probe-appimage-launch-chain.sh`. Details:
[`cases/2026-11-13-appimage-menu-click-launch-chain/`](cases/2026-11-13-appimage-menu-click-launch-chain/),
[playbook 0012](playbooks/0012-bisect-the-launch-chain.md).

**Verified — Token Monitor 0.91.0 menu click (2026-11-13):** a separate shape of "the click does
nothing". The entry was valid and pointed at the installed AppImage, but each click started a
process that exited in ~2.2 s with **no app log at all**. 0.91.0's `launch.js` calls
`linuxDisplayServer.startWithXWayland()`, which re-execs the AppImage with `--ozone-platform=x11`,
detached and with `stdio: 'ignore'`, then calls `app.exit(0)`. GNOME runs menu launches in a
transient `app-gnome-*.scope` whose default `KillMode=control-group` kills the rest of the cgroup
when the main process exits, so the relaunched child died before it could mount the AppImage. Fix:
put `--ozone-platform=x11` on the entry's `Exec=` (and in the guard's `exec_suffix`), so the
wrapper takes its "already selected" branch and never forks. User-confirmed after a reboot. The
first post-fix test was a **false negative**: the running Shell still had the old `ShellApp`
command, so the journal looked identical before and after the edit. Details:
[`cases/2026-11-13-token-monitor-menu-click-noop/`](cases/2026-11-13-token-monitor-menu-click-noop/)
and [playbook 0013](playbooks/0013-menu-click-noop-is-a-lifetime-question.md).

**Open:** (1) AppImageLauncher 3.0.0-beta-2 fails to extract the eyeShell icon from a jpackage AppDir
that only has root `eyeshell.png` + `.DirIcon`; packaging the seven sizes under
`usr/share/icons/hicolor/<size>/apps/eyeshell.png` fixes extraction (verified with `ail-cli`), but
the AppImage in use was not rebuilt. (2) Token Monitor's bundle still ships
`StartupWMClass=Token Monitor` while its app_id is `token-monitor`. (3) GNOME caches the `ShellApp`
command line/icon for the session; after `Exec=`/`Icon=` changes the menu can keep running the old
path while a fresh `Gio` reads the new one. Log out/in or reboot (or use a new desktop ID) — and keep
`Exec=` version-free, or the next in-session update re-arms the trap (eyeShell does; Token Monitor
still does not). (4) A silently
broken guard looks exactly like the original bug — re-verify after updates. (5) Token
Monitor's upstream `startWithXWayland` discards the child's stdio and exits the parent before the
child is ready; the `Exec` flag is a workaround, not a fix at the source.

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

## DSH plugin lifecycle (added 2026-11-12)

**Settled — "remove failed" was package state, not a permission or a broken plugin.** On an Ubuntu
24.04.5 workstation (dsh **0.2.2-rc.1**, pnpm **12.4.2**), removing `dsh-multi-lang-ui@0.1.1` failed
with nothing but `Command failed with exit code 1`. The plugin manager's per-operation log held the
command line and **not** pnpm's stderr; re-running the same command on a copy of the profile showed
`ERR_PNPM_UNUSED_PATCH` — the plugin had been fixed for DSH 0.2.0-rc.2 months earlier with pnpm's
native patch mechanism, and pnpm refuses to remove the last dependent of a declared patch.

The failure also left the profile **half-removed**: `removeBundle` writes the bundle deselection
(and the `disabled: true` overlay row) *before* it calls `pnpm remove`, so the plugin was no longer
loaded, still installed, and impossible to remove by retrying. Fixed by withdrawing the
`patchedDependencies` declaration first, re-running removal (exit 0 in 3 s), then deleting the
orphan overlay row (until then `--dump-config` warned `patch: entry "multi-lang-ui" not found`) and
the orphan patch file. Final state: `--dump-config` 202 rows, stderr empty; 6 dependencies; 0
lockfile references; the live server still answering (401 without a token is its normal auth).
Details: [`cases/2026-11-12-dsh-plugin-remove-unused-patch/`](cases/2026-11-12-dsh-plugin-remove-unused-patch/)
and [playbook 0009](playbooks/0009-uninstall-failure-is-package-state.md).

**Open:** (1) `@deepseek-ai/dsh-plugin-manager` 0.2.2-rc.1 `removeBundle` still (a) does not clean the
profile's own `patchedDependencies` for the package being removed, (b) commits the deselection
before pnpm runs, and (c) reports only an exit code — the upstream fix is to withdraw the patch
declaration first, roll back the deselection on failure, and surface pnpm's stderr. (2) Any
compatibility patch applied by hand to a profile must be recorded next to the reinstall/removal
step, or it gates the uninstall later.

## Agent-runtime timeouts and breakers (added 2026-11-20)

**Settled — "the agent stopped answering" was a latched circuit breaker, not a dead model.** A
chat-bound profile answered every message in **0.5 s** with `Provider has been unresponsive … 6
consecutive stale attempts`, while the same backend served a 16-token completion in 0.29 s. The
cross-turn breaker (`_consecutive_stale_streams`, give-up threshold `HERMES_STREAM_STALE_GIVEUP` = 5)
had latched: past the threshold every call raises **before opening a socket**, and the streak resets
only on a successful call, a model/provider switch, or a process restart — so retrying can never
recover.

**Settled — the stale timeout times queue position, not model speed.** Measured on the same backend
with cache-hostile payloads: cold 117 k-token TTFT **195.5 s** (599 tok/s), the same payload again
**0.25 s** (prompt cache), cold 60 k **69.4 s** (860 tok/s), and — the decisive one — a second
concurrent request took **400.8 s** ≈ 195 + 195, i.e. the server has exactly **one request slot**.
The deployed value was 300 s, which is *enough* for a single cold request and *not enough* for one
queued request; seven profiles pointed at that endpoint, so collisions were routine. 188 of 201 stale
kills had `chunks=0`, confirming the knob is a TTFT budget (every chunk resets it; output length is
irrelevant).

**Applied:** `agent.local_stream_stale_timeout` raised 300 → 900 in every profile that streams to the
local backend (per-profile files only — a named profile does not merge the global config), verified
through Hermes' own `load_config_readonly()` rather than by grepping the file. 900 covers up to **4**
concurrent cold 100 k requests by the measured arithmetic.

**Open — this regresses the 2026-11-18 fix, deliberately.** That case lowered 900 → 300 so a
genuinely wedged backend is reclaimed in ~5 min, because a kanban worker that keeps heartbeating
while producing nothing escapes the 3600 s stale detector. With 900, a dead backend burns ~45 min per
API call (900 s × 3 attempts) and ~75 min to latch the breaker. The structural fixes are not timeout
values: stop sharing one single-slot endpoint across seven agents, shrink the context (98 k → 20–30 k
turns 195 s into ~25 s), or route chat to a hosted model and keep the local box for batch work.
Details: [`cases/2026-11-20-hermes-stale-breaker-latched/`](cases/2026-11-20-hermes-stale-breaker-latched/),
[playbook 0019](playbooks/0019-a-timeout-measures-queue-position.md), probe
[`tools/linux/probe-ttft-under-contention.py`](tools/linux/probe-ttft-under-contention.py).

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
   On **0.2.2-rc.5** it exists, and a config change that **passes validation** hot-applies without a
   restart (2026-11-21 portable-pwsh case); a config that **fails validation** still needs a full
   restart (2026-11-13 dsh-gitea case). When you write "no restart needed", record the version — see
   [docs/dsh-diagnostics.md](docs/dsh-diagnostics.md).
8. **An identity-only probe can say `RESOLVED` while the dock still shows a gear.** It checks which
   entry matches, not whether that entry is loadable or whether its `Icon=` resolves. The
   AppImageLauncher case found both: a GLib-null entry and a matched entry with zero icon sizes.
   Also check `desktop-file-validate` and `GtkIconTheme.lookup_icon()`
   ([playbook 0006](playbooks/0006-window-identity-not-icon.md)).
9. **`NoDisplay=true` does not guarantee an entry stops matching windows.** Hidden entries can
   still match by `StartupWMClass`. Remove `StartupWMClass` from the hidden duplicate so only the
   visible entry matches; patching the hidden entry's icon is a fallback, not the fix.
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
13. **A failed removal leaves "not loaded but still installed".** Wrappers that stage a remove across
    selection list → package files → overlay rows can stop halfway and still report failure, so the
    plugin disappears from the UI while `package.json`, `node_modules` and the lockfile keep it. Do
    not trust the list state: check dependency declaration, lockfile, installed tree, selection list
    and overlay rows, then `--dump-config`. A declared patch outliving its package
    (`ERR_PNPM_UNUSED_PATCH`) is the usual blocker — withdraw the declaration before removing
    ([playbook 0009](playbooks/0009-uninstall-failure-is-package-state.md)).
14. **GNOME Shell caches the `ShellApp` command line for the session.** After an AppImage update the
    `.desktop` file may correctly point at 0.1.9 while a menu click still executes 0.1.8 and fails
    (`env: … No such file or directory`); double-clicking the AppImage works because it bypasses the
    cached entry. A fresh `Gio` process reads the new command. Log out/in or reboot (Wayland has no
    shell-only restart), or use a new desktop ID to force a fresh app object. **The same cache also
    makes a correct fix look broken:** after editing `Exec=`, a click in the same session runs the
    old command and reproduces the identical failure signature — reboot before judging the fix.
15. **An instance the agent started contaminates every later click.** A test launch holds the
    Chromium singleton lock, so the user's next menu click is a *second instance*: it exits 0 in
    ~1.3 s and looks exactly like the bug you were asked to fix. Three "still broken" reports here were
    the agent's own leftover instance. Check `ps` from **outside** the sandbox before judging any click,
    and test the "already running → window hidden" contract separately from the cold start.

16. **"Exit 0 + ~1.3 s CPU + no window + empty stderr" is the single-instance path, not a crash.**
    Check `~/.config/<Product>/SingletonLock` (holder alive?) and `SingletonSocket` (target exists?)
    before touching the launcher, the AppImage or the icon. Plant a stale lock to prove a fix; a repair
    that never saw a failing input proves nothing.

17. **A valid desktop entry can still "do nothing" because the process dies.** GNOME starts
    menu-launched apps in a transient `app-gnome-*.scope`; when the main process exits, systemd
    stops the scope and kills the rest of the cgroup. A launcher that forks a helper and exits
    (Token Monitor 0.91.0's XWayland relaunch) loses the helper, and `stdio: 'ignore'` hides why.
    Check scope lifetime, `tmp-.mount_*` count and the app's own log lines before touching the
    entry ([playbook 0013](playbooks/0013-menu-click-noop-is-a-lifetime-question.md)).

18. **A frozen progress number is a claim about the display's accounting, not the engine's output.**
    LM Studio's card read `125 tok` for an hour while the engine logged 159k decoded tokens; 125 was
    exactly `110 reasoning + 15 content` chunks, and the entire hour of `tool_calls` was excluded from
    the count. Find the engine-side counter (`n_gen`, `tg`, `n_decoded`) before diagnosing a stall —
    the number on screen may simply not count what you think it counts
    ([playbook 0014](playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md)).

19. **A "version upgrade" whose package name contains the version is a co-install, and the package
    manager will not cross that boundary for you.** `apt full-upgrade` did nothing while looking
    successful, because no `amdrocm*` package was "upgradable"; the new minor is a different package
    in a different directory. Ask `apt-get -s` for `0 to remove` before believing an upgrade is safe,
    and record the `update-alternatives` map as the rollback point
    ([playbook 0016](playbooks/0016-version-you-can-undo.md)).

20. **One measurement per version is not a comparison.** The same GPU measured 94.6 GB/s in a
    single-shot smoke test and 239–242 GB/s with warmup; a naive A/B said 10.2 was 2.2 % slower until
    the order was reversed, after which 10.2 was 1.4 % *faster*. Warm up, interleave A/B/B/A, cool
    down, compare same-position numbers, and quote the resolution next to the delta
    ([playbook 0017](playbooks/0017-version-comparison-needs-pairing.md)).

21. **On a boot-managed box, "newest installed" is not "what boots".** GRUB-DEFAULT is a string
    pointer into the Advanced-options submenu; the top-level Ubuntu entry, `/boot` symlinks and
    `needrestart` all track the newest install and disagree on purpose. And a fallback kernel the
    pointer no longer selects is exactly what `apt autoremove` will prune — shield it with
    `apt-mark manual`, or lose it the way this box lost kernels 1055–1064
    ([playbook 0018](playbooks/0018-boot-default-is-a-pointer.md)).

## Handing this over

If you are picking this up: read `README.md` for the map, then
`docs/methodology.md` for the reasoning order, then the case you care about. Do not start by
changing settings — start by measuring the ratio, because every wrong-direction fix in this
repo cost hours and produced zero effect.
