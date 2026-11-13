# Playbook 0013 — A menu click that "does nothing" is a lifetime question

**Applies to:** any GUI app started from a desktop entry on Linux (GNOME/KDE), especially
AppImages, self-updating Electron apps, and anything that re-execs itself at startup.
**Answers:** the icon is visible and the `.desktop` entry validates, but clicking it produces no
window. Is the entry wrong, or did the process die?

## Ask four questions, in this order

| # | Question | Measurement |
|---|---|---|
| 1 | Did the entry load? | `desktop-file-validate`; `GioUnix.DesktopAppInfo.new(<id>)` |
| 2 | Did the process start? | journal scope/unit line; `tmp-.mount_*` for AppImages; launcher log |
| 3 | Did it **stay**? | scope still active after N seconds; cgroup has processes; the app's own log line |
| 4 | Whose output am I reading? | the launcher wrapper's line vs the app's line — they share one journal identifier |

Most investigations stop at question 1, because a broken entry and a dead process look the same
from the menu. They are not the same, and the fix is different.

## The trap: a valid entry plus a 2-second process

On GNOME, an application launched from the shell runs in a transient
`app-gnome-<desktop-id>-<pid>.scope` (created through the user systemd manager). Scopes default to
`KillMode=control-group`: when the scope's main process exits, the remaining processes in its
cgroup are killed. A transient unit file confirms it — there is no `KillMode=` override:

```ini
# /run/user/<uid>/systemd/transient/app-gnome-<desktop-id>-<pid>.scope
[Unit]
Description=Application launched by gnome-shell
CollectMode=inactive-or-failed
```

That is harmless for a normal app and fatal for one that **re-execs itself and exits**. A common
Electron pattern is:

```js
const child = spawn(executable, args, { detached: true, stdio: 'ignore' });
child.once('spawn', () => { child.unref(); app.exit(0); });
```

The child is in a new session but **the same cgroup**. The parent exits; systemd stops the scope;
the child is killed before it can create a window. Because `stdio` is `'ignore'`, the child's error
output never reaches the journal.

What you observe instead:

- the entry is valid and points at an existing file;
- the journal shows the scope starting, then a `Consumed … CPU time` line ~2 s later;
- **no application log lines at all** — only whatever the launcher wrapper printed;
- for an AppImage, only **one** `tmp-.mount_*` mount per attempt, although a two-stage launch
  should mount the AppImage once per process.

## The per-application evidence

```bash
# 1. the entry is loadable (a null here is an entry bug, not a lifetime bug)
ENTRY=~/.local/share/applications/appimagekit_<id>-<App>.desktop
desktop-file-validate "$ENTRY"
gjs -c 'const {GioUnix}=imports.gi; const a=GioUnix.DesktopAppInfo.new("'"$(basename "$ENTRY")"'"); print(a && a.get_commandline())'

# 2. did a launch happen, and how long did its scope live?
journalctl --user --since '-10 min' --no-pager | grep -E '<desktop-id>|Token_Monitor'

# 3. is the scope still there?  (name from the journal; also lists the cgroup)
ls -d /sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice/app-gnome-*<App>* 2>/dev/null

# 4. AppImage mount count — one mount for a two-stage launch means the child died early
journalctl --since '-10 min' --no-pager | grep -i 'mount_.*<App>'
```

The cgroup directory is the cheapest liveness check: if the app is running, its scope directory
still exists, even when no window is visible.

## Fixing it

If you do not own the application, give the startup wrapper the argument that makes it take its
"I am already configured" branch. For an Electron app whose wrapper re-launches itself to select
XWayland, that is `--ozone-platform=x11` on the `Exec=` line:

```ini
Exec=/path/AppImage --no-sandbox --ozone-platform=x11 %U
```

The app then runs (under XWayland) in the process the launcher started, so there is no child for
the scope teardown to kill. Keep the flag in whatever generates or repairs the entry — an
auto-updater or a path-unit guard that rewrites `Exec=` will otherwise reintroduce the bug on the
next update.

If you do own the application: do not `app.exit(0)` while the replacement is still in the same
scope; either keep the parent alive, or move the child out with its own transient unit, and never
send its stdio to `/dev/null` during startup.

## Validate only after the shell has reloaded

Editing `Exec=` is not enough to judge a fix. The running GNOME Shell caches the `ShellApp` command
line for the session (see playbook 0006 and the eyeShell 0.1.9 case). The click after the edit runs
the **old** command, so the journal looks exactly like the original failure — same ~2 s scope, no
app logs. That is a false negative, not a failed fix.

- log out/in or reboot, then click again;
- or create a new desktop ID so the shell builds a fresh app object;
- **a test whose output is identical before and after the change has not tested anything.**

## Related

- [Playbook 0012](0012-bisect-the-launch-chain.md) — bisect the five stages of the launch chain and
  match the failure fingerprint before changing anything.
- Case with the same symptom, three other layers:
  [`cases/2026-11-13-appimage-menu-click-launch-chain/`](../cases/2026-11-13-appimage-menu-click-launch-chain/).

## One-line rule

If the entry validates and the app logs nothing, stop editing the entry and measure the process
lifetime: scope start, scope stop, mount count, and whether the app ever printed a line of its own.
