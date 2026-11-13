# Case: a menu click that does nothing — three independent layers between the icon and the window

**Tool:** Token Monitor 0.91.0 (Electron AppImage), AppImageLauncher 3.0.0-beta-2 (git `96cb937`) ·
**OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-13
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)
**Probe:** [`tools/linux/probe-appimage-launch-chain.sh`](../../tools/linux/probe-appimage-launch-chain.sh)

## Symptom

The user reported, after several Token Monitor self-updates plus an OS reboot:

- left-clicking `Token Monitor` in the applications menu does nothing — no window, no error;
- double-clicking `~/Applications/Token-Monitor-*.AppImage` in the file manager starts it normally;
- closing the window does not stop the app: it keeps running as a background widget, and further
  clicks stay invisible.

An earlier case in this repo
([`2026-11-02-appimage-desktop-structural-repair/`](../2026-11-02-appimage-desktop-structural-repair/))
already established that the entry on disk can be correct while the running GNOME Shell still
executes the old command. That was only **one** of the three layers here.

## Root cause — three layers, each able to fail silently

| # | Layer | What breaks | Signature |
|---|---|---|---|
| 1 | integrator middle-man | AppImageLauncher's binfmt interpreter hands the AppImage to its **Qt GUI** (`/usr/bin/AppImageLauncher`). A launch through that path does **not** deliver the app's `second-instance` event, so a click while the app is alive cannot restore its window | click runs ~1.2 s, exits 0, no window; journal shows only the Qt banner |
| 2 | app-level lock | Chromium's `SingletonLock` / `SingletonSocket` survive a dirty exit or a reboot-while-running (`/tmp` wiped), so a cold start believes another instance exists, fails to notify it, and quits | 1.07–1.29 s CPU / 1.18–1.39 s wall, ~140 MB peak, **exit 0**, empty stderr |
| 3 | shell cache | the running GNOME Shell keeps the pre-edit `ShellApp` command for the session; a fresh `Gio`/`gtk-launch` reads the edited `Exec`, the menu keeps running the old one | menu click logs the **old** command while `gtk-launch` logs the new wrapper |

Layers 1 and 2 are independent: fixing the lock still leaves "already running → window never comes
back"; fixing the middle-man still leaves the first cold start after a reboot dead. Layer 3 hides the
first two from the user: the menu can keep executing a command that was correct at login and wrong
five minutes later.

## Evidence

Direct execution of the app's own binary while the widget window was hidden (measured outside the
agent sandbox):

```console
$ xwininfo -id 0x1200003 | grep 'Map State'
  Map State: IsUnMapped            # user closed the window, process kept running

$ /tmp/.mount_Token-*/token-monitor --no-sandbox --ozone-platform=x11 &
$ xwininfo -id 0x1200003 | grep 'Map State'
  Map State: IsViewable            # second-instance -> focusExistingWindow() works
```

The same click through the integrator, with the app already running:

```console
$ journalctl --user --since -30s | grep -i token
… appimagekit_<id>-Token_Monitor.desktop[73216]: Warning: Ignoring XDG_SESSION_TYPE=wayland …
… Started app-gnome-appimagekit_<id>-Token_Monitor-73216.scope
… …-73216.scope: Consumed 1.275s CPU time over 1.363s wall clock, 140.8M memory peak.
```

No window, no stderr, exit 0 — the "second instance" path, not a crash.

The app implements the handler, so the bug is not in the app:

```js
app.on('second-instance', focusExistingWindow);   // resources/app.asar
```

A wrapper that sets `APPIMAGELAUNCHER_DISABLE=1` and execs the AppImage makes the interpreter skip
the GUI and run the app directly; with a synthetic stale lock planted, the menu-equivalent launch
then works first try:

```console
$ gio launch …/appimagekit_<id>-Token_Monitor.desktop
[appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly
$ ps -o cmd -p <new pid>
/tmp/.mount_Token-*/token-monitor --no-sandbox --ozone-platform=x11
```

## Fix

1. **Launcher wrapper** `~/.local/bin/token-monitor`:
   - picks the newest `~/Applications/Token-Monitor-*.AppImage` (the integrator renames the file on
     every update, so a fixed path in `Exec=` expires);
   - clears `SingletonLock` / `SingletonSocket` / `SingletonCookie` when the holder is dead or the
     socket is missing;
   - exports `APPIMAGELAUNCHER_DISABLE=1`, then `exec`s the AppImage with the original arguments.
2. **Desktop entry** `Exec=` / `TryExec=` point at the wrapper (the `Delete this AppImage` action is
   left on the integrator's `remove` helper).
3. **Stop the integrator from rewriting the entry**: `enable_daemon = false` and
   `systemctl --user disable --now appimagelauncherd` — it re-integrates at login and would undo (2).
4. **Self-healing**: a systemd user `.path` unit plus a login oneshot run a repair script that
   re-points `Exec=` at the wrapper and clears stale locks. Verified by rewriting `Exec=` by hand and
   watching it revert within 3 s.
5. **One session reload** (logout/login or reboot): GNOME Shell cannot reload `ShellApp` commands on
   Wayland. After the reboot the journal showed the wrapper being executed by `gnome-shell` and the
   window mapped; the user confirmed the menu click works.

## Verification

| Check | Before | After |
|---|---|---|
| menu click with no instance running | 1.36 s, exit 0, no window | wrapper executed, app starts, window `IsViewable` |
| menu click with the app running, window hidden | no window | window returns (`IsUnMapped` → `IsViewable`) |
| stale lock planted by hand, then launch | silent exit | lock cleared, app starts first try |
| journal identifier for a menu click | `Warning: Ignoring XDG_SESSION_TYPE…` only (GUI path) | `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly` |
| `Exec=` rewritten by hand + `touch` the dir | — | reverted to the wrapper in ≤3 s |
| reboot, then user click | broken since the update | app launches; user-confirmed |

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **"Click does nothing" is a chain, not a component** | menu → shell cache → `Exec` → integrator interpreter → integrator GUI → AppImage runtime → app. Bisect by running each stage by hand; the stage where behaviour changes owns the bug |
| **Exit 0 + CPU≈wall ≈1.3 s + no window + empty stderr is the single-instance path** | it looks like a crash and is not; check `SingletonLock`/`SingletonSocket` before touching the launcher |
| **Cold start and "show the existing window" are different contracts** | both must be tested; each has its own failure mode, and each passed while the other failed here |
| **An agent-started instance contaminates the experiment** | the agent's own test launch holds the lock, so every later user click silently exits and "reproduces" the bug. Record `ps` from outside the sandbox before judging a click |
| **A wrapper is the stable seam** | it survives integrator rewrites and version-renamed AppImages, and it is the only place that can set the environment the interpreter reads (`APPIMAGELAUNCHER_DISABLE`) |
| **A self-healing file is useless while a daemon rewrites it** | the integrator re-integrated at login; the path unit and the daemon then race. Disable the daemon, then heal |
| **Integrator "integration" is a behaviour change, not a convenience** | the GUI hand-off changed second-instance semantics; `APPIMAGELAUNCHER_DISABLE=1` buys back the plain `exec` path |
| **Wayland has no shell-only reload** | after any `Exec=` change the session must be reloaded; a "verified" fix that was never reloaded is unverified |

## Open

- AppImageLauncher 3.0.0-beta-2 is unchanged upstream; everything above is a local wrapper, so a
  fresh machine needs the same four steps (probe, wrapper, entry, daemon off, session reload).
- `--no-sandbox` is kept in `Exec=` but is **not** required — measured both with and without; it was
  inherited from the generated entry.
- With `appimagelauncherd` disabled, newly downloaded AppImages are no longer integrated
  automatically; they need a one-off `AppImageLauncher <file>`.
- The shell-cache layer is not solvable from the app side. `probe-appimage-launch-chain.sh` prints
  the `gtk-launch`-works-but-menu-does-not check that identifies it.
