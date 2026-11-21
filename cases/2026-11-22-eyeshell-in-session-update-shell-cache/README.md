# Case: an in-session AppImage update makes the menu click a file that no longer exists

**Tool:** eyeShell 0.2.2 (jpackage/Compose AppImage) + AppImageLauncher 3.0.0-beta-2 (git `96cb937`) ·
**OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-22
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)
**Same symptom, earlier round:** [`2026-11-02-appimage-desktop-structural-repair/`](../2026-11-02-appimage-desktop-structural-repair/)
§6.6 — eyeShell 0.1.9, fixed by a reboot

## Symptom

- clicking `eyeShell` in the applications menu does nothing — no window, no error;
- double-clicking `~/Applications/eyeShell-0.2.2-x86_64.AppImage` starts it normally;
- the update to 0.2.2 happened **inside the same login session** (logged in 20:30, updated 01:29).

## Root cause

One layer this time — GNOME Shell's cached `ShellApp` command — but the reason it can exist is the
entry's shape: `Exec=` carried the version number.

At login the visible entry ran `env APPIMAGELAUNCHER_DISABLE=1 "…/eyeShell-0.1.9-x86_64.AppImage"`.
The integrator unintegrated 0.1.9 at 01:28:46 and integrated 0.2.2 at 01:29:43; the repair guard
re-pointed the file at 01:29:46 (disk correct, `desktop-file-validate` passes, a fresh `Gio` read
returns 0.2.2). The click at 01:30:58 still ran the cached 0.1.9 string:

```console
$ journalctl --user --since '2026-11-22 01:28' --no-pager | grep eyeshell.desktop
… eyeshell.desktop[62373]: env: '/home/…/Applications/eyeShell-0.1.9-x86_64.AppImage': No such file or directory
… eyeshell.desktop[62373]: env: use -[v]S to pass options in shebang lines
```

`env` cannot exec a missing file, so the click ends there: exit, no app, no window, one journal line.
The disk was right for 72 s before the click and stayed right; only the session's memory was old.

## Evidence

| Observation | Meaning |
|---|---|
| click leaves a single `env:` line — no `app-gnome-*.scope` for that pid, no app log | the shell never got past `env`; nothing was started |
| fresh `Gio` read: `env APPIMAGELAUNCHER_DISABLE=1 "…/eyeShell-0.2.2-x86_64.AppImage"` | disk is current → not an entry bug, not an icon bug |
| double-click 01:29:58 → `appimagelauncher.desktop` Qt warning, 01:29:59 app log, window closed 01:30:10 | the file-manager path executes the file it was given and bypasses the cache |
| guard at 01:29:01 and 01:29:22: `eyeShell: no AppImage found; skipping entry repair` | the daemon writes `*.AppImage.part` before the rename; for ~45 s the only `*.AppImage` on disk was the outgoing 0.1.9 |
| after reboot, click 01:52:41: `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly`, `app-gnome-eyeshell-7893.scope`, app log `eyeShell=0.2.2` | the wrapper was executed by gnome-shell; cold start and menu path both fine |
| `~/.local/bin/eyeshell --appimage-version` before the reboot | proves the wrapper resolves and execs the AppImage without opening a window |

## Fix

1. **Wrapper** `~/.local/bin/eyeshell`: picks the newest `~/Applications/eyeShell-*.AppImage` at run
   time (skips `.part`/empty/non-executable), exports `APPIMAGELAUNCHER_DISABLE=1`, `exec`s.
2. **Visible entry** `eyeshell.desktop`: `Exec=/home/<you>/.local/bin/eyeshell` — version-free.
3. **Guard** `appimage-desktop-fix.py` learns `custom_exec`, so it never rewrites `Exec=` back to a
   versioned path; if the wrapper disappears it falls back to `env … "<AppImage>"`.
4. **One session reload** — the old cache cannot be dropped on Wayland otherwise.

## Verification

| Check | Before | After |
|---|---|---|
| menu click after an in-session update | `env: '…0.1.9…': No such file or directory`, no window | wrapper executed by gnome-shell, app starts (user-confirmed after reboot) |
| `Exec=` content | `env APPIMAGELAUNCHER_DISABLE=1 "…/eyeShell-0.2.2-x86_64.AppImage"` | `~/.local/bin/eyeshell` |
| journal marker for a menu click | none (died in `env`) | `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly` |
| guard second run | — | `no changes needed` (idempotent: fixed Exec is not re-expanded) |
| fake-HOME update simulation | — | wrapper picks 0.2.3 over 0.2.2, ignores `*.part`; missing wrapper falls back to the AppImage path |

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A reboot-only fix expires at the next update** | the shell cache is keyed by desktop id (stable) and holds the `Exec=` string (version-dependent). Fix the value, not just the session |
| **`Exec=` containing a version number is a cache-expiry timer** | every integrator update renames the file; the session keeps the old string and the failure returns hours later |
| **`env: '<path>': No such file or directory` is the shell-cache fingerprint** | nothing in the app is reached, so no app log, no crash, no stderr beyond that line |
| **"Double-click works" says nothing about the entry** | the file manager runs the clicked file; it never consults the cached command |
| **A guard can be right and still be silent for a minute** | during the download the only file matching the glob is the outgoing version; the entry is briefly stale by design |

## Open

- Token Monitor still puts `0.95.1_<hash>` in `Exec=` (`--no-sandbox --ozone-platform=x11`); the same
  in-session-update break is still possible there. The wrapper pattern has not been applied to it.
- AppImageLauncher 3.0.0-beta-2 still fails to extract the eyeShell icon from the jpackage AppDir;
  the guard installs the icons from the repo's assets, so this is cosmetic only.
