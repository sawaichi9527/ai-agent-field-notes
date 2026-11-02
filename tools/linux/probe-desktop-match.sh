#!/usr/bin/env bash
# STATUS : proven
# PLATFORM: linux
# NEEDS  : python3 + PyGObject (gi); any desktop session (no D-Bus call needed)
# ANSWERS: given a window's app_id, does a .desktop entry resolve for it — and by which of the
#          shell's two rules (desktop id, or StartupWMClass)?
# SIDE EFFECTS: none, read-only
# USED BY: playbooks/0006-window-identity-not-icon.md,
#          cases/2026-11-02-appimage-dock-gear-linux/
#
# Usage:
#   probe-desktop-match.sh <app-id> [executable-path]
#
#   <app-id>           the SECOND string of WM_CLASS, e.g. "token-monitor"
#   [executable-path]  optional; also lists every entry whose Exec/TryExec references this file,
#                      which is how stale or duplicated entries from integration tools show up
#
# Exit code: 0 = resolved (rule 1 or rule 2), 1 = would fall back to the generic icon.
#
# Why this exists: a missing/wrong window icon is almost never an icon-asset problem. The shell
# matches the window to an application by exactly two rules; this probe replays those two rules
# through GIO, without a GUI, so the check can be scripted.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

APP_ID="$1"
EXEC_PATH="${2:-}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }
python3 -c 'import gi' 2>/dev/null || { echo "error: PyGObject (python3-gi) not installed" >&2; exit 2; }

APP_ID="$APP_ID" EXEC_PATH="$EXEC_PATH" python3 -W ignore - <<'PY'
import os, sys, warnings
warnings.simplefilter("ignore")

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio

app_id = os.environ["APP_ID"]
exec_path = os.environ.get("EXEC_PATH", "")

def entries():
    for info in Gio.AppInfo.get_all():
        if isinstance(info, Gio.DesktopAppInfo):
            yield info

# Rule 1: desktop id == app_id + ".desktop"
# NOTE: a missing id raises TypeError on this GIO version instead of returning None.
try:
    rule1 = Gio.DesktopAppInfo.new(f"{app_id}.desktop")
except TypeError:
    rule1 = None

# Rule 2: StartupWMClass == app_id (case-insensitive)
rule2 = [i for i in entries()
         if (i.get_startup_wm_class() or "").lower() == app_id.lower()]

print(f"app_id: {app_id}")
print(f"rule 1 (id == '{app_id}.desktop'): " + (f"FOUND  {rule1.get_id()}" if rule1 else "MISS"))
print(f"rule 2 (StartupWMClass == '{app_id}'): " +
      (", ".join(sorted(i.get_id() for i in rule2)) if rule2 else "MISS"))

resolved = rule1 is not None or bool(rule2)
print(f"verdict: {'RESOLVED' if resolved else 'FALLBACK ICON (gear)'}")

seen = set()
for info in ([rule1] if rule1 else []) + rule2:
    if info.get_id() in seen:
        continue
    seen.add(info.get_id())
    print(f"  - {info.get_id()}: icon={info.get_icon().to_string() if info.get_icon() else None} "
          f"exec={info.get_executable()} wm_class={info.get_startup_wm_class()!r}")

if exec_path:
    print(f"entries whose Exec/TryExec mentions {exec_path!r}:")
    hit = False
    for info in entries():
        text = " ".join(filter(None, [
            info.get_string("Exec") if info.get_string("Exec") else "",
            info.get_string("TryExec") if info.get_string("TryExec") else "",
        ]))
        if exec_path in text:
            hit = True
            print(f"  - {info.get_id()}  wm_class={info.get_startup_wm_class()!r}")
    if not hit:
        print("  (none)")

sys.exit(0 if resolved else 1)
PY
