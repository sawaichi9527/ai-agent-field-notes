# ai-agent-field-notes

Field notes on AI coding agents — **DSH, opencode, and whatever comes next** — across **Windows and Ubuntu**.

These are not opinions or tutorials. Each entry is a case that was actually measured with a
reproducible probe, including the hypotheses that **failed** and why.

## Why this repo exists

Debugging an AI agent CLI is a different problem from debugging an app:

- the interesting parts are **module loading**, **plugin graphs**, and **subprocess spawning**
- symptoms are often **timing-dependent** and belong to no single component
- the agent itself is the wrong observer — it runs under the very sandbox that distorts the measurement

So the value here is not "the answer" but **the method that gets you the answer**, plus enough
evidence that you can tell a real root cause from a coincidence.

## Symptom index

| Symptom | Tool | OS | Root cause | Write-up |
|---|---|---|---|---|
| Every incoming connection pops the system "allow screen sharing" dialog, even with a password set | RustDesk 1.5.1 | Ubuntu 26.04.1 (GNOME 50, Wayland) | the unattended/DRM variant package was replaced by the **same-version** standard package, so capture fell back to the XDG Desktop Portal | [case](cases/2026-11-04-rustdesk-wayland-unattended/) · [playbook](playbooks/0007-same-version-different-artifact.md) |
| The dock shows a generic gear icon for an AppImage whose icon is correct | Token Monitor (Electron AppImage) + Gear Lever | Ubuntu 26.04.1 (GNOME 50, Wayland) | desktop id and `StartupWMClass` both differ from the window `app_id`; the integration tool rebuilds the entry from the app's own (wrong) bundle | [case](cases/2026-11-02-appimage-dock-gear-linux/) · [playbook](playbooks/0006-window-identity-not-icon.md) |
| The app is missing from the menu, appears twice, or shows a gear even though its PNG is fine | Token Monitor + eyeShell (AppImageLauncher) | Ubuntu 26.04.1 (GNOME 50, Wayland) | one entry was structurally invalid (no `Type`/`Exec`, so GLib dropped it); one app had two entries matching the same WM_CLASS and the winning entry's `Icon` name was never installed | [case](cases/2026-11-02-appimage-desktop-structural-repair/) · [playbook](playbooks/0006-window-identity-not-icon.md) |
| Clicking an app-menu shortcut does nothing after an AppImage update, while double-clicking the AppImage works | eyeShell 0.1.9 + AppImageLauncher | Ubuntu 26.04.1 (GNOME 50, Wayland) | the entry on disk was correct, but the running GNOME Shell had cached the old `ShellApp` command; a hidden duplicate also shared `StartupWMClass` | [case](cases/2026-11-02-appimage-desktop-structural-repair/) · [playbook](playbooks/0006-window-identity-not-icon.md) |
| Clicking the menu icon does nothing — no window, no error — and clicking it while the app is already running does nothing either | Token Monitor 0.91.0 + AppImageLauncher 3.0.0-beta-2 | Ubuntu 26.04.1 (GNOME 50, Wayland) | three independent silent layers: the integrator's Qt GUI swallows `second-instance`, a stale Chromium `SingletonLock` makes the app exit in ~1.3 s with exit 0, and GNOME Shell keeps running the cached `Exec=` | [case](cases/2026-11-13-appimage-menu-click-launch-chain/) · [playbook](playbooks/0012-bisect-the-launch-chain.md) |
| Clicking the app-menu shortcut does nothing after an **in-session** AppImage update, while double-clicking the AppImage works | eyeShell 0.2.2 + AppImageLauncher 3.0.0-beta-2 | Ubuntu 26.04.1 (GNOME 50, Wayland) | `Exec=` carried the version number, so the session's cached `ShellApp` command outlived the file (`env: '…0.1.9…': No such file or directory`); the 0.1.9 reboot-only fix expired at the next update | [case](cases/2026-11-22-eyeshell-in-session-update-shell-cache/) · [playbook](playbooks/0012-bisect-the-launch-chain.md) |
| The app-menu icon "does nothing" although the entry is valid and the app is installed | Token Monitor 0.91.0 (Electron 45 AppImage) | Ubuntu 26.04.1 (GNOME 50, Wayland) | the app's own XWayland self-relaunch spawned a detached child and exited; GNOME's transient app scope killed the child, and its stdio was ignored, so the click left no app log at all | [case](cases/2026-11-13-token-monitor-menu-click-noop/) · [playbook](playbooks/0013-menu-click-noop-is-a-lifetime-question.md) |
| Startup takes 20+ s, window blank the whole time | DSH | Windows 10 | CPU-bound module loading; cost scales with plugin bundle count | [case](cases/2026-10-30-dsh-slow-startup-win/) · [playbook](playbooks/0001-measure-cpu-vs-wall.md) |
| A console window flashes every ~4 s and typing in the browser loses characters | DSH + `@goodandready/dsh-gitea` | Windows 10 | `git rev-parse` spawned from a 4 s status poll without `windowsHide`; **returns after every plugin update** (re-confirmed on 0.7.41) | [case](cases/2026-10-30-dsh-console-flash-win/) · [playbook](playbooks/0003-catch-short-lived-windows.md) |
| A plugin is installed but never shows up in the marketplace's "installed" list | DSH + `@maxhsu/dsh-forge` | Windows | host-only plugin has no UI panel; the panel also labels it by entry id, not package name | [case](cases/2026-09-18-dsh-plugin-not-showing/) |
| Removing a plugin fails with "exit code 1", and it stays half-removed — gone from the list, still installed, retries keep failing | DSH + `dsh-multi-lang-ui` | Ubuntu 24.04.5 | a stale pnpm `patchedDependencies` entry lost its only dependent (`ERR_PNPM_UNUSED_PATCH`); the manager commits the bundle deselection **before** pnpm runs, so the failure leaves a half-applied removal | [case](cases/2026-11-12-dsh-plugin-remove-unused-patch/) · [playbook](playbooks/0009-uninstall-failure-is-package-state.md) |
| After installing `@goodandready/dsh-gitea`, every `gitea_*` tool says "Configure the Gitea instance URL in Settings"; a config edit then made the tools disappear | DSH + `@goodandready/dsh-gitea` 0.7.44 | Windows | bundle installs the entry with an empty `config: {}`; the working config (baseUrl / tokenEnv / defaultOwner / defaultRepo) must be supplied as a profile overlay, `defaultOwner` must be a **quoted string**, and a config that failed validation needs a full restart to load | [case](cases/2026-11-13-dsh-gitea-config-file-windows/) · [playbook](playbooks/0010-verify-a-plugin-we-can-call-its-tool.md) |
| `apt update` ends with three `Notice:` lines every run: two `doesn't support architecture 'i386'`, one `Missing Signed-By` | apt 3.2.1 | Ubuntu 26.04.1 LTS | `i386` is a foreign architecture (kept for Steam/Wine) but those two third-party repos index **amd64 only**; and `apt modernize-sources` rewrote the NVIDIA entry with an **empty** `Signed-By` while its key stayed in `trusted.gpg.d` | [case](cases/2026-11-13-apt-update-three-notices/) · [playbook](playbooks/0011-terminal-only-output-is-not-the-output.md) |
| The token counter on the loaded-model card sits at `125 tok` with the spinner running, while the queue fills up | LM Studio 0.4.x (llama.cpp, MTP) + `ornith-1.5-35b-a3b` Q4_K_M | Ubuntu (kernel 7.0) | the counter only counts reasoning/content chunks (110 + 15 = 125); the engine was looping `,"limit":6` inside one tool-call's JSON — 159k tokens, no `finish_reason` — and the request carried no `max_tokens` with a 262144 context | [case](cases/2026-11-18-lmstudio-token-counter-frozen/) · [playbook](playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md) |
| A coordinator's kanban worker sits at `running` for hours — heartbeat on, zero output, board never clears it | hermes-agent v0.23.2 (OPC multi-profile) + local `ornith-1.5-35b-a3b` via LM Studio @ `.217:1234` | Ubuntu (kernel 7.0) | local decode backend goes silent (HTTP 200, ~900s zero chunks) while keeping its heartbeat; kanban stale needs 3600s no-heartbeat so it's missed — same class as the frozen token counter, manifesting as zero output instead of a frozen counter | [case](cases/2026-11-18-coordinator-hung-worker-local-decode-stall/) · [playbook](playbooks/0015-stale-watchdog-is-a-timing-claim.md) |
| `apt` lists ROCm 10.2 but `apt full-upgrade` leaves you on 10.1 — and you need a way back | ROCm Core SDK 10.1.0 → 10.2.0 (TheRock `amdrocm*` debs) | Ubuntu 26.04.1 (kernel 7.0, `gfx1151`) | the two minors are separate package sets in versioned directories (`/opt/rocm/core-10.x`); `update-alternatives` decides which is current, so installing is a **co-install** and rollback is a pointer change | [case](cases/2026-11-20-rocm-10.2-coexist-upgrade/) · [playbook](playbooks/0016-version-you-can-undo.md) |
| Every message to a chat-bound agent comes back in **0.5 s** with "Provider has been unresponsive … 6 consecutive stale attempts", and retrying never helps — while the model itself answers in 0.29 s | hermes-agent 0.23.2 (9-profile gateway) + local `ornith-1.5-35b-a3b` via LM Studio (single request slot) | Ubuntu (kernel 7.0) | a cross-turn circuit breaker (`_consecutive_stale_streams`) latched at ≥5 stale kills, and the 300 s stale timeout was below measured TTFT **with one request queued** (400.8 s vs 195.5 s alone) — the knob times queue position, not model speed | [case](cases/2026-11-20-hermes-stale-breaker-latched/) · [playbook](playbooks/0019-a-timeout-measures-queue-position.md) |
| I switched the boot kernel and the "newest installed" claims a *different* kernel is expected; and my fallback kernel disappeared from `apt autoremove` | Ubuntu kernel `nvidia-64k` flavor (NVIDIA Grace C1, 72-core Neoverse V2) | Ubuntu 24.04 (Grace, non-x86) | boot is decided by `GRUB_DEFAULT`, a string pointer into the Advanced-options submenu — not by the newest install, `/boot` symlinks or `needrestart`; and `apt autoremove` consumes a kernel the pointer no longer selects unless it is `apt-mark manual` | [case](cases/2026-11-20-grace-c1-kernel-undo-switch/) · [playbook](playbooks/0018-boot-default-is-a-pointer.md) |
| A sidebar plugin's terminal keeps spawning the built-in Windows PowerShell while the host's own tool already runs portable 7.6.10 | DSH CLI 0.2.2-rc.5 + `dsh-better-sidebar` 0.32.1 | Windows 10 | the plugin has no PTY; the terminal is spawned by the host `webTerminals` service, whose shell choice starts at the service's `Config.shell` — patch the host `terminal-controller` overlay, not the plugin | [case](cases/2026-11-21-dsh-portable-pwsh-terminal-win/) · [playbook](playbooks/0020-the-terminal-is-owned-by-the-host-service.md) |
| `dsh web` dies with `startup failed: 1 required plugin did not activate` + `DUPLICATE_KEY at line 21, column 3`, and 12 plugins wait for services; reinstall, reboot and `npm update -g` change nothing | DSH CLI 0.2.2-rc.5 + `dsh-gitea` token | Windows 10 Enterprise LTSC | the credential store is parsed with duplicate-key rejection and belongs to a **required** plugin, so a second hand-appended `GITEA_TOKEN` in the same `refs:` section fails the whole plugin graph; the message withholds the key name because that line is the secret | [case](cases/2026-11-22-dsh-credentials-dupkey-startup/) · [playbook](playbooks/0021-a-required-plugin-fails-on-its-data-file.md) |
| Every `npm install/update -g` of the CLI ends with `N packages had install scripts blocked …`, and the list changes between runs | DSH global install (npm 12.2.3) | Windows 10 Enterprise LTSC | advisory policy message, not a missing artifact: `koffi` resolves from a per-platform optional dependency, `node-pty` ships `prebuilds/`, and `dsh-subprocess-local`'s postinstall is a POSIX-only `chmod` — nothing needed the scripts; `--allow-scripts` is one-shot and the `.npmrc` list replaces rather than appends | [case](cases/2026-11-22-dsh-credentials-dupkey-startup/) · [playbook](playbooks/0022-an-install-script-warning-is-not-a-missing-artifact.md) |
| Pressing the "x" closes the whole RustDesk and it never auto-starts — the "shrink to the tray" never happens | RustDesk (Windows) | Windows 10 Enterprise LTSC | the Windows service was never installed: the app runs in normal-app mode (main + `--cm`), which has no tray component and no auto-start; the always-on mode is a registered service (`--service`, LocalSystem, AUTO_START) + a separate `--tray` process | [case](cases/2026-11-22-rustdesk-service-mode-win/) · [playbook](playbooks/0023-always-on-is-an-installed-service.md) |
| Importing a PPTX template into a ppt-master pack: SVG slots say 4, the PPTX is 5 pages, opencode and the DSH wrapper load the same "template" from different places, and a bare-URL LAN push dies with a TLS error | DSH 0.2.2-rc.5 + `dsh-ppt-master-wrapper` + ppt-master (`hugohe3`) v6.10.0 | Windows 10 (consumer templates are cross-OS; LAN forgejo/Gitea mirror) | "template" is two artifacts — the native PPTX (contract, stays in the round-trip workspace) vs the SVG slots (`page_count`), and each consumer has its own slot/registry; the LAN mirror speaks token-embedded http, not https | [case](cases/2026-11-23-dsh-ppt-master-pack-import/) · [playbook](playbooks/0024-dsh-import-a-deck-into-a-ppt-master-pack.md) |

## Playbooks (the reusable part)

These are tool-agnostic. Unless an entry says otherwise, they apply to any agent CLI on any OS.

1. [Measure CPU-vs-wall before anything else](playbooks/0001-measure-cpu-vs-wall.md) — one ratio splits "busy" from "waiting"
2. [Sandbox measurements lie](playbooks/0002-sandbox-measurements-lie.md) — never classify from inside the agent's sandbox
3. [Catch short-lived windows when process polling fails](playbooks/0003-catch-short-lived-windows.md)
4. [Separate causes that share the same symptom](playbooks/0004-separate-correlated-causes.md)
5. [On Windows, stdio decides whether a console appears — not `windowsHide`](playbooks/0005-windows-console-window-rules.md)
6. [A wrong window icon is usually identity — but verify the asset too](playbooks/0006-window-identity-not-icon.md) — match by id/`StartupWMClass`, then check the entry is loadable and every matched entry's `Icon` resolves
7. [A regression after an upgrade is a different artifact, not a worse version](playbooks/0007-same-version-different-artifact.md) — check the package state and the file that carries the capability, not the version string
8. [An uninstall that refuses is package state, and the wrapper hides why](playbooks/0009-uninstall-failure-is-package-state.md) — read the manager's operation log, reproduce on a copy, withdraw patch declarations before the package
9. [A plugin is "installed"; whether it is usable is a separate load + config + restart chain](playbooks/0010-verify-a-plugin-we-can-call-its-tool.md) — install gives an empty config; supply a typed overlay, restart, and verify by calling a registered tool
10. [Terminal-only output is not the output](playbooks/0011-terminal-only-output-is-not-the-output.md) — `Notice:`/progress lines exist only on a tty; a pipe silently drops them, so a captured run that looks clean may be blind
11. [Bisect the launch chain; a silent 1.3 s exit is the second-instance path](playbooks/0012-bisect-the-launch-chain.md) — menu click → cached app object → `Exec=` → integrator GUI → single-instance lock; each link fails silently, so match the fingerprint before changing anything
12. [A menu click that "does nothing" is a lifetime question](playbooks/0013-menu-click-noop-is-a-lifetime-question.md) — prove the entry loaded, then prove the process started *and stayed*; a self-relaunch can be killed by the app scope, and a cached `ShellApp` makes a correct fix look broken
13. [A frozen progress counter is a claim about the UI, not the engine](playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md) — find the engine's own counter (`n_gen`, `tg`), reconcile the shown number by delta arithmetic, check `finish_reason`, and only then blame the backend
14. [A stale watchdog that times out on liveness is a claim about timing, not progress](playbooks/0015-stale-watchdog-is-a-timing-claim.md) — heartbeat on + output flat means a wedged backend; reconcile the process's own output counter with the signal the watchdog watches, and reclaim on actual output (with a wall-clock cap for "flows but never ends")
15. [A version you must be able to undo: read the install model before upgrading](playbooks/0016-version-you-can-undo.md) — versioned package names mean a *co-install*; make `0 to remove` a gate and record the `update-alternatives` map as the rollback point
16. [Never compare two versions with one measurement each](playbooks/0017-version-comparison-needs-pairing.md) — warm up, interleave A/B/B/A, cool down between blocks, and state the resolution; the second measurement is always slower
17. [The boot default is a pointer to a menuentry, and `apt autoremove` will delete the fallback you did not shield](playbooks/0018-boot-default-is-a-pointer.md) — check flavor before version, move `GRUB_DEFAULT`, `apt-mark manual` the fallback lineage, and verify from the booted kernel itself
18. [A response timeout measures queue position, not model speed](playbooks/0019-a-timeout-measures-queue-position.md) — measure cold TTFT alone, the same payload warm (prompt cache), then two at once (2× = one request slot); pick the value as `TTFT × overlap you accept`, then account for the retry budget that turns slowness into permanent refusal
19. [The terminal you see is owned by the host service, not the plugin that draws it](playbooks/0020-the-terminal-is-owned-by-the-host-service.md) — find who spawns the PTY (`webTerminals` / `terminal-controller`), patch the shell at the top of the decision chain (service `Config.shell`), watch the localStorage path preference, and verify from the spawned process path
20. [A required plugin that will not activate is usually its data file](playbooks/0021-a-required-plugin-fails-on-its-data-file.md) — read the (path, code, line, column), map the column to the document section, recover the key name with the same parser without printing values, fix by deletion, and verify with a fresh start; a version change cannot touch user data
21. [An install-script warning is a claim about scripts, not artifacts](playbooks/0022-an-install-script-warning-is-not-a-missing-artifact.md) — find the shipped artifact (per-platform optional dependency, `prebuilds/`), prove it loads with a real call, and remember `npm install -g` needs a package name while `--allow-scripts` is a one-shot list
22. [The always-on mode is an installed service, not a checkbox](playbooks/0023-always-on-is-an-installed-service.md) — "x closes everything" + "no auto-start" is one missing component (no registered service / tray); install `--install-service` and verify from `sc.exe qc`, not the window
23. [Import a deck into a ppt-master pack via `dsh-ppt-master-wrapper` (DSH route): the template is two artifacts, and each consumer has its own slot](playbooks/0024-dsh-import-a-deck-into-a-ppt-master-pack.md) — count SVG slots and PPTX pages separately, land the contract in the round-trip workspace, register per consumer, keep `/N` honest with patch + add-in + sync tool, retire by de-registering, and verify both remotes' head SHAs

## Docs (product-specific reference)

Not method — facts that took a while to establish, so they live in one place:

- [What the agent sandbox blocks](docs/dsh-sandbox.md) — a measured table of what is denied and
  what still works, plus the four workarounds that survived
- [Where the DSH diagnostics are](docs/dsh-diagnostics.md) — the four log/flag sources, what each
  can and cannot answer, and which claims are version-dependent
- [Methodology](docs/methodology.md) — the reasoning order the cases follow
- [Handover: a second `gfx1151` machine](docs/rocm-395-handover.md) — the do-this-on-the-other-box
  checklist (platform check → install → verify → baseline → PyTorch → evidence/PR), plus what must not
  be copied between 395 and 495
- [ROCm on `gfx1151`](docs/rocm-gfx1151.md) — packaging model (`/opt/rocm/core-<x.y>`), kernel and GTT
  requirements, 10.1 vs 10.2 facts, why the torch venv carries its own ROCm, container-only vLLM,
  and the measured bandwidth/step baselines

## Layout

```
cases/      one directory per investigated symptom (evidence + write-up)
playbooks/  reusable method, one file per idea
tools/      probes, chosen by question - start at tools/README.md
docs/       facts and methodology
handoff.md  current state: what is settled, what is still open
SANITIZE.md rules applied before publishing anything here
```

## Contributing / reusing

Most of these probes are single-file and dependency-free by design; copy them, adapt the
paths, and keep the interpretation rules intact — the interpretation is the part that took
the longest to get right.

If you find a case where a rule below fails, that is the most interesting kind of issue:
open one with the raw numbers rather than the conclusion.
