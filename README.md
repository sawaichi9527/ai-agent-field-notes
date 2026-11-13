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
| Startup takes 20+ s, window blank the whole time | DSH | Windows 10 | CPU-bound module loading; cost scales with plugin bundle count | [case](cases/2026-10-30-dsh-slow-startup-win/) · [playbook](playbooks/0001-measure-cpu-vs-wall.md) |
| A console window flashes every ~4 s and typing in the browser loses characters | DSH + `@goodandready/dsh-gitea` | Windows 10 | `git rev-parse` spawned from a 4 s status poll without `windowsHide`; **returns after every plugin update** (re-confirmed on 0.7.41) | [case](cases/2026-10-30-dsh-console-flash-win/) · [playbook](playbooks/0003-catch-short-lived-windows.md) |
| A plugin is installed but never shows up in the marketplace's "installed" list | DSH + `@maxhsu/dsh-forge` | Windows | host-only plugin has no UI panel; the panel also labels it by entry id, not package name | [case](cases/2026-09-18-dsh-plugin-not-showing/) |
| Removing a plugin fails with "exit code 1", and it stays half-removed — gone from the list, still installed, retries keep failing | DSH + `dsh-multi-lang-ui` | Ubuntu 24.04.5 | a stale pnpm `patchedDependencies` entry lost its only dependent (`ERR_PNPM_UNUSED_PATCH`); the manager commits the bundle deselection **before** pnpm runs, so the failure leaves a half-applied removal | [case](cases/2026-11-12-dsh-plugin-remove-unused-patch/) · [playbook](playbooks/0009-uninstall-failure-is-package-state.md) |
| After installing `@goodandready/dsh-gitea`, every `gitea_*` tool says "Configure the Gitea instance URL in Settings"; a config edit then made the tools disappear | DSH + `@goodandready/dsh-gitea` 0.7.44 | Windows | bundle installs the entry with an empty `config: {}`; the working config (baseUrl / tokenEnv / defaultOwner / defaultRepo) must be supplied as a profile overlay, `defaultOwner` must be a **quoted string**, and a config that failed validation needs a full restart to load | [case](cases/2026-11-13-dsh-gitea-config-file-windows/) · [playbook](playbooks/0010-verify-a-plugin-we-can-call-its-tool.md) |
| `apt update` ends with three `Notice:` lines every run: two `doesn't support architecture 'i386'`, one `Missing Signed-By` | apt 3.2.1 | Ubuntu 26.04.1 LTS | `i386` is a foreign architecture (kept for Steam/Wine) but those two third-party repos index **amd64 only**; and `apt modernize-sources` rewrote the NVIDIA entry with an **empty** `Signed-By` while its key stayed in `trusted.gpg.d` | [case](cases/2026-11-13-apt-update-three-notices/) · [playbook](playbooks/0011-terminal-only-output-is-not-the-output.md) |

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

## Docs (product-specific reference)

Not method — facts that took a while to establish, so they live in one place:

- [What the agent sandbox blocks](docs/dsh-sandbox.md) — a measured table of what is denied and
  what still works, plus the four workarounds that survived
- [Where the DSH diagnostics are](docs/dsh-diagnostics.md) — the four log/flag sources, what each
  can and cannot answer, and which claims are version-dependent
- [Methodology](docs/methodology.md) — the reasoning order the cases follow

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
