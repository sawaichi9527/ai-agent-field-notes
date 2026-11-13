# Case: the app-menu icon "does nothing" — the entry was valid and the app died in 2 s

**Tool:** Token Monitor **0.91.0** (Electron 45.2.1 / Chrome 156 AppImage), AppImageLauncher
3.0.0-beta-2 ·
**OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-13
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands and journal lines)
**Reusable method:** [playbook 0013](../../playbooks/0013-menu-click-noop-is-a-lifetime-question.md)
**Same symptom, other layers:** [`../2026-11-13-appimage-menu-click-launch-chain/`](../2026-11-13-appimage-menu-click-launch-chain/)
(integrator GUI swallowing `second-instance`, stale Chromium `SingletonLock`, shell cache — the
~1.3 s fingerprint; this case is the 2.2–2.8 s, no-app-log, one-mount fingerprint)

## Symptom

Clicking the `Token Monitor` icon in the application grid does nothing. No window, no tray icon, no
error dialog. The entry is visible, has the right icon, and passes every check the previous cases
taught:

```console
$ desktop-file-validate ~/.local/share/applications/appimagekit_<id>-Token_Monitor.desktop
$ gjs -c '…DesktopAppInfo.new("appimagekit_<id>-Token_Monitor.desktop")'
name='Token Monitor' show=True
$ grep '^Exec=' ~/.local/share/applications/appimagekit_<id>-Token_Monitor.desktop
Exec=…/Token-Monitor-0.91.0_<hash>.AppImage --no-sandbox %U
```

0.88.0 and earlier had run normally (its last session lived 5 minutes in the journal); 0.91.0 arrived
via the app's own updater the previous evening and never produced an app log line.

## Root cause — a self-relaunch whose child is killed by the app scope

0.91.0's `launch.js` selects XWayland by re-executing itself:

```js
// src/electron/linuxDisplayServer.js (packaged branch)
const child = spawn(executable, args, { detached: true, stdio: 'ignore' });
child.once('spawn', () => { child.unref(); app.exit(0); });
```

GNOME starts desktop apps in a transient `app-gnome-*.scope`. Scopes default to
`KillMode=control-group`: when the main process exits, systemd stops the scope and kills the rest of
the cgroup. The relaunched child is in a new session but the same cgroup, so it dies before it can
mount the AppImage or show a window. Its stdio is `'ignore'`, so its failure never reaches the
journal.

The click therefore *does* start something — it just cannot survive:

| Observation | Value |
|---|---|
| scope starts on click | `Started app-gnome-…-Token_Monitor-<pid>.scope` |
| scope lifetime | **2.2–2.8 s**, `Consumed 2.1–2.3 s CPU` |
| app's own log lines | **none** (earlier versions printed `[collector] Watching …`) |
| `tmp-.mount_*` per attempt | **one** — a two-stage launch needs two |
| window / tray | none |

The only journal line is `Warning: Ignoring XDG_SESSION_TYPE=wayland on Gnome…`, which comes from
AppImageLauncher's Qt binfmt-bypass wrapper, not from the app — it says nothing about the app's
display backend.

## Fix

Give the wrapper the switch it would have re-launched with, so it takes the "already configured"
branch and never forks:

```ini
Exec=/home/<you>/Applications/Token-Monitor-0.91.0_<hash>.AppImage --no-sandbox --ozone-platform=x11 %U
```

The auto-repair guard in the maintenance workspace now emits that flag too; otherwise the systemd
path unit would rewrite `Exec=` back to the relaunching form on the next update.

## Verification

After changing `Exec=` **the running GNOME Shell still launched the cached old command** (the
eyeShell 0.1.9 trap): a click at 23:45 produced the same 2.2 s scope and zero app logs. A reboot
refreshed the `ShellApp`; the next click produced:

```console
23:48:28  Warning: Ignoring XDG_SESSION_TYPE=wayland on Gnome…   ← launcher wrapper
23:48:32  [collector] Watching ~/.local/share/opencode (native events)
23:48:33  [collector] Watching ~/.dsh/sessions (native events)
23:48:47  Checking for update
23:48:48  Update for version 0.91.0 is not available…
```

and the scope directory was still present at 23:51. User-confirmed: the window opens from the menu.

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A visible, valid entry can still be the wrong suspect** | "entry loads" and "process stays" are different questions; check both before editing anything |
| **A 2 s scope with no app logs is a lifetime signature** | the process started and exited; that is not the same as a launcher that never ran anything |
| **A self-relaunch is visible in the mount count** | a two-stage AppImage launch should mount twice; one mount means stage two never got there |
| **Launcher output is not app output** | AppImageLauncher's Qt wrapper and the Electron app share one journal identifier |
| **Scopes kill the cgroup when the main process exits** | any "fork a helper and exit" pattern is fragile under GNOME's app scopes — including `spawn(..., {detached:true})` |
| **Fix validation needs a fresh shell** | a cached `ShellApp` makes the post-fix click look identical to the bug; reject the result, not the fix |
| **Put the backend switch in `Exec=`** | the app's own re-launch arguments are the most reliable hint for what it needs; keeping them in the guard makes the fix survive updates |

## Open

- systemd's kill of the child is inferred from the scope lifetime, the default `KillMode`, and the
  missing second mount; it was not observed directly (the process is gone by the time the journal
  is read).
- Upstream (`Javis603/token-monitor`): `startWithXWayland` should not send the child's stdio to
  `/dev/null`, and should either keep the parent alive until the child is ready or move the child
  into its own unit; then no desktop-entry workaround would be needed.
- The same guard also handles the eyeShell entry; the 0.91.0 fix is a one-line `Exec` change plus
  the guard update, not an AppImage rebuild.
