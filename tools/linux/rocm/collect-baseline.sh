#!/usr/bin/env bash
# STATUS : template (read-only; emits a markdown baseline report on stdout)
# PLATFORM: linux
# NEEDS  : dpkg, update-alternatives; /dev/kfd for the GPU sections; a torch venv for the torch section
# ANSWERS: what this particular gfx1151 machine actually measures, in a form that can be pasted into
#          cases/<date>-rocm-.../evidence/<sku>-baseline.md without re-typing numbers
# SIDE EFFECTS: none - it only reads. Benchmark output is written to the state dir by bench-ab.sh.
#
# Usage:
#   bash collect-baseline.sh                       # print markdown to stdout
#   bash collect-baseline.sh --out /tmp/base.md    # also write it
#   bash collect-baseline.sh --venv ~/venvs/rocm102
#   bash collect-baseline.sh --iters 50            # bench samples
#
# Sanitization: this script never prints the hostname or the user name. Paths are shown as ~/....
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH="$SELF_DIR/rocm-version-switch.sh"
OUT=""
VENV="${HOME}/venvs/rocm102"
ITERS=30

while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT="${2:-}"; shift ;;
        --venv)  VENV="${2:-}"; shift ;;
        --iters) ITERS="${2:-30}"; shift ;;
        --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

emit() { printf '%s\n' "$*"; }
row()  { printf '| %s | %s |\n' "$1" "$2"; }
sub()  { printf '\n### %s\n\n' "$1"; }

CPU="$(lscpu 2>/dev/null | awk -F: '/^Model name|^型號名稱/{gsub(/^ +/,"",$2); print $2; exit}')"
GPU="$(rocminfo 2>/dev/null | awk -F: '/Marketing Name/ && !/Ryzen/{gsub(/^ +/,"",$2); print $2; exit}')"
KREL="$(uname -r)"
OS="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-}" "${VERSION_ID:-}")"
RAM="$(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
KFD="no"; [ -e /dev/kfd ] && KFD="yes"
PAGES="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo '?')"
[ "$PAGES" != "?" ] && PAGES_GB="$(( PAGES * 4096 / 1024 / 1024 / 1024 )) GiB" || PAGES_GB="?"

report() {
    emit "# Baseline: <SKU> on ROCm <version> (fill the date)"
    emit ""
    emit "> Generated with \`tools/linux/rocm/collect-baseline.sh\`. Fill in the TODOs, delete rows that do"
    emit "> not apply, and re-read [SANITIZE.md](../../../SANITIZE.md) before opening a PR."
    emit ""
    emit "## System"
    emit ""
    emit "| Item | Value |"
    emit "| --- | --- |"
    row "SKU" "$CPU"
    row "iGPU" "${GPU:-TBD}"
    row "RAM" "$RAM"
    row "OS" "${OS:-TBD}"
    row "Kernel" "$KREL"
    row "amdgpu driver" "$( [ -e /sys/module/amdgpu/version ] && echo 'DKMS (investigate!)' || echo 'inbox' )"
    row "/dev/kfd available in this shell" "$KFD"
    row "ttm.pages_limit" "$PAGES pages ≈ $PAGES_GB"
    emit ""
    emit "## ROCm state"
    emit ""
    emit '```'
    if [ -x "$SWITCH" ]; then bash "$SWITCH" --status 2>&1 | sed 's/^/  /'; else emit "rocm-version-switch.sh not found next to this script"; fi
    emit '```'
    emit ""
    emit "## Version identity (fill from \`rocminfo\`, \`amd-smi version\`, \`hipcc --version\`)"
    emit ""
    emit "| Item | Value |"
    emit "| --- | --- |"
    row "ROCm (current)" "TBD"
    row "HIP runtime" "TBD"
    row "AMD SMI" "TBD"
    row "clang" "TBD"
    row "gfx target" "TBD"
    emit ""
    emit "## Verification"
    emit ""
    emit '```'
    if [ "$KFD" = "yes" ] && [ -x "$SWITCH" ]; then
        bash "$SWITCH" --verify 2>&1 | sed 's/^/  /'
    else
        emit "  (skipped: /dev/kfd not visible in this shell - run on the machine's own terminal)"
    fi
    emit '```'
    emit ""
    emit "## Benchmark"
    emit ""
    emit "Command: \`bash tools/linux/rocm/rocm-version-switch.sh --bench $ITERS\`"
    emit ""
    emit "| Metric | Value |"
    emit "| --- | --- |"
    row "median ms" "TBD"
    row "min ms" "TBD"
    row "bandwidth (median)" "TBD"
    row "traffic per iteration" "192 MiB (16M floats x3)"
    emit ""
    emit '```'
    if [ "$KFD" = "yes" ] && [ -x "$SWITCH" ]; then
        bash "$SWITCH" --bench "$ITERS" 2>&1 | sed 's/^/  /'
    else
        emit "  (skipped: no /dev/kfd in this shell)"
    fi
    emit '```'
    emit ""
    emit "## PyTorch"
    emit ""
    emit "| Item | Value |"
    emit "| --- | --- |"
    row "torch" "TBD"
    row "torchvision" "TBD"
    row "venv size" "TBD"
    row "eager ms/step" "TBD"
    row "compiled ms/step" "TBD"
    row "compile time" "TBD"
    emit ""
    emit '```'
    if [ -x "$VENV/bin/python" ]; then
        "$VENV/bin/python" -c 'import torch; print("torch", torch.__version__); print("hip", torch.version.hip)' 2>&1 | sed 's/^/  /'
    else
        emit "  (no venv at $VENV - run setup-torch.sh first)"
    fi
    emit "  # for the training numbers, paste the output of smoke-torch.sh"
    emit '```'
    emit ""
    emit "## Deltas against the 495 baseline"
    emit ""
    emit "| Metric | 495 (measured 2026-11-20) | this machine | comment |"
    emit "| --- | --- | --- | --- |"
    row "bandwidth (median)" "239 GB/s" "TBD" "same class expected; LPDDR5X 256-bit ceiling = 256 GB/s"
    row "eager ms/step (MLP 256-512-512-10, batch 512)" "12.87" "TBD" "scales with clocks, not with RAM size"
    row "compiled ms/step" "1.09" "TBD" "needs python3.14-dev + DISABLE_ADDMM_HIP_LT=1"
    emit ""
    emit "## Notes"
    emit ""
    emit "- What surprised you on this machine (thermal? GTT default? fan curve?): TODO"
    emit "- Anything that did **not** reproduce from the 495 write-up: TODO"
}

if [ -n "$OUT" ]; then
    report | tee "$OUT"
    echo "written: $OUT" >&2
else
    report
fi
