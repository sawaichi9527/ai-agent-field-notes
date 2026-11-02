# Case: the dock shows a gear icon for an AppImage whose icon is fine

**Tool:** Token Monitor 0.84.0 (Electron AppImage) + Gear Lever 4.6.2 · **OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-02
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact measurement commands)

## Symptom

Launching the AppImage works, the window title is "Token Monitor", but the dock entry is the generic
Yaru **gear** (`application-x-executable`). The app's own icon — a 1024×1024 blue Σ — is present and
valid.

A hand-made `token-monitor.desktop` fixed this on 0.69.0. After updating to 0.84.0 the gear came
back, which is the interesting part: the *fix* did not survive the update.

## Root cause

GNOME resolves a window to a `.desktop` entry by exactly two rules:

1. desktop id == window `app_id` + `.desktop`
2. `StartupWMClass` == window `app_id` (case-insensitive)

Measured identity of the real window:

```
WM_CLASS(STRING) = "token-monitor", "token-monitor"
_NET_WM_NAME(UTF8_STRING) = "Token Monitor"
```

Installed entry at the time:

| Field | Value | vs. `app_id` |
|---|---|---|
| file name | `token_monitor.desktop` | underscores are not hyphens → **miss** |
| `StartupWMClass` | `Token Monitor` | space + capitals → **miss** |

Both rules miss, so the shell falls back to `application-x-executable`: the gear.

Two independent faults, either of which alone would have hidden the bug:

- the AppImage **ships** a wrong `StartupWMClass` in its bundled `.desktop` (still wrong in 0.84.0);
- Gear Lever **rebuilds** the entry on every (re)integration, deriving the file name from `Name`
  and copying `StartupWMClass` verbatim.

So a one-off rename fixes it until the next update, and then reverts.

## Fix

```ini
# ~/.local/share/applications/token-monitor.desktop
[Desktop Entry]
Type=Application
Name=Token Monitor
Icon=/home/<you>/Applications/.icons/token_monitor
TryExec=/home/<you>/Applications/token_monitor.appimage
Exec=/home/<you>/Applications/token_monitor.appimage --no-sandbox %U
Terminal=false
StartupWMClass=token-monitor
```

Plus a guard, because the generator will overwrite the file again: a systemd **user path unit**
watching `~/.local/share/applications`, running a script that

- renames any entry whose `Exec` points at the AppImage to `token-monitor.desktop`,
- forces `StartupWMClass=token-monitor`,
- removes duplicate entries,
- writes only when something differs (so it cannot loop on its own output).

## Verification

Replay the shell's lookup with [`tools/linux/probe-desktop-match.sh`](../../tools/linux/probe-desktop-match.sh):

```bash
probe-desktop-match.sh token-monitor /path/to/token_monitor.appimage
```

| Check | Result |
|---|---|
| GIO rule 1: `DesktopAppInfo.new("token-monitor.desktop")` | FOUND |
| GIO rule 2: `startup_wm_class` | `token-monitor` |
| entries for this app | 1 (no duplicate menu item) |
| guard vs. simulated Gear Lever rewrite | corrected in **< 5 s** |
| guard vs. two entries | duplicate removed, canonical kept |

Not verified: a screenshot of the dock. The check above exercises the same lookup the shell uses,
so a correct resolution is the mechanism by which the icon appears. Launch the app to confirm
visually.

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A wrong icon is an identity mismatch, never an asset bug** | check `app_id` against the two rules before touching any PNG |
| **Generators own the file, you do not** | integration tools (Gear Lever, AppImageLauncher, appimaged) rebuild `.desktop` from the app's own copy on every update; hand edits are temporary |
| **Two faults can mask each other** | here: wrong `StartupWMClass` *and* wrong file name; fixing either hides the other until the next update |
| **Verify with the shell's own lookup, not by eye** | GIO reproduces rule 1/2 without a GUI, and can be scripted as a regression check |
| **A guard beats a repair** | a path-unit + idempotent script turns "fix after every update" into "never again" |

## Open

- **Upstream:** the bundled `.desktop` says `StartupWMClass=Token Monitor` while the app id is
  `token-monitor`; its own file name is already `token-monitor.desktop`, so correcting the key (or
  dropping it) would fix every user. Not filed yet.
- Gear Lever could set `StartupWMClass` from the observed `WM_CLASS` instead of copying the bundle.
- Re-check after each AppImage update; the guard should make this a non-event, but a silent guard
  failure would look exactly like the original bug.
