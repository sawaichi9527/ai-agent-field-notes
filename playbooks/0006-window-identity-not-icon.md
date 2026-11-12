# Playbook 0006 — A wrong icon is usually identity, but the asset can still be the bug

**Applies to:** any GUI app on Linux that ships a `.desktop` entry — Electron, GTK, Qt, AppImage.
**Answers:** why does this window show a generic icon, or open as a second dock entry instead of
grouping with its launcher?

## The two rules that decide everything

The shell does not look at your PNG. It looks up **which application this window belongs to**:

1. desktop id == window `app_id` + `.desktop`
2. `StartupWMClass` == window `app_id` (case-insensitive)

Anything else — icon path, `Name`, `Categories` — is irrelevant to matching. Miss both rules and
the shell falls back to `application-x-executable`, which in Yaru is a grey gear.

## Identity is necessary, not sufficient

A match is not the end of the lookup. Two more things can produce a gear with a perfect `app_id`:

1. **The entry is structurally invalid.** A `.desktop` file missing `Type`/`Exec`/`Name` is silently
   dropped by GLib: it never appears in `Gio.AppInfo.get_all()`, so both rules miss. The cause is
   not a naming mismatch, and renaming cannot fix it. Check the file itself:

   ```bash
   desktop-file-validate ~/.local/share/applications/<entry>.desktop
   gjs -c 'const {GioUnix}=imports.gi; print(GioUnix.DesktopAppInfo.new_from_filename("…/<entry>.desktop"))'
   ```

   `null` plus a validator error means "rebuild the entry", not "rename the entry".

2. **The winning entry's `Icon=` does not resolve.** `Icon=` is a name (or a path), not an image.
   A generator can point it at `appimagekit_<id>_<name>` and then fail to extract the PNG. Replay
   the icon lookup for **every** matching entry:

   ```bash
   tools/linux/probe-desktop-match.sh <app-id> <executable> [<entry>.desktop]
   ```

   The probe checks `GtkIconTheme.lookup_icon()` at 16–512 px (at least one hit in 32–512 is
   required), reports a name that is "registered" but has no standard sizes, and flags hidden
   entries.

Also: **several entries can match**. `NoDisplay=true` removes an entry from menus; it does not
remove it from window matching. If a duplicate must stay on disk (a generator owns it), **remove
`StartupWMClass` from the hidden copy** and keep it only on the visible entry; otherwise the shell
can bind the window to the hidden entry. Patching the hidden copy's icon is a fallback, not the fix.

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
  can break rule 1 even if the bundle's file name was correct;
- a real update can write the entry **more than once** (AppImageLauncher schedules the change,
  writes the entry, then re-writes it during its deferred integration); an idempotent guard
  converges over several passes, a one-shot fix does not.

So: fix identity, and if a generator owns the file, guard it.

## The shell caches the command line

Changing `Exec=` in a `.desktop` file does **not** update a running GNOME Shell's `ShellApp`
command line. A menu click can keep launching the old path while a fresh `Gio` process reads the
new one — and double-clicking the AppImage still works because it bypasses the cached entry.

```console
$ gjs -c 'const {GioUnix}=imports.gi; const a=GioUnix.DesktopAppInfo.new("eyeshell.desktop"); print(a.get_commandline())'
env APPIMAGELAUNCHER_DISABLE=1 "…/eyeShell-0.1.9-x86_64.AppImage"
$ journalctl --user --since today | grep 'No such file'
… eyeshell.desktop[…]: env: '…/eyeShell-0.1.8…AppImage': No such file or directory
```

The entry on disk is right; the session is stale. Log out/in (or reboot) on Wayland — a shell
restart is not available — or create a new desktop ID to force a fresh app object.

## Rules

1. **Measure `app_id` before touching the icon.** The asset is rarely the bug — but check it after
   identity: a matched entry can still point at a name that was never installed.
2. **Two mismatches can mask each other.** Fixing the file name hides a wrong `StartupWMClass`
   until the next regeneration — and vice versa. Fix both, or fix the one the generator keeps.
3. **Never treat a hand edit as the whole fix** when a tool regenerates the file. Either patch the
   source (upstream bundle) or add an idempotent guard (path unit / inotify).
4. **Verify with the shell's own lookup, not by eye.** GIO reproduces rules 1 and 2, and
   `desktop-file-validate` proves the file is loadable at all.
5. **Prove the guard by faking the regression.** Write the broken file back, wait one cycle, assert
   it is corrected — otherwise a silently-broken guard looks exactly like the original bug.
6. **Dedupe, but do not rely on hiding.** Two entries with the same `StartupWMClass` can both match
   the window; `NoDisplay=true` only removes one from the menu. Remove `StartupWMClass` from the
   hidden duplicate so only the visible entry matches.
7. **Check the pre-fix state.** A probe that returns 0 on the broken state is not a check.
   Reconstruct the old entry in an isolated `XDG_DATA_HOME` and assert the probe fails on it.
8. **A file edit is not a session refresh.** After changing `Exec=`/`Icon=`, log out/in or reboot
   (or use a new desktop ID); otherwise the menu can keep running the old command line.

## Worked examples

- [cases/2026-11-02-appimage-dock-gear-linux](../cases/2026-11-02-appimage-dock-gear-linux/) —
  gear on the dock with Gear Lever 4.6.2: two independent identity faults, and a systemd path-unit
  guard that normalises the entry in under 5 s after a simulated rewrite.
- [cases/2026-11-02-appimage-desktop-structural-repair](../cases/2026-11-02-appimage-desktop-structural-repair/) —
  AppImageLauncher 3.0.0-beta-2, two apps: a structurally invalid entry that both rules skip, and a
  second entry matching the same `app_id` whose `Icon=` was never extracted. The follow-up (eyeShell
  0.1.9) added the hidden-duplicate `StartupWMClass` rule and the stale `ShellApp` command-cache
  trap; a reboot confirmed the menu and dock afterwards.
