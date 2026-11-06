#!/usr/bin/env bash
# STATUS : proven
# PLATFORM: linux
# NEEDS  : dpkg (Debian/Ubuntu), read-only
# ANSWERS: Of two packages that Conflict/Replace each other, which is actually installed,
#          and does the file that carries the capability belong to it?
# SIDE EFFECTS: none, read-only
# USED BY: cases/2026-11-04-rustdesk-wayland-unattended/, playbooks/0007
#
# Usage:
#   probe-package-variant.sh <base-pkg> <variant-pkg> <capability-artifact>
#
# <capability-artifact> is a path and may contain globs - quote it.
#
# Why this exists: a project can ship a "variant" package next to its base package with the
# SAME version number and Conflicts/Replaces. Updating the base silently removes the variant,
# and `--version` still prints the same number. The version is not the identity; the artifact
# is. This probe asks the question that settles it.

set -u

usage() {
  sed -n '/^# Usage:/,/^# <capability-artifact>/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -eq 3 ] || usage
base=$1
variant=$2
artifact=$3

# dpkg status: first letter = wanted action, second = package status.
state() {
  local s
  s=$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null) || { echo "not-installed"; return; }
  s=${s// /}
  case "$s" in
    ii) echo "installed" ;;
    rc) echo "removed, conffiles left" ;;
    ic) echo "config-files only" ;;
    i?) echo "not fully configured ($s)" ;;
    *)  echo "state=$s" ;;
  esac
}

base_state=$(state "$base")
variant_state=$(state "$variant")

# ls -l so the mtime of the shipped binary is visible: it is how you tell
# "the file exists" from "the file that is actually loaded".
artifact_listing=$(ls -l $artifact 2>/dev/null)
artifact_present=$([ -n "$artifact_listing" ] && echo yes || echo no)
owners=$(dpkg -S $artifact 2>/dev/null | cut -d: -f1 | sort -u | tr '\n' ' ')
owners=${owners:-none}
owners=${owners% }

printf '%-34s %s\n' "base package" "$base"
printf '%-34s %s\n' "  state" "$base_state"
printf '%-34s %s\n' "variant package" "$variant"
printf '%-34s %s\n' "  state" "$variant_state"
printf '%-34s %s\n' "capability artifact" "$artifact"
printf '%-34s %s\n' "  present" "$artifact_present"
printf '%-34s %s\n' "  owned by" "$owners"
if [ -n "$artifact_listing" ]; then
  printf '%-34s %s\n' "  listing" "$(echo "$artifact_listing" | head -1)"
fi

echo
if [ "$variant_state" = "installed" ] && [ "$artifact_present" = yes ] \
   && printf '%s' "$owners" | grep -qw "$variant"; then
  echo "VERDICT: PASS - the variant is installed and owns the capability artifact."
  exit 0
fi

echo "VERDICT: FAIL - the capability is not carried by the installed variant."
[ "$variant_state" != "installed" ] && \
  echo "  - variant '$variant' is not installed ($variant_state); the base package replaced it."
[ "$artifact_present" = no ] && \
  echo "  - '$artifact' does not exist: this build cannot do the thing at all."
[ "$artifact_present" = yes ] && ! printf '%s' "$owners" | grep -qw "$variant" && \
  echo "  - '$artifact' is owned by '$owners', not by the variant."
exit 1
