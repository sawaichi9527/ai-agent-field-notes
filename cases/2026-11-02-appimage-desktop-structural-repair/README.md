# Case: an AppImage entry can be structurally invalid, and the matched entry's icon can be missing

**Tool:** Token Monitor 0.84.0 (updated to 0.84.1 during the investigation) and eyeShell 0.1.5
(AppImages, AppImageLauncher 3.0.0-beta-2) ·
**OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-02
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)

## Symptom

Two apps on the same workstation:

- **Token Monitor**: the app grid has no `Token Monitor` entry at all. Launching the AppImage
  shows the generic gear in the dock.
- **eyeShell**: the app grid shows both `eyeShell` and `eyeShell (1)`. The dock shows the gear.

Both apps have valid PNG icons. The first Linux case
([`../2026-11-02-appimage-dock-gear-linux/`](../2026-11-02-appimage-dock-gear-linux/)) explains
the two GNOME identity rules; this case is the second pass, on a machine whose integrator is
**AppImageLauncher** rather than Gear Lever.

## Root cause 1 — the Token Monitor entry was structurally invalid

The file existed, but it was not a desktop entry GLib could load:

```ini
[Desktop Entry]
Name=\s(2)
Icon=token-monitor
StartupWMClass=token-monitor
```

No `Type=`, `Exec=`, `Comment=`, `Categories=`, `TryExec=`, `X-AppImage-Identifier=`.

```console
$ gjs -c 'const {GioUnix}=imports.gi; print(GioUnix.DesktopAppInfo.new_from_filename("…/appimagekit_<id>-Token_Monitor.desktop"))'
null
$ desktop-file-validate …/appimagekit_<id>-Token_Monitor.desktop
error: required key "Type" in group "Desktop Entry" is not present
```

`Gio.AppInfo.get_all()` omits it, so neither identity rule can ever fire. The previous guard only
rewrote `Icon=` / `StartupWMClass=` and reported success; the missing keys were never noticed.

AppImageLauncher's normal rewrite does **not** do this. Reproduced in an isolated `HOME` with
`ail-cli integrate`: on a name conflict it appends ` (1)` to `Name` and preserves every key
(`Name=Token Monitor (0.84.0) (1)`). The `\s(2)` / dropped-keys shape is therefore most likely from
an earlier hand/script edit (the exact event was not recorded); the lesson is that a guard must
validate structure, not just two fields.

## Root cause 2 — eyeShell had two matching entries, and the winning one's icon was never extracted

Two entries shared `StartupWMClass=io-github-…-MainKt`:

| Entry | Name | Icon | Visible |
|---|---|---|---|
| `eyeshell.desktop` (hand-written) | eyeShell | `eyeshell` (16–512 installed) | yes |
| `appimagekit_<id>-eyeShell.desktop` (AL) | eyeShell (1) | `appimagekit_<id>_eyeshell` | yes |

AppImageLauncher's journal for the eyeShell integration:

```console
WARNING: No icons found at "usr/share/icons"
WARNING: Using .DirIcon as default app icon
ERROR: Unable to load image.
ERROR: No icon was generated for: …/eyeShell-0.1.5-x86_64.AppImage
WARNING: Unable to resize the application icon into a 128x128 image: "Unable to load image."
```

The AppDir contains only root `eyeshell.png` + a `.DirIcon` symlink; AL's extractor failed to load
it, so the entry pointed at a name with zero installed sizes. GNOME's
`~/.local/share/gnome-shell/application_state` showed the AL entry with the newer `last-seen`,
consistent with the running window being bound to it; hiding that entry with `NoDisplay=true` did
not fix the dock. `NoDisplay` removes an entry from menus — it does not make an existing window
binding go away.

## Why the old probe said "RESOLVED"

On a reconstructed pre-fix state, `tools/linux/probe-desktop-match.sh` printed:

```text
rule 2 (StartupWMClass == 'io-github-…-MainKt'): appimagekit_<id>-eyeShell.desktop, eyeshell.desktop
verdict: RESOLVED
  - appimagekit_<id>-eyeShell.desktop: icon=appimagekit_<id>_eyeshell …
  - eyeshell.desktop: icon=eyeshell …
```

Exit code 0 — while the first entry's icon had no standard sizes at all. The probe replayed
identity but never asked whether the matched entry's `Icon=` resolved. It has been extended:
it now checks the icon of **every** match, notes hidden duplicates, and validates explicitly
named entries that GLib silently drops. It exits 1 on the reconstructed pre-fix state.

## Fix

A generic idempotent repairer (`appimage-desktop-fix.py`, kept in the maintenance workspace) that:

- rebuilds an entry when `Type`/`Exec`/`Name` are missing — it does not assume the file is valid;
- normalises `Name`, `Icon`, `StartupWMClass`, `Exec`/`TryExec` on **every** entry matching the app;
- keeps one visible entry per app and sets `NoDisplay=true` on duplicates;
- generates 16–512 icons from the newest source and, for AL, also the
  `appimagekit_<id>_<icon>` alias so a cached GIcon or the AL-native name resolves;
- writes only on change, so a systemd path unit cannot loop.

A systemd user path unit watches `~/.local/share/applications` and
`~/.local/share/icons/hicolor`. It repairs the entry within seconds of AL rewriting it.

## Verification

| Check | Before | After |
|---|---|---|
| `Gio` parse: Token Monitor entry | `null` | `name='Token Monitor' show=true` |
| `desktop-file-validate` (3 entries) | token: missing `Type` | all OK |
| entries matching eyeShell WMClass | 2, both visible | 2, one visible, one `NoDisplay` |
| icon of the AL eyeShell entry | `appimagekit_<id>_eyeshell`, 0 sizes | `eyeshell`, 16–512 |
| `probe-desktop-match.sh` on pre-fix state | `RESOLVED`, exit 0 (blind) | `FAIL`, exit 1 (icon missing) |
| `probe-desktop-match.sh` after fix | — | `RESOLVED (identity + icon asset)`, exit 0 |
| guard vs simulated AL rewrite | — | corrected; second run `no changes needed` |
| simulated 0.84.1 update | — | new entry normalised; probe exit 0 |
| **real 0.84.1 update** (2026-11-02 21:47) | AL wrote its own new `appimagekit_<id>` entry (bundle `StartupWMClass`, unextracted icon name) | guard patched it in ~3 s across two passes; old entry removed; probe exit 0; fixer now `no changes needed` |
| **real 0.87.0 update** (2026-11-06 22:34) | AL produced two `appimagekit_*` entries for the same 0.87.0 AppImage | guard kept one visible and hid the duplicate; both icons resolve; probe exit 0 |

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **Identity is necessary, not sufficient** | after the two rules match, the winning entry's `Icon=` must resolve; check every match, not just the visible one |
| **A desktop entry can be structurally invalid and invisible to both rules** | `Gio` returns null; `desktop-file-validate` names the missing key; a probe that only uses `Gio.AppInfo.get_all()` never sees it |
| **`NoDisplay=true` does not by itself stop window matching** | an existing binding is not cleared by hiding the entry; repair the hidden duplicate's icon too, or the shell can still show a gear |
| **Multiple entries can match the same app_id** | fix all of them; hiding is for the menu, not for identity |
| **Distinguish generator behaviour from corruption** | reproduce the generator in an isolated `HOME` (`ail-cli integrate`); AL appends ` (1)`, it does not drop keys |
| **A guard must repair structure** | a two-key patch can report success while the entry is unloadable |
| **Alias icons are cheap insurance** | generating the generator's own icon name (`appimagekit_<id>_<icon>`) rescues cached GIcon strings and races |
| **A real generator update is multi-step** | AppImageLauncher scheduled, wrote, then re-wrote the entry during deferred integration; the guard ran three times and patched twice before converging. Idempotency is what makes the extra passes safe. |
| **Deleting a test shortcut is not enough** | AppImageLauncher re-integrates any AppImage left in `~/Applications`; trash/move the test AppImage too, or the entry comes back on the next pass. |
| **Prove the guard against the pre-fix state** | the old probe returned 0 on the broken state; a check that cannot fail is not a check |

## Open

- AppImageLauncher's icon extraction fails on this jpackage AppDir (root `.DirIcon` only, no
  `usr/share/icons`). Packaging the seven sizes under
  `usr/share/icons/hicolor/<size>/apps/eyeshell.png` makes AL extract them correctly
  (verified with `ail-cli` in an isolated `HOME`), but the AppImage in use was not rebuilt.
- AL copies `StartupWMClass` from the bundle; Token Monitor's bundle still says `Token Monitor`
  while its app_id is `token-monitor`.
- GNOME may keep the old icon in the running window's app object; restart the app (or re-login)
  after changing the entry.
- The first Linux case documents Gear Lever 4.6.2; the entry shapes differ
  (`token_monitor.desktop` vs `appimagekit_<id>-Token_Monitor.desktop`). The two-rule model is
  shared; the repair mechanics are not.
