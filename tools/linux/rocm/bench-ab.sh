#!/usr/bin/env bash
#
# STATUS : proven (2026-11-20, gfx1151 / ROCm 10.1 vs 10.2)
# PLATFORM: linux
# NEEDS  : a working ROCm install, /dev/kfd, sudo (temporarily switches alternatives)
# ANSWERS: does version A differ from version B in memory bandwidth, once warmup/order/cooldown are controlled
# SIDE EFFECTS: switches alternatives to each version and restores the original at exit; writes logs+TSV under the state dir

# bench-ab.sh — ROCm 版本 A/B 頻寬比較（一次跑完，含 alternatives 切換與還原）
#
# 為什麼需要這支：GPU 量測只能在你的終端機（有 /dev/kfd）執行，
# 但「切版本 → 跑 bench → 切回來 → 算差異」可以自動化成一條指令。
#
# 用法：
#   bash bench-ab.sh                     # 10.1 與 10.2 各編譯+量測，比較 codegen+runtime
#   bash bench-ab.sh --runtime-only      # 只編譯一次，同一 binary 跑兩種 runtime（隔離 codegen）
#   bash bench-ab.sh --iters 50          # 每版取樣次數（預設 30）
#   bash bench-ab.sh --series "10.1 10.2 10.3"
#   bash bench-ab.sh --cooldown 20       # 每次量測前閒置 N 秒，讓 GPU 回到待機時脈（預設 15，0=關閉）
#
# 特性：
#   * 只用一句 sudo 驗證（之後 sudo timestamp 沿用），結束會「還原成執行前的版本」
#   * 原始輸出與 TSV 結果都存在 .rocm-version-switch/bench/
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH="$SELF_DIR/rocm-version-switch.sh"
BENCH_CPP="$SELF_DIR/src/bench-vector-add.cpp"
[ -r "$BENCH_CPP" ] || BENCH_CPP="$SELF_DIR/.rocm-verify/bench-vector-add.cpp"
OUT_DIR="${ROCM_BENCH_OUT:-${HOME}/.local/state/rocm-switch/bench}"
ITERS=30
COOLDOWN=15
MODE="compile-each"
SERIES=(10.1 10.2)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --iters)        ITERS="${2:-30}"; shift ;;
        --series)       read -r -a SERIES <<< "${2:-10.1 10.2}"; shift ;;
        --cooldown)     COOLDOWN="${2:-15}"; shift ;;
        --runtime-only) MODE="runtime-only" ;;
        --help|-h)      usage ;;
        *) die "未知參數：$1（用 --help）" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 前置檢查
# ---------------------------------------------------------------------------
[ -r "$BENCH_CPP" ] || die "找不到 $BENCH_CPP"
[ -x "$SWITCH" ] || die "找不到 $SWITCH"
command -v hipcc >/dev/null || die "PATH 上沒有 hipcc"

if [ ! -e /dev/kfd ]; then
    die "/dev/kfd 不存在：這裡沒有 GPU 存取（容器/沙箱？）。請在一般終端機執行本腳本。"
fi

mkdir -p "$OUT_DIR" || die "無法建立 $OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$OUT_DIR/${STAMP}-raw.log"
TSV="$OUT_DIR/${STAMP}.tsv"
: > "$RAW"; : > "$TSV"

# ---------------------------------------------------------------------------
# 目前版本與 gfx
# ---------------------------------------------------------------------------
CUR="$(basename "$(readlink -f /opt/rocm/core)")"
ORIG="${CUR#core-}"
GFX="$(bash "$SWITCH" --status 2>/dev/null | awk '/gfx target/{print $4}')"
[ -n "$GFX" ] || die "無法判定 gfx target"

log "A/B 設定：gfx=$GFX、iters=$ITERS、mode=$MODE、cooldown=${COOLDOWN}s"
log "執行前版本：$ORIG（結束後會還原）"

restore() {
    if [ -n "${ORIG:-}" ] && [ "$(basename "$(readlink -f /opt/rocm/core)")" != "core-$ORIG" ]; then
        log "還原成 $ORIG"
        sudo -n bash "$SWITCH" --use "$ORIG" >/dev/null 2>&1 || warn "還原失敗，請手動： sudo bash $SWITCH --use $ORIG"
    fi
}
trap restore EXIT INT TERM

sudo -v || die "需要 sudo 才能切換 alternatives"

# ---------------------------------------------------------------------------
# 量測函式
# ---------------------------------------------------------------------------
cooldown() {
    [ "${COOLDOWN:-0}" -gt 0 ] || return 0
    log "冷卻 ${COOLDOWN}s（避免前一輪的熱度污染）"
    sleep "$COOLDOWN"
}

switch_to() {
    sudo bash "$SWITCH" --use "$1" >>"$RAW" 2>&1 || die "切換到 $1 失敗"
}

run_binary() {   # $1 = series 標籤, $2 = 可執行檔
    local label="$1" bin="$2" out med bw
    out="$("$bin" "$ITERS" 2>&1)" || { printf '%s\n' "$out" >>"$RAW"; die "$label 執行失敗"; }
    printf '### %s\n%s\n' "$label" "$out" >>"$RAW"
    med="$(printf '%s\n' "$out" | awk '$1=="median_ms"{print $3}')"
    bw="$(printf '%s\n' "$out" | awk '$1=="bw_med_gbs"{print $3}')"
    [ -n "$med" ] || die "無法解析 $label 的 median_ms（見 $RAW）"
    printf '%s\t%s\t%s\n' "$label" "$med" "${bw:-NA}" >> "$TSV"
}

run_switch_bench() {   # $1 = series
    local s="$1" out med bw
    switch_to "$s"
    out="$(bash "$SWITCH" --bench "$ITERS" 2>&1)" || { printf '%s\n' "$out" >>"$RAW"; die "$s bench 失敗"; }
    printf '### %s\n%s\n' "$s" "$out" >>"$RAW"
    med="$(printf '%s\n' "$out" | awk '$1=="median_ms"{print $3}')"
    bw="$(printf '%s\n' "$out" | awk '$1=="bw_med_gbs"{print $3}')"
    [ -n "$med" ] || die "無法解析 $s 的 median_ms（見 $RAW）"
    printf '%s\t%s\t%s\n' "$s" "$med" "${bw:-NA}" >> "$TSV"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$MODE" in
    compile-each)
        for s in "${SERIES[@]}"; do
            log "量測 $s（以該版 hipcc 編譯）"
            cooldown
            run_switch_bench "$s"
        done
        ;;
    runtime-only)
        TMPD="$(mktemp -d /tmp/bench-ab.XXXXXX)"
        trap 'rm -rf "$TMPD"; restore' EXIT INT TERM
        COMPILE="${SERIES[0]}"
        log "在 $COMPILE 下編譯一次（之後只換 runtime）"
        switch_to "$COMPILE"
        hipcc --offload-arch="$GFX" -O3 "$BENCH_CPP" -o "$TMPD/bench" 2>>"$RAW" \
            || die "編譯失敗（見 $RAW）"
        for s in "${SERIES[@]}"; do
            log "以 $s 的 runtime 執行同一 binary"
            cooldown
            switch_to "$s"
            run_binary "$s" "$TMPD/bench"
        done
        ;;
    *) die "未知模式：$MODE" ;;
esac

# ---------------------------------------------------------------------------
# 摘要（同一版本出現多次時取平均，較能抵抗順序/溫度偏差）
# ---------------------------------------------------------------------------
echo
log "結果摘要（median 越小越好；重複版本取平均）"
awk -F'\t' '
    { if (!($1 in sum)) order[++n] = $1
      sum[$1] += $2; cnt[$1]++
      if ($3 ~ /^[0-9.]+$/) { bwsum[$1] += $3; bwn[$1]++ } }
    END {
        base = (cnt[order[1]] > 0) ? sum[order[1]] / cnt[order[1]] : 0
        printf "  %-8s %-4s %-11s %-12s %-9s\n", "版本", "次數", "mean_ms", "bw_GB/s", "delta"
        for (i = 1; i <= n; i++) {
            v = order[i]; m = sum[v] / cnt[v]
            b = (bwn[v] > 0) ? bwsum[v] / bwn[v] : 0
            d = (base > 0) ? (m - base) / base * 100.0 : 0
            bs = (b > 0) ? sprintf("%.1f", b) : "NA"
            printf "  %-8s %-4d %-11.4f %-12s %+.2f%%\n", v, cnt[v], m, bs, d
        }
    }' "$TSV"

echo
echo "  注意：delta 相對第一個版本的平均；同一位置的配對比較（1↔3、2↔4）仍是最嚴謹的讀法。"

echo
ok "原始輸出：$RAW"
ok "TSV     ：$TSV"
echo "  判讀：|delta| < 5% 視為相同；> 10% 才值得追查。"
echo "  回滾： sudo bash $SWITCH --use $ORIG"
