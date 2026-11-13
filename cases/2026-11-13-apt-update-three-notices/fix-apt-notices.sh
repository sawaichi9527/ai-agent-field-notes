#!/usr/bin/env bash
# fix-apt-notices.sh — silence apt's per-repository notices on a host that keeps i386
# (Steam/Wine) while some third-party repos publish amd64 only.
#
#   Notice: Skipping acquire of configured file '.../binary-i386/Packages' ... doesn't support architecture 'i386'
#   Notice: Missing Signed-By in the sources.list(5) entry for '...'
#
# Verified on Ubuntu 26.04.1 LTS / apt 3.2.1 (2026-11-13). Idempotent.
#
# Usage: sudo bash fix-apt-notices.sh
#
# Scope: only the entries listed below. Ubuntu's own archive keeps serving i386,
# so 32-bit Steam/Wine dependencies remain installable.

set -euo pipefail
export LC_ALL=C

NODESRC=/etc/apt/sources.list.d/nodesource.sources
NVSRC=/etc/apt/sources.list.d/stable-linux-debian-default.sources
NVKEY_SRC=/etc/apt/trusted.gpg.d/ai-workbench-desktop-key.asc
NVKEY_DST=/usr/share/keyrings/ai-workbench-desktop-key.asc

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

for f in "$NODESRC" "$NVSRC"; do
    [ -f "$f" ] || { echo "missing: $f (edit the variable list at the top)" >&2; exit 1; }
done

BK=/etc/apt/sources.list.d.bak.$(date +%Y%m%d-%H%M%S)
cp -a /etc/apt/sources.list.d "$BK"
echo "backup: $BK"
echo "rollback: sudo cp -a $BK/. /etc/apt/sources.list.d/"

# 1) Restrict each amd64-only repo to amd64 instead of dropping the i386 architecture.
for f in "$NODESRC" "$NVSRC"; do
    if grep -q '^Architectures:' "$f"; then
        echo "architectures already pinned: $f"
    else
        sed -i '/^Components:/a Architectures: amd64' "$f"
        echo "added 'Architectures: amd64': $f"
    fi
done

# 2) Give the NVIDIA entry its own Signed-By instead of the deprecated global trust store.
if [ -f "$NVKEY_SRC" ]; then
    install -m 0644 "$NVKEY_SRC" "$NVKEY_DST"
    echo "key copied: $NVKEY_DST"
    if grep -q '^Signed-By:[[:space:]]*$' "$NVSRC"; then
        sed -i "s|^Signed-By:.*|Signed-By: $NVKEY_DST|" "$NVSRC"
        echo "Signed-By set: $NVSRC"
    else
        echo "Signed-By already set: $NVSRC"
    fi
else
    echo "key not found, Signed-By left as is: $NVKEY_SRC" >&2
fi

# 3) Verify on a pty: apt prints Notice: only when stdout is a terminal (playbook 0011).
echo "--- apt-get update (pty) ---"
out=$(script -q -c "apt-get update" /dev/null | tr '\r' '\n')
printf '%s\n' "$out" | grep -E '^(Notice|N:|W:|E:|Err)' || true
bad=$(printf '%s\n' "$out" | grep -cE '^(Notice|N:|W:|E:|Err)' || true)
echo "--- notices/warnings/errors: $bad ---"
[ "$bad" -eq 0 ] || { echo "still noisy — inspect $BK vs current entries" >&2; exit 1; }
echo OK
