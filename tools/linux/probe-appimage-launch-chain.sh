#!/usr/bin/env bash
# STATUS : proven
# PLATFORM: linux
# NEEDS  : bash, coreutils, procps; optional: xwininfo (X11/XWayland window state),
#          desktop-file-validate (structural check)
# ANSWERS: when clicking a menu icon "does nothing", which stage of the launch chain is dead —
#          the desktop entry, the integrator's middle-man, a stale app-level singleton lock, or a
#          window that exists but is not mapped?
# SIDE EFFECTS: none, read-only
# USED BY: playbooks/0012-bisect-the-launch-chain.md,
#          cases/2026-11-13-appimage-menu-click-launch-chain/
#
# Usage:
#   probe-appimage-launch-chain.sh <app-id> [desktop-file] [profile-dir]
#
#   <app-id>        window app_id, i.e. the SECOND string of WM_CLASS (e.g. "token-monitor")
#   [desktop-file]  explicit entry; default: newest matching *.desktop in the applications dir
#   [profile-dir]   Electron/Chromium user-data dir that owns SingletonLock
#                   (default: newest ~/.config/*/SingletonLock)
#
# Exit code:
#   0 = every stage of the chain looks alive (entry valid, no stale lock, window mapped or no instance)
#   1 = one stage is dead — the printed verdict names it
#   2 = usage / environment error
#
# Why this exists: "click does nothing" is not one bug. The click passes shell-cache -> desktop
# Exec -> (integrator interpreter / GUI) -> AppImage runtime -> app. Any stage can fail *silently*,
# and a stale Chromium single-instance lock makes the app exit in ~1.3 s with no window and no
# error output. This probe separates the stages before you change anything.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

APP_ID="$1"
ENTRY="${2:-}"
PROFILE="${3:-}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- stage 1: entry
say "== 1. desktop entry =="
if [ -z "$ENTRY" ]; then
    ENTRY=$(ls -1t "$APPS_DIR"/*"$APP_ID"*.desktop "$APPS_DIR"/*Token*Monitor*.desktop 2>/dev/null | head -1)
fi
if [ -z "$ENTRY" ] || [ ! -f "$ENTRY" ]; then
    say "   FAIL no entry found for app_id=$APP_ID under $APPS_DIR"
    exit 1
fi
say "   file: $(basename "$ENTRY")  (mtime $(date -r "$ENTRY" '+%F %T' 2>/dev/null))"

EXEC_LINE=$(grep -m1 '^Exec=' "$ENTRY" 2>/dev/null | cut -d= -f2-)
TRYEXEC_LINE=$(grep -m1 '^TryExec=' "$ENTRY" 2>/dev/null | cut -d= -f2-)
say "   Exec    : ${EXEC_LINE:-<missing>}"
say "   TryExec : ${TRYEXEC_LINE:-<none>}"

if have desktop-file-validate; then
    if desktop-file-validate "$ENTRY" 2>/dev/null; then
        say "   validate: OK"
    else
        say "   validate: FAIL"
        desktop-file-validate "$ENTRY" 2>&1 | sed 's/^/             /'
    fi
else
    say "   validate: (desktop-file-validate not installed, skipped)"
fi

# first token = what the shell will exec
EXEC_TARGET=$(printf '%s' "$EXEC_LINE" | sed 's/^env[[:space:]]\+//' | awk '{print $1}' | tr -d '"')
EXEC_TARGET=$(printf '%s' "$EXEC_TARGET" | sed 's/^[A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]*//')
say "   exec target: ${EXEC_TARGET:-<unparsed>}"
if [ -n "${EXEC_TARGET:-}" ] && [ ! -x "$EXEC_TARGET" ]; then
    say "   FAIL exec target is not executable"
    exit 1
fi

# ------------------------------------------------- stage 2: integrator middle-man
say
say "== 2. integrator middle-man (AppImageLauncher / binfmt) =="
BYPASS=0
if printf '%s' "$EXEC_TARGET" | grep -q '\.AppImage$'; then
    say "   Exec runs the AppImage directly -> binfmt intercepts it if the integrator registered one"
else
    say "   Exec runs a wrapper: $EXEC_TARGET"
    if grep -qs 'APPIMAGELAUNCHER_DISABLE' "$EXEC_TARGET" 2>/dev/null; then
        say "   wrapper sets APPIMAGELAUNCHER_DISABLE -> integrator GUI is bypassed  (good)"
        BYPASS=1
    else
        say "   wrapper does NOT set APPIMAGELAUNCHER_DISABLE -> integrator GUI still in the path"
    fi
    if [ -w "$EXEC_TARGET" ] && grep -qs 'SingletonLock' "$EXEC_TARGET" 2>/dev/null; then
        say "   wrapper also clears stale singleton locks  (good)"
    fi
fi

if [ -d /proc/sys/fs/binfmt_misc ]; then
    regs=$(ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -i appimage | tr '\n' ' ')
    if [ -n "${regs:-}" ]; then
        say "   binfmt registrations: $regs"
        for r in $regs; do
            say "     $r -> $(grep -m1 '^interpreter' "/proc/sys/fs/binfmt_misc/$r" 2>/dev/null | cut -d' ' -f2-)"
        done
        [ "$BYPASS" -eq 0 ] && say "   NOTE the integrator interpreter runs before the app on every exec"
    else
        say "   binfmt registrations: none (AppImages exec directly)"
    fi
else
    say "   binfmt_misc not mounted here; registrations are kernel-global, so 'exec runs directly'"
    say "   cannot be judged from inside a sandbox/container. Re-run outside it."
fi

# --------------------------------------------------- stage 3: singleton lock state
say
say "== 3. app-level single-instance lock (Chromium/Electron) =="
INSTANCES=$(ps -eo pid=,etime=,cmd= 2>/dev/null | grep -F -- "$APP_ID" | grep -v -e 'grep' -e 'probe-appimage' | wc -l | tr -d ' ')
say "   processes whose cmdline mentions '$APP_ID': $INSTANCES"

STALE=0        # authoritative: this app's own profile says the lock is dead
STALE_ANY=0    # informational: some profile somewhere is stale

# analyse one profile dir. $2=1 means "this is the app we were asked about", so a stale lock here
# is a verdict; $2=0 is informational only (another Electron app's leftovers must not fail this app).
analyze_lock() {
    _profile="$1"
    _authoritative="${2:-1}"
    say "   profile: $_profile"
    LOCK="$_profile/SingletonLock"
    SOCK="$_profile/SingletonSocket"
    if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
        owner=$(readlink "$LOCK" 2>/dev/null)
        pid=${owner##*-}
        alive=dead
        case "$pid" in
            '' | *[!0-9]*) alive=unknown ;;
            *) kill -0 "$pid" 2>/dev/null && alive=alive ;;
        esac
        sockpath=$(readlink "$SOCK" 2>/dev/null)
        sockstate=missing
        [ -n "$sockpath" ] && [ -S "$sockpath" ] && sockstate=present
        say "     SingletonLock -> ${owner:-<none>}  (holder: $alive)"
        say "     SingletonSocket -> ${sockpath:-<none>}  (socket: $sockstate)"
        if [ "$alive" = dead ] || [ "$sockstate" = missing ]; then
            say "     STALE: a new process takes the 'second instance' path, notifies, fails, and exits"
            say "            silently in ~1.3 s. Removing Lock/Cookie/Socket is safe while holder is dead."
            STALE_ANY=1
            [ "$_authoritative" = 1 ] && STALE=1
        else
            say "     lock is live -> a click landing now is a *second instance*, not a cold start"
        fi
    else
        say "     no SingletonLock (no instance, or it exited cleanly)"
    fi
}

if [ -n "$PROFILE" ]; then
    analyze_lock "$PROFILE" 1
else
    # deliberately do NOT guess one profile: several Electron apps may hold locks at once
    found=0
    for _lock in "$HOME"/.config/*/SingletonLock; do
        # SingletonLock is a dangling symlink by design ("<host>-<pid>"), so -e alone is false
        [ -e "$_lock" ] || [ -L "$_lock" ] || continue
        found=$((found + 1))
        analyze_lock "$(dirname "$_lock")" 0
    done
    if [ "$found" -eq 0 ]; then
        say "   no SingletonLock anywhere under ~/.config (all Electron apps exited cleanly)"
    elif [ "$found" -gt 1 ]; then
        say "   ($found locks listed; pass the profile dir as arg 3 to analyse exactly one)"
    fi
fi

# ------------------------------------------------------- stage 4: window mapping
say
say "== 4. window state =="
if [ -n "${DISPLAY:-}" ] && have xwininfo; then
    ids=$(xwininfo -root -tree 2>/dev/null | grep -i -F -- "$APP_ID" | awk '{print $1}')
    if [ -z "${ids:-}" ]; then
        say "   no X window matching '$APP_ID' (nothing mapped, or a native Wayland window)"
    else
        for id in $ids; do
            info=$(xwininfo -id "$id" 2>/dev/null)
            state=$(printf '%s' "$info" | grep 'Map State' | sed 's/.*: //')
            w=$(printf '%s' "$info" | sed -n 's/^  Width: //p')
            h=$(printf '%s' "$info" | sed -n 's/^  Height: //p')
            # Electron keeps tiny 10x10 helper windows around; only real windows are interesting
            if [ "${w:-0}" -ge 100 ] 2>/dev/null && [ "${h:-0}" -ge 100 ] 2>/dev/null; then
                say "   $id  ${w}x${h}  Map State: ${state:-?}"
                [ "$state" = IsUnMapped ] && say "        real window exists but is hidden -> this is a 'show existing window' case, not a cold start"
            else
                say "   $id  ${w:-?}x${h:-?}  (helper/auxiliary window, ignored)"
            fi
        done
    fi
else
    say "   DISPLAY unset or xwininfo missing; skipped (XWayland clients only)"
fi

# -------------------------------------------------------------------- verdict
say
say "== verdict =="
rc=0
[ "${STALE:-0}" = 1 ] && { say " DEAD STAGE: stale singleton lock in this app's profile (stage 3)"; rc=1; }
if [ "${STALE:-0}" = 0 ] && [ "${STALE_ANY:-0}" = 1 ]; then
    say " NOTE: a stale lock exists in another app's profile (see stage 3); it does not affect this app."
    say "       Pass the profile dir as arg 3 to make stage 3 authoritative for this app."
fi
if [ "${BYPASS:-0}" = 0 ] && printf '%s' "${EXEC_TARGET:-}" | grep -q '\.AppImage$'; then
    say " NOTE: Exec goes through the integrator; it is fine for a cold start but it is the layer that"
    say "       breaks the 'already running -> show window' contract on AppImageLauncher 3.0."
fi
[ "$rc" = 0 ] && say " no dead stage detected by this probe"
[ "$rc" = 0 ] && say " if the user still sees nothing: the click may never reach this entry (shell cache)."
[ "$rc" = 0 ] && say " confirm with: a fresh 'gtk-launch <desktop-id>' works, the menu does not -> log out/in."
exit "$rc"
