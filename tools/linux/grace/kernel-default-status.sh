#!/usr/bin/env bash
# STATUS : proven (2026-11-20, NVIDIA Grace C1 / Ubuntu nvidia-64k / 1043<->1067)
# PLATFORM: linux
# NEEDS  : dpkg, apt-mark, grep, sed; root only for the grub.cfg read on some installs
# ANSWERS: which kernel the boot pointer selects, which kernel lineages are installed
#          (nvidia-64k vs generic), and whether the fallback lineage is shielded
#          from `apt autoremove` by apt-mark manual
# SIDE EFFECTS: none, read-only
# USED BY: cases/2026-11-20-grace-c1-kernel-undo-switch/, playbooks/0018
#
# Usage:
#   kernel-default-status.sh            # read-only summary (needs no root for most reads)
#
# What this settles, and what it cannot: it reports the GRUB_DEFAULT pointer,
# the installed kernel lineages, PAGE_SIZE, and the apt-mark manual shield. It
# does NOT prove which kernel booted — that is `uname -r` + `/proc/cmdline` +
# `getconf PAGE_SIZE` after a reboot (see the case evidence). A boot pointer is
# a plan; only the booted kernel is a fact.

set -u

echo "== boot pointer (GRUB_DEFAULT) =="
if [ -r /etc/default/grub ]; then
  grep -E '^GRUB_DEFAULT=' /etc/default/grub || echo "(no GRUB_DEFAULT= in /etc/default/grub)"
else
  echo "(cannot read /etc/default/grub)"
fi

echo
echo "== effective set-default in grub.cfg =="
GRUB_CFG=""
for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
  [ -r "$c" ] && GRUB_CFG="$c" && break
done
if [ -n "$GRUB_CFG" ]; then
  grep -n 'set default=' "$GRUB_CFG" | head -2
else
  echo "(no readable grub.cfg found; needs root on some setups)"
fi

echo
echo "== kernel menuentries that survive regeneration =="
if [ -n "$GRUB_CFG" ]; then
  grep -n 'menuentry ' "$GRUB_CFG" | grep -iE 'Ubuntu, with Linux|recovery' | head -12
else
  echo "(skipped: grub.cfg not readable)"
fi

echo
echo "== page size (Grace must be 65536) =="
getconf PAGE_SIZE

echo
echo "== installed nvidia-64k lineage (ii) vs consumed (rc) =="
dpkg -l 2>/dev/null | grep -E 'linux-(image|modules|modules-nvidia-fs|tools|headers)-[0-9].*nvidia-64k' | awk '{printf "%s %s %s\n", $1, $2, $3}' | sort

echo
echo "== generic (4K) kernels present — NOT bootable on Grace, but GRUB offers them =="
dpkg -l 2>/dev/null | grep -E 'linux-image-[0-9].*generic' | awk '{printf "%s %s\n", $1, $2}' | sort

echo
echo "== apt-mark manual shield (fallback lineage must appear here) =="
apt-mark showmanual 2>/dev/null | grep -E '-[0-9]{4,}-nvidia-64k|linux-nvidia-' || echo "(no nvidia-64k packages marked manual)"
