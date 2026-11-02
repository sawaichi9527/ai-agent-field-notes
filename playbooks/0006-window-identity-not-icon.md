# Playbook 0006 — A wrong icon is an identity mismatch, not an asset bug

**Applies to:** any GUI app on Linux that ships a `.desktop` entry — Electron, GTK, Qt, AppImage.
**Answers:** why does this window show a generic icon, or open as a second dock entry instead of
grouping with its launcher?

## The two rules that decide everything

The shell does not look at your PNG. It looks up **which application this window belongs to**:

1. desktop id == window `app_id` + `.desktop`
2. `StartupWMClass` == window `app_id` (case-insensitive)

Anything else — icon path, `Name`, `Categories` — is irrelevant to matching. Miss both rules and
the shell falls back to `application-x-executable`, which in Yaru is a grey gear.

## Measure the window identity first

```bash
xprop -id <window-id> WM_CLASS _NET_WM_NAME
# WM_CLASS(STRING) = "token-monitor", "token-monitor"
```

The **second** string is the app_id. On Wayland there is no equivalent read without shell
introspection; Electron/GTK derive it from the executable or `app_id` API, and it is usually the
same string, but say so in the write-up instead of assuming it silently.

Then check the lookup the shell performs, without a GUI:

```bash
tools/linux/probe-desktop-match.sh token-monitor
```

## The generator trap

Integration tools (**Gear Lever**, AppImageLauncher, appimaged) do not just install your app — they
**rebuild** `~/.local/share/applications/*.desktop` from the `.desktop` file *inside* the AppImage,
on every install and every update. Consequences:

- hand-editing that file is a fix with an expiry date;
- a wrong key in the bundle propagates to every user of every integration tool;
- the file **name** may be derived from `Name` (`Token Monitor` → `token_monitor.desktop`), which
  can break rule 1 even if the bundle's file name was correct.

So: fix identity, and if a generator owns the file, guard it.

## Rules

1. **Measure `app_id` before touching the icon.** The asset is almost never the bug.
2. **Two mismatches can mask each other.** Fixing the file name hides a wrong `StartupWMClass`
   until the next regeneration — and vice versa. Fix both, or fix the one the generator keeps.
3. **Never treat a hand edit as the whole fix** when a tool regenerates the file. Either patch the
   source (upstream bundle) or add an idempotent guard (path unit / inotify).
4. **Verify with the shell's own lookup, not by eye.** GIO reproduces rules 1 and 2, and turns the
   check into a scriptable regression test.
5. **Prove the guard by faking the regression.** Write the broken file back, wait one cycle, assert
   it is corrected — otherwise a silently-broken guard looks exactly like the original bug.
6. **Dedupe.** If both names exist, the menu shows two "Token Monitor" entries, which is a second
   bug introduced by the fix.

## Worked example

[cases/2026-11-02-appimage-dock-gear-linux](../cases/2026-11-02-appimage-dock-gear-linux/) —
gear on the dock, two independent identity faults, and a systemd path-unit guard that normalises
the entry in under 5 s after a simulated Gear Lever rewrite.
