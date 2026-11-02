#!/usr/bin/env bash
# STATUS : proven
# PLATFORM: linux
# NEEDS  : python3 + PyGObject (gi) + Gtk 3 typelib; any desktop session (no D-Bus call needed)
# ANSWERS: given a window's app_id (and optionally its executable and a specific .desktop file),
#          does an entry resolve, does EVERY matching entry's Icon actually resolve in the icon
#          theme, and are there structurally invalid / duplicate / hidden entries?
# SIDE EFFECTS: none, read-only
# USED BY: playbooks/0006-window-identity-not-icon.md,
#          cases/2026-11-02-appimage-dock-gear-linux/,
#          cases/2026-11-02-appimage-desktop-structural-repair/
#
# Usage:
#   probe-desktop-match.sh <app-id> [executable-path] [desktop-file]
#
#   <app-id>           the SECOND string of WM_CLASS, e.g. "token-monitor"
#   [executable-path]  optional; also lists every entry whose Exec/TryExec references this file,
#                      which is how stale or duplicated entries from integration tools show up
#   [desktop-file]     optional; validate this exact entry (basename is resolved against
#                      $XDG_DATA_HOME/applications). Use this to catch an entry that exists on
#                      disk but that GLib silently drops (missing Type/Exec/Name).
#
# Exit code:
#   0 = identity resolves, every matching entry's Icon resolves at at least one standard size,
#       and no explicit/exec-referencing entry is invalid
#   1 = the shell would fall back to the gear, or could bind to an entry whose icon is missing
#   2 = usage or environment error
#
# Why this exists: a missing/wrong window icon is almost never an icon-asset problem — but
# "almost" is doing work. The shell matches the window to an application by exactly two rules,
# and then it uses the Icon of whichever entry won. This probe replays the two rules, checks the
# icon of every match (including NoDisplay=true entries, which still match windows), and validates
# explicitly named entries that GLib would otherwise hide from the app list.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

APP_ID="$1"
EXEC_PATH="${2:-}"
ENTRY_PATH="${3:-}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }
python3 -c 'import gi' 2>/dev/null || { echo "error: PyGObject (python3-gi) not installed" >&2; exit 2; }

APP_ID="$APP_ID" EXEC_PATH="$EXEC_PATH" ENTRY_PATH="$ENTRY_PATH" python3 -W ignore - <<'PY'
import glob
import os
import shutil
import subprocess
import sys
import warnings

warnings.simplefilter("ignore")

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio

try:
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
except Exception as exc:
    print(f"error: Gtk 3 typelib unavailable ({exc}); cannot verify icon assets", file=sys.stderr)
    sys.exit(2)

APP_ID = os.environ["APP_ID"]
EXEC_PATH = os.environ.get("EXEC_PATH", "")
ENTRY_PATH = os.environ.get("ENTRY_PATH", "")

DATA_HOME = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
APPS_DIR = os.path.join(DATA_HOME, "applications")

SIZES = (16, 24, 32, 48, 64, 96, 128, 256, 512)
# The dock never renders below 32 px; one hit in this set is enough for a non-gear icon.
REQUIRED_SIZES = (32, 48, 64, 96, 128, 256, 512)

failures = []


def entries():
    for info in Gio.AppInfo.get_all():
        if isinstance(info, Gio.DesktopAppInfo):
            yield info


def icon_status(info):
    """Return (ok, human-readable detail) for the entry's Icon=."""
    icon = info.get_icon()
    if icon is None:
        return False, "no Icon key"

    if isinstance(icon, Gio.FileIcon):
        path = icon.get_file().get_path()
        if path and os.path.isfile(path):
            return True, f"file:{path}"
        return False, f"file MISSING:{path}"

    name = icon.to_string()
    theme = Gtk.IconTheme()
    found = [size for size in SIZES if theme.lookup_icon(name, size, 0) is not None]
    ok = any(size in found for size in REQUIRED_SIZES)
    detail = f"theme:{name} sizes={found or 'NONE'}"
    missing = [size for size in SIZES if size not in found]
    if missing:
        detail += f" missing={missing}"
    return ok, detail


# Rule 1: desktop id == app_id + ".desktop"
# NOTE: a missing id raises TypeError on this GIO version instead of returning None.
try:
    rule1 = Gio.DesktopAppInfo.new(f"{APP_ID}.desktop")
except TypeError:
    rule1 = None

# Rule 2: StartupWMClass == app_id (case-insensitive)
rule2 = [i for i in entries() if (i.get_startup_wm_class() or "").lower() == APP_ID.lower()]

matched = []
for info in ([rule1] if rule1 else []) + rule2:
    if info is not None and all(info.get_id() != seen.get_id() for seen in matched):
        matched.append(info)

print(f"app_id: {APP_ID}")
print(f"rule 1 (id == '{APP_ID}.desktop'): " + (f"FOUND  {rule1.get_id()}" if rule1 else "MISS"))
print(f"rule 2 (StartupWMClass == '{APP_ID}'): " +
      (", ".join(sorted({i.get_id() for i in rule2})) if rule2 else "MISS"))
print(f"entries matching the window: {len(matched)}")

icon_ok_all = True
for info in matched:
    ok, detail = icon_status(info)
    icon_ok_all = icon_ok_all and ok
    print(f"  - {info.get_id()}: show={info.should_show()} icon_ok={ok} {detail} "
          f"wm_class={info.get_startup_wm_class()!r} exec={info.get_executable()}")
    if not info.should_show():
        print("      note: hidden (NoDisplay=true) but still matches the window")

if len(matched) > 1:
    print(f"note: {len(matched)} entries match the same app_id; the shell may bind to any of them")

if not matched:
    failures.append("no entry resolves for this app_id")
    if not ENTRY_PATH:
        print("hint: the entry may exist but be unloadable; pass its .desktop as the third argument "
              "to check for a structurally invalid file")

if not icon_ok_all:
    failures.append("at least one matching entry has no resolvable icon")

# Validate entries named explicitly or referencing the executable. Gio.AppInfo.get_all() silently
# drops a .desktop file with missing required keys, so it never appears in the two rules above.
candidates = set()
if ENTRY_PATH:
    entry = ENTRY_PATH if os.path.isabs(ENTRY_PATH) else os.path.join(APPS_DIR, ENTRY_PATH)
    if not os.path.isfile(entry):
        print(f"explicit entry: MISSING {entry}")
        failures.append(f"explicit entry not found: {entry}")
    else:
        candidates.add(entry)

if EXEC_PATH:
    for path in glob.glob(os.path.join(APPS_DIR, "*.desktop")):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        if EXEC_PATH in text:
            candidates.add(path)

for path in sorted(candidates):
    try:
        info = Gio.DesktopAppInfo.new_from_filename(path)
    except Exception:
        info = None
    if info is None:
        detail = ""
        if shutil.which("desktop-file-validate"):
            result = subprocess.run(
                ["desktop-file-validate", path], capture_output=True, text=True, check=False
            )
            if result.returncode != 0:
                output = (result.stderr or "") + (result.stdout or "")
                detail = " | " + "; ".join(
                    line.strip() for line in output.splitlines() if line.strip()
                )
        print(f"invalid entry: {os.path.basename(path)} (GLib returns null){detail}")
        failures.append(f"invalid entry: {os.path.basename(path)}")
    else:
        print(f"valid entry mentioning Exec/TryExec: {os.path.basename(path)} "
              f"show={info.should_show()} icon={info.get_icon().to_string() if info.get_icon() else None}")

if failures:
    print("verdict: FAIL")
    for reason in failures:
        print(f"  - {reason}")
    sys.exit(1)

print("verdict: RESOLVED (identity + icon asset)")
sys.exit(0)
PY
