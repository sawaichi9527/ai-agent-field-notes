# Playbook 0012 — Bisect the launch chain; a silent 1.3 s exit is the second-instance path

**Applies to:** any GUI app started from a menu/dock (`.desktop` entry), especially where an
integrator (AppImageLauncher, Gear Lever, `.deb` wrapper, Flatpak/Snap wrapper) sits between the
entry and the binary — and any Electron/Chromium app that uses `requestSingleInstanceLock()`.
**Answers:** "clicking the icon does nothing", when double-clicking the file works, when the app is
"obviously fine", and when nothing appears in any log.

## The trap

"It doesn't start" is a claim about a **chain of five processes**, and every link fails silently in
its own way:

```
menu click
  └─ shell's cached app object        (GNOME Shell keeps the ShellApp command for the session)
      └─ Exec= + TryExec=              (the file may be edited and correct)
          └─ integrator middle-man      (binfmt interpreter → its GUI, before the app runs)
              └─ runtime (FUSE mount, wrapper script, sandbox)
                  └─ app process        (Chromium single-instance lock decides to die)
```

None of the five prints an error when it fails. Two of them exit **0**. So "no window and no
message" carries almost no information until you know the fingerprints.

## The fingerprints

Measure outside any sandbox (playbook 0002), with `ps` + journal, and compare CPU time against wall
time (playbook 0001):

| Observation | Most likely link |
|---|---|
| no process at all, no journal line | the shell never ran the entry (stale cached command, or `TryExec` invalid) |
| `env: '<old path>': No such file or directory` in the journal | the shell's cached command points at a version that was renamed/removed |
| exit 0, **CPU ≈ wall ≈ 1.2–1.4 s**, RSS ≈ 140 MB, no window | **the single-instance path** — the app started, decided another instance exists, and quit |
| window exists but `Map State: IsUnMapped` | not a start failure; the "show the existing window" contract is broken |
| the app runs for seconds and dies with stderr | a real startup failure — read stderr, this is the easy case |
| Qt/GTK banner from the *integrator*, no app logs | the launch went through the integrator's GUI, not directly to the app |

The third row is the one that wastes days: it looks like a crash, and it is a **successful** start of
a process that then yields to an instance that is not there.

## Recipe

1. **Look for a running instance first.** The agent's own test launch contaminates everything after
   it: it holds the lock, so every later click is a second instance and "reproduces" the bug.

   ```bash
   ps -eo pid,etime,rss,cmd | grep -F '/tmp/.mount_' | grep -v grep   # AppImage runtime mounts
   ```

2. **Read the lock.** Chromium/Electron keeps three symlinks in the user-data dir; after a crash or a
   reboot-while-running the socket target is gone and the holder pid is dead:

   ```bash
   ls -l ~/.config/<Product>/Singleton*
   readlink ~/.config/<Product>/SingletonLock      # "<host>-<pid>" -> kill -0 that pid
   readlink ~/.config/<Product>/SingletonSocket    # must be an existing socket, not a removed path
   ```

   A dead holder or a missing socket is the whole explanation for a 1.3 s silent exit.

3. **Bisect the chain by running each stage by hand**, from the outside in:

   ```bash
   gtk-launch <desktop-id>                      # does a fresh GIO read of the entry work?
   $HOME/.local/bin/<wrapper>                   # does the entry's exec target work?
   ~/Applications/<app>.AppImage --no-sandbox   # does the AppImage work?
   /tmp/.mount_<...>/<binary>                   # does the app binary itself work?
   ```

   The first stage that succeeds while the one before it fails owns the bug. In the case that
   produced this playbook, `gtk-launch` worked and the menu did not → shell cache, and
   `.AppImage` worked while the menu's path did not → the integrator GUI.

4. **Check both contracts.** "Cold start" and "already running → show the window" fail
   independently, and fixing one leaves the other broken. Test with the window hidden/closed while
   the process is alive.

5. **Then reload the session.** GNOME Shell cannot reload app commands on Wayland; a fix to `Exec=`
   is unverified until logout/login or reboot.

## The three seams you can actually control

| Seam | What it buys |
|---|---|
| **a wrapper as `Exec=`** | survives integrator rewrites and version-renamed files; the only place to set environment the interpreter reads (`APPIMAGELAUNCHER_DISABLE=1`) |
| **clearing a stale lock before `exec`** | turns the silent 1.3 s exit back into a cold start; must check holder-alive *and* socket-exists |
| **turning off the writer** | a path-unit that repairs a file is useless if a daemon rewrites it at login — disable the daemon, then heal |

## Sanity rules

- An exit code of 0 is not evidence of success when the app is single-instance; it is evidence that
  the app reached the lock.
- `No such file or directory` from `env:` means the *shell's memory* is stale, not the disk.
- A "repair" that never observed a failing input proves nothing; plant a stale lock and re-run.
- Never classify a GUI launch from inside the agent sandbox — the PID namespace hides the host and
  AppArmor can make `exec` fail with a permission error that looks like the user's bug.

## Generalizes to

- Flatpak/Snap wrappers that exec a helper before the app: same chain, same silent failures.
- Any Electron app whose window "won't come back" after being closed: check whether the integrator's
  launch path delivers `second-instance` at all.
- Windows has the analogue: a shortcut's cached target vs the exe on disk, and single-instance
  mutexes that survive a taskkill — same bisect, different probes.

## Related

- [Playbook 0006](0006-window-identity-not-icon.md) — the icon side of `.desktop` entries.
- [Playbook 0002](0002-sandbox-measurements-lie.md) — why the sandbox's `Permission denied` was not
  the user's bug.
- Probe: [`tools/linux/probe-appimage-launch-chain.sh`](../tools/linux/probe-appimage-launch-chain.sh)
  — prints all five stages in one pass.
- Case: [`cases/2026-11-13-appimage-menu-click-launch-chain/`](../cases/2026-11-13-appimage-menu-click-launch-chain/)
- [Playbook 0013](0013-menu-click-noop-is-a-lifetime-question.md) — the same symptom when the process
  starts but does not stay (a self-relaunch child killed by GNOME's app scope)
