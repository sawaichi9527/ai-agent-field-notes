#!/usr/bin/env bash
#
# STATUS : proven (2026-11-20, gfx1151 / Ubuntu 26.04.1 / ROCm 10.1<->10.2)
# PLATFORM: linux
# NEEDS  : dpkg, apt, update-alternatives; root only for install/use/remove/restore
# ANSWERS: which ROCm versions are installed, which one is current, and can a new one be added without removing the old
# SIDE EFFECTS: --status/--plan/--verify/--bench/--snapshot are read-only; --install/--use/--remove/--purge/--restore change packages and alternatives

# rocm-version-switch.sh — ROCm 多版本並存、切換與回滾工具（TheRock 世代的 amdrocm* 套件）
#
# 設計原則：
#   * 只做「並存 + 切換」，永遠不主動移除另一個版本
#   * 任何寫入動作前先存 snapshot；回滾＝把 alternatives 指回去（或再移除新版本）
#   * 不執行 apt full-upgrade（避免順手升級核心／其他套件）
#   * 不碰 amdgpu-dkms、不設 HSA_OVERRIDE_GFX_VERSION
#
# 用法：
#   bash rocm-version-switch.sh --status              # 唯讀：列出已安裝/可用版本與 alternatives
#   bash rocm-version-switch.sh --plan 10.2           # 唯讀：模擬安裝 10.2，顯示會動到什麼
#   sudo bash rocm-version-switch.sh --install 10.2   # 安裝 10.2 並存，切 alternatives 到 10.2
#   sudo bash rocm-version-switch.sh --use 10.1       # 只切 alternatives（回滾用，最輕量）
#   bash rocm-version-switch.sh --verify              # 驗證目前指向的版本能否正常運作
#   bash rocm-version-switch.sh --bench [N]           # 頻寬 A/B 測試（warmup + N 次取樣，預設 30）
#   sudo bash rocm-version-switch.sh --restore FILE   # 依 snapshot 還原 alternatives
#   sudo bash rocm-version-switch.sh --remove 10.2    # 移除 10.2（10.1 保持不動）
#   sudo bash rocm-version-switch.sh --purge 10.1     # 移除 10.1（僅在確定不再需要時）
#
# 選項：
#   --gfx gfx1151     覆蓋自動偵測的 gfx target
#   --yes, -y         不詢問（僅供自動化；仍會先印出計畫）
#   --allow-remove    允許 apt 移除套件（預設遇到 Remv 就中止）
#
set -uo pipefail

SELF="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${ROCM_SWITCH_STATE:-${HOME}/.local/state/rocm-switch/snapshots-dir}"
SNAP_DIR="${STATE_DIR}"
ROOT_PREFIX="/opt/rocm"

ACTION=""
TARGET=""
GFX=""
ASSUME_YES=0
ALLOW_REMOVE=0
HIP_SRC="$SELF_DIR/src/hip-vector-add.cpp"
[ -r "$HIP_SRC" ] || HIP_SRC="$HIP_SRC"
SERIES_FROM_SNAPSHOT=""
ORIG_ARGS=("$@")

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --status)        ACTION="status" ;;
        --plan)          ACTION="plan";    TARGET="${2:-}"; shift ;;
        --install)       ACTION="install"; TARGET="${2:-}"; shift ;;
        --use|--switch)  ACTION="use";     TARGET="${2:-}"; shift ;;
        --verify)        ACTION="verify" ;;
        --bench)         ACTION="bench"; TARGET="${2:-30}"; shift ;;
        --remove)        ACTION="remove";  TARGET="${2:-}"; shift ;;
        --purge)         ACTION="purge";   TARGET="${2:-}"; shift ;;
        --restore)       ACTION="restore"; TARGET="${2:-}"; shift ;;
        --snapshot)      ACTION="snapshot" ;;
        --gfx)           GFX="${2:-}"; shift ;;
        --yes|-y)        ASSUME_YES=1 ;;
        --allow-remove)  ALLOW_REMOVE=1 ;;
        --help|-h)       usage ;;
        *) die "未知參數：$1（用 --help）" ;;
    esac
    shift
done

[ -n "$ACTION" ] || usage

# ---------------------------------------------------------------------------
# 環境
# ---------------------------------------------------------------------------
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
KREL="$(uname -r)"
IN_SANDBOX=0
[ -e /dev/kfd ] || IN_SANDBOX=1

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "需要 root，改用 sudo 重新執行"
        exec sudo bash "$SELF_DIR/$SELF" "${ORIG_ARGS[@]}"
    fi
}


# ---------------------------------------------------------------------------
# 偵測
# ---------------------------------------------------------------------------
detect_gfx() {
    [ -n "$GFX" ] && { printf '%s' "$GFX"; return 0; }
    local p
    p="$(dpkg-query -W -f='${Package}\n' 'amdrocm-core*' 2>/dev/null \
        | sed -nE 's/.*-(gfx[0-9a-z]+)$/\1/p' | sort -u | head -1)"
    if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
    return 1
}

installed_series() {
    local gfx="$1"
    dpkg-query -W -f='${Package}\n' 'amdrocm-core-sdk*' 2>/dev/null \
        | sed -nE "s/^amdrocm-core-sdk([0-9.]+)-${gfx}\$/\1/p" | sort -V -u
}

dir_series() {
    local d
    for d in "$ROOT_PREFIX"/core-[0-9]*; do
        [ -d "$d" ] || continue
        [ -L "$d" ] && continue
        [ -f "$d/.info/version" ] || continue
        printf '%s\t%s\n' "${d##*/core-}" "$(cat "$d/.info/version")"
    done
}

# 所有指向某 series 目錄的 alternatives 群組：輸出 "群組<TAB>目前路徑"
alts_for_series() {
    local series="$1"
    update-alternatives --get-selections 2>/dev/null \
        | awk -F'[[:space:]]+' -v s="$series" \
            '$1!="" && $3 ~ ("^/opt/rocm/core-" s "/") {print $1 "\t" $3}'
}

series_path_exists() { [ -e "$1" ]; }

# ---------------------------------------------------------------------------
# 狀態
# ---------------------------------------------------------------------------
show_status() {
    local gfx series
    gfx="$(detect_gfx)" || gfx=""
    echo "系統        : ${PRETTY_NAME:-$OS_ID $OS_VER} / kernel $KREL"
    echo "gfx target  : ${gfx:-（無法判定，請用 --gfx 指定）}"
    echo "apt 來源    : $(ls /etc/apt/sources.list.d/amdrocm-stable.sources 2>/dev/null || echo '（未設定）')"
    echo

    echo "已安裝的 ROCm 系列（dpkg）："
    if [ -n "$gfx" ]; then
        series="$(installed_series "$gfx")"
        [ -n "$series" ] || echo "  （無）"
        for s in $series; do
            local cnt cand
            cnt="$(dpkg-query -W -f='${Package} ${Version}\n' 'amdrocm*'"$s"'*' 2>/dev/null | wc -l)"
            cand="$(apt-cache policy "amdrocm-core-sdk${s}-${gfx}" 2>/dev/null \
                    | awk '/Candidate|候選/{print $2; exit}')"
            printf '  %-6s 套件數 %-3s 已安裝版本 %-10s repo 候選 %s\n' \
                "$s" "$cnt" "$(dpkg-query -W -f='${Version}' "amdrocm-core-sdk${s}-${gfx}" 2>/dev/null)" "$cand"
        done
    fi
    echo

    echo "/opt/rocm 下的版本目錄："
    local out; out="$(dir_series)"
    if [ -n "$out" ]; then printf '%s\n' "$out" | awk -F'\t' '{printf "  core-%-6s %s\n", $1, $2}'; else echo "  （無）"; fi
    echo

    echo "alternatives 目前指向："
    update-alternatives --get-selections 2>/dev/null \
        | awk '$3 ~ /^\/opt\/rocm\// {printf "  %-24s %-6s %s\n", $1, $2, $3}' \
        | head -20
    echo

    echo "磁碟："
    df -h / 2>/dev/null | awk 'NR==1{printf "  %s\n", $0; next} $6=="/" && !done {printf "  %s\n", $0; done=1}'
    local used
    for d in "$ROOT_PREFIX"/core-[0-9]*; do
        [ -d "$d" ] || continue
        [ -L "$d" ] && continue
        used="$(du -sh "$d" 2>/dev/null | cut -f1)"
        printf '  %-28s %s\n' "$d" "${used:-?}"
    done
    echo

    if [ "$IN_SANDBOX" = "1" ]; then
        warn "/dev/kfd 不存在 → 目前 shell 可能在容器／沙箱內（GPU 驗證請在一般終端機執行）"
    else
        ok "/dev/kfd 存在"
    fi
}

# ---------------------------------------------------------------------------
# Snapshot / Restore
# ---------------------------------------------------------------------------
snapshot() {
    local tag="${1:-manual}" ts file
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SNAP_DIR" || die "無法建立 $SNAP_DIR"
    file="$SNAP_DIR/${ts}-${tag}.tsv"
    {
        echo "# rocm snapshot v1"
        echo "# created $(date -Is)"
        echo "# kernel $KREL"
        echo "# series ${tag}"
        update-alternatives --get-selections 2>/dev/null \
            | awk '$3 ~ /^\/opt\/rocm\// {print "alt\t" $1 "\t" $3}'
        dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 'amdrocm*' 2>/dev/null \
            | awk -F'\t' '$3 ~ /installed$/ {print "pkg\t" $1 "\t" $2}'
    } > "$file"
    ok "snapshot：$file"
    printf '%s' "$file"
}

do_snapshot() {
    local f; f="$(snapshot manual | tail -1)"
    echo "  內容摘要：$(grep -c '^alt' "$f" 2>/dev/null) 個 alternatives、$(grep -c '^pkg' "$f" 2>/dev/null) 個套件"
}

do_restore() {
    local file="$1"
    [ -n "$file" ] || die "--restore 需要 snapshot 檔案路徑"
    [ -r "$file" ] || die "讀不到 $file"
    need_root
    local okc=0 skip=0 g p
    while IFS=$'\t' read -r kind name path; do
        [ "$kind" = "alt" ] || continue
        if series_path_exists "$path"; then
            update-alternatives --set "$name" "$path" >/dev/null 2>&1 \
                && { okc=$((okc+1)); } || { warn "無法設定 $name → $path"; }
        else
            warn "目標不存在，略過：$name → $path"
            skip=$((skip+1))
        fi
    done < <(grep '^alt' "$file")
    ok "已還原 $okc 個 alternatives（略過 $skip 個）"
    echo "  請執行： bash $SELF --verify"
}

# ---------------------------------------------------------------------------
# 切換 alternatives
# ---------------------------------------------------------------------------
do_use() {
    local to="$1" from cur new moved=0
    [ -n "$to" ] || die "--use 需要版本，例如 --use 10.1"
    need_root
    series_path_exists "$ROOT_PREFIX/core-$to" \
        || die "$ROOT_PREFIX/core-$to 不存在；請先安裝（--plan/--install $to）"

    # 找出目前指向其他版本的群組，逐一轉到新版本對應路徑
    while IFS=$'\t' read -r group cur; do
        [ -n "$group" ] || continue
        from="$(printf '%s' "$cur" | sed -nE 's#^/opt/rocm/core-([0-9.]+)(/.*)?$#\1#p')"
        [ -n "$from" ] || continue
        [ "$from" = "$to" ] && continue
        new="$(printf '%s' "$cur" | sed "s#^/opt/rocm/core-${from}#/opt/rocm/core-${to}#")"
        if series_path_exists "$new"; then
            if update-alternatives --set "$group" "$new" >/dev/null 2>&1; then
                printf '  %-24s %s → %s\n' "$group" "$cur" "$new"
                moved=$((moved+1))
            else
                warn "設定失敗：$group → $new"
            fi
        fi
    done < <(update-alternatives --get-selections 2>/dev/null \
                | awk '$3 ~ /^\/opt\/rocm\/core-/ {print $1 "\t" $3}')

    # core / core-10 這種「目錄型」群組，cur 可能是 /opt/rocm/core-10.1（已在上面處理）
    # 若完全沒動，代表已經指向目標版本
    if [ "$moved" = "0" ]; then
        ok "alternatives 已指向 $to（無需變更）"
    else
        ok "已切換 $moved 個 alternatives 到 $to"
    fi

    # 反向確認
    local left
    left="$(update-alternatives --get-selections 2>/dev/null \
            | awk '$3 ~ /^\/opt\/rocm\/core-/ {print $1, $3}' | grep -v "core-${to}" || true)"
    [ -z "$left" ] || warn "仍有群組指向其他版本：$(printf '%s' "$left" | tr '\n' ' ')"

    echo "  提示：若指令仍顯示舊版，開新 shell 或 hash -r 後再測。"
}

# ---------------------------------------------------------------------------
# 計畫（唯讀）
# ---------------------------------------------------------------------------
pkg_for() { printf 'amdrocm-core-sdk%s-%s' "$1" "$2"; }

# 不用 `cmd | grep -q`：pipefail 下上游可能因 SIGPIPE 被判失敗
pkg_candidate() {
    local out
    out="$(apt-cache policy "$1" 2>/dev/null)" || return 1
    awk '/Candidate|候選/{print $2; exit}' <<< "$out"
}

pkg_installed() {
    local st
    st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
    case "$st" in *"install ok installed"*) return 0 ;; *) return 1 ;; esac
}

do_plan() {
    local series="$1" gfx pkg sim sum remv
    [ -n "$series" ] || die "--plan 需要版本，例如 --plan 10.2"
    gfx="$(detect_gfx)" || die "無法判定 gfx target，請加 --gfx gfx1151"
    pkg="$(pkg_for "$series" "$gfx")"

    local cand
    cand="$(pkg_candidate "$pkg")"
    [ -n "$cand" ] && [ "$cand" != "(無)" ] && [ "$cand" != "(none)" ] \
        || die "repo 找不到 $pkg（先確認 apt update 與 gfx target）"

    if pkg_installed "$pkg"; then
        ok "$pkg 已安裝（$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)）"
        echo "  目前指向：$(readlink -f /opt/rocm/core 2>/dev/null)"
        echo "  要切換到它： sudo bash $SELF --use $series"
        echo "  要驗證它  ： bash $SELF --verify"
        echo "  要移除它  ： sudo bash $SELF --remove $series"
        return 0
    fi

    log "計畫：安裝 $pkg（$cand），與現有版本並存"
    echo "  gfx           : $gfx"
    echo "  已安裝系列    : $(installed_series "$gfx" | tr '\n' ' ')"
    echo "  安裝目錄      : $ROOT_PREFIX/core-$series"

    local avail
    avail="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
    local est
    est="$(apt-get -s install "$pkg" 2>/dev/null \
           | awk '/^Inst/{n++} END{print n+0}')"
    echo "  新增套件      : ${est:-?} 個"
    echo "  / 可用空間    : ${avail} GB（另需約 9 GB）"
    [ "${avail:-0}" -ge 15 ] || warn "可用空間偏低（< 15 GB）"

    sim="$(LC_ALL=C apt-get -s install "$pkg" 2>&1)"
    remv="$(printf '%s' "$sim" | grep -c '^Remv' || true)"
    sum="$(printf '%s' "$sim" | grep -E 'upgraded, .* newly installed' | tail -1)"
    echo "  模擬結果      : ${sum:-（無法取得摘要）}"
    if [ "${remv:-0}" -gt 0 ]; then
        warn "模擬顯示會移除 $remv 個套件（正常應為 0）"
        printf '%s\n' "$sim" | grep '^Remv' | sed 's/^/    /'
    else
        ok "不會移除任何套件 → 10.1 可保留作為回滾"
    fi
    echo
    echo "  下一步： sudo bash $SELF --install $series"
}

# ---------------------------------------------------------------------------
# 安裝
# ---------------------------------------------------------------------------
do_install() {
    local series="$1" gfx pkg sim remv sum snap
    [ -n "$series" ] || die "--install 需要版本，例如 --install 10.2"
    need_root
    gfx="$(detect_gfx)" || die "無法判定 gfx target，請加 --gfx gfx1151"

    pkg="$(pkg_for "$series" "$gfx")"
    case "$pkg" in *-gfx[0-9]*) ;; *) die "套件名不合法：$pkg" ;; esac
    [ -e "/etc/apt/sources.list.d/amdrocm-stable.sources" ] \
        || die "缺少 AMD apt 來源，請先依 runbook 步驟 2 設定"

    log "1. 更新 apt 索引"
    apt-get update -qq || warn "apt-get update 失敗（續用現有索引）"

    local cand
    cand="$(pkg_candidate "$pkg")"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ] || [ "$cand" = "(無)" ]; then
        echo "  除錯資訊（請把這段貼回）：" >&2
        echo "    apt-cache : $(command -v apt-cache || echo '找不到')" >&2
        echo "    PATH      : $PATH" >&2
        echo "    apt-cache policy $pkg（前 6 行）：" >&2
        apt-cache policy "$pkg" 2>&1 | head -6 | sed 's/^/      /' >&2
        die "找不到 $pkg"
    fi
    ok "repo 提供的版本：$cand"

    log "2. 模擬（確認不會移除任何套件）"
    sim="$(LC_ALL=C apt-get -s install "$pkg" 2>&1)"
    remv="$(printf '%s' "$sim" | grep -c '^Remv' || true)"
    sum="$(printf '%s' "$sim" | grep -E 'upgraded, .* newly installed' | tail -1)"
    echo "  ${sum:-（無摘要）}"
    if [ "${remv:-0}" -gt 0 ] && [ "$ALLOW_REMOVE" = "0" ]; then
        printf '%s\n' "$sim" | grep '^Remv' | sed 's/^/    /'
        die "模擬會移除 ${remv} 個套件；如確定，加 --allow-remove 重跑"
    fi

    log "3. 建立回滾點（snapshot）"
    snap="$(snapshot "pre-install-${series}" | tail -1)"
    echo "  $snap"

    if [ "$ASSUME_YES" = "0" ]; then
        echo
        printf '即將安裝 %s。10.1 會保留、alternatives 會切到 %s。[y/N] ' "$pkg" "$series"
        read -r ans
        case "$ans" in y|Y|yes|YES) ;; *) die "使用者取消" ;; esac
    fi

    log "4. 安裝（約 1 GB 下載、9 GB 磁碟）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$pkg" || die "安裝失敗（10.1 未受影響；可用 --restore 還原 alternatives）"
    ok "安裝完成：$(cat "$ROOT_PREFIX/core-$series/.info/version" 2>/dev/null || echo '?')"

    log "5. 切換 alternatives 到 $series"
    do_use "$series"

    log "6. 更新 snapshot（post-install）"
    snapshot "post-install-${series}" >/dev/null

    echo
    ok "完成。請在一般終端機驗證："
    echo "    bash $SELF --verify"
    echo "  回滾（最輕量）： sudo bash $SELF --use 10.1"
}

# ---------------------------------------------------------------------------
# 移除
# ---------------------------------------------------------------------------
do_remove() {
    local series="$1" gfx pkg others verb="remove"
    [ -n "$series" ] || die "--remove 需要版本，例如 --remove 10.2"
    need_root
    gfx="$(detect_gfx)" || die "無法判定 gfx target"
    pkg="$(pkg_for "$series" "$gfx")"
    pkg_installed "$pkg" || die "$pkg 未安裝"

    others="$(installed_series "$gfx" | grep -v "^${series}\$" | tr '\n' ' ')"
    [ -n "$others" ] || warn "這是最後一個已安裝的 ROCm 系列，移除後就沒有可用版本"

    # 若目前 alternatives 指向要移除的版本，先切走
    if [ -n "$(alts_for_series "$series" | head -1)" ] && [ -n "$others" ]; then
        log "1. 先把 alternatives 切到 ${others%% *}"
        do_use "${others%% *}"
    elif [ -n "$(alts_for_series "$series" | head -1)" ]; then
        warn "這是目前唯一/使用中的版本；移除後 alternatives 會失效"
        if [ "$ACTION" != "purge" ]; then
            die "如確定要移除最後一個版本，請改用 --purge $series"
        fi
    fi

    log "2. 建立回滾點"
    snapshot "pre-remove-${series}" >/dev/null

    [ "$ACTION" = "purge" ] && verb="purge"
    log "3. 移除 $pkg（$verb）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get "$verb" -y "$pkg" || die "移除失敗"
    ok "已移除 $pkg（相依套件未自動清除）"
    echo "  清除殘留相依套件： sudo apt autoremove --purge"
    echo "  確認現況        ： bash $SELF --status"
}

# ---------------------------------------------------------------------------
# 頻寬 A/B 測試
# ---------------------------------------------------------------------------
do_bench() {
    local gfx iters cur tmpd bin
    gfx="$(detect_gfx)" || gfx=""
    iters="${1:-30}"
    cur="$(basename "$(readlink -f "$ROOT_PREFIX/core" 2>/dev/null)")"
    [ -r "$SELF_DIR/.rocm-verify/bench-vector-add.cpp" ] \
        || die "找不到 .rocm-verify/bench-vector-add.cpp"
    if [ "$IN_SANDBOX" = "1" ]; then
        warn "/dev/kfd 不存在（沙箱環境），無法量測 GPU；請在一般終端機執行"
        return 1
    fi
    log "bench：$cur（gfx=$gfx, iters=$iters）"
    tmpd="$(mktemp -d /tmp/rocm-bench.XXXXXX)"
    bin="$tmpd/bench"
    if ! hipcc --offload-arch="$gfx" -O3 "$SELF_DIR/.rocm-verify/bench-vector-add.cpp" -o "$bin" 2>"$tmpd/cc.err"; then
        tail -8 "$tmpd/cc.err" | sed 's/^/  /'
        rm -rf "$tmpd"
        die "bench 編譯失敗"
    fi
    timeout 600 "$bin" "$iters" | sed 's/^/  /'
    local rc=$?
    rm -rf "$tmpd"
    echo
    echo "  A/B 比較方式："
    echo "    sudo bash $SELF --use 10.1 && bash $SELF --bench $iters"
    echo "    sudo bash $SELF --use 10.2 && bash $SELF --bench $iters"
    return $rc
}

# ---------------------------------------------------------------------------
# 驗證
# ---------------------------------------------------------------------------
verify() {
    local gfx ri rc ri_ok=0 hip_ok=0 tmpd
    gfx="$(detect_gfx)" || gfx=""
    echo "系統      : ${PRETTY_NAME:-$OS_ID $OS_VER} / kernel $KREL"
    echo "gfx       : ${gfx:-?}"
    echo

    echo "版本目錄："
    dir_series | awk -F'\t' '{printf "  core-%-6s %s\n", $1, $2}'
    echo "目前指向："
    update-alternatives --get-selections 2>/dev/null \
        | awk '$3 ~ /^\/opt\/rocm\/core-/ {printf "  %-24s %s\n", $1, $3}' | head -8
    echo "  /opt/rocm/core -> $(readlink -f "$ROOT_PREFIX/core" 2>/dev/null || echo '?')"
    echo

    if ! command -v rocminfo >/dev/null 2>&1; then
        warn "PATH 上找不到 rocminfo"; return 1
    fi

    if [ "$IN_SANDBOX" = "1" ]; then
        warn "/dev/kfd 不存在 → 沙箱環境，跳過 GPU 實測（請在一般終端機重跑 --verify）"
        return 0
    fi

    echo "工具版本："
    amd-smi version 2>&1 | sed 's/^/  /'
    hipcc --version 2>&1 | head -2 | sed 's/^/  /'
    echo

    # rocminfo：只跑一次，保留 exit code 與 stderr，避免誤判
    echo "GPU 辨識（rocminfo）："
    tmpd="$(mktemp -d /tmp/rocm-verify.XXXXXX)"
    timeout 90 rocminfo >"$tmpd/out" 2>"$tmpd/err"; rc=$?
    case "$rc" in
        0)  if grep -q "$gfx" "$tmpd/out" 2>/dev/null; then
                grep -E 'Marketing Name|Runtime Version|'"$gfx" "$tmpd/out" | head -5 | sed 's/^/  /'
                ri_ok=1; ok "rocminfo 認得 $gfx"
            else
                warn "rocminfo 結束碼 0，但輸出（$(wc -l < "$tmpd/out") 行）沒有 $gfx"
                head -5 "$tmpd/out" | sed 's/^/    /'
            fi ;;
        124) warn "rocminfo 超過 90 秒未結束（timeout）" ;;
        139) warn "rocminfo segfault（SIGSEGV，結束碼 139）— 已知問題類別，見 runbook 疑難排解" ;;
        *)   warn "rocminfo 結束碼 $rc" ;;
    esac
    if [ "$rc" -ne 0 ] && [ -s "$tmpd/err" ]; then
        echo "  stderr 末幾行："
        tail -3 "$tmpd/err" | sed 's/^/    /'
    fi
    if [ "$ri_ok" = "0" ]; then
        echo "  改用 amd-smi 交叉確認："
        amd-smi static 2>/dev/null | grep -iE 'TARGET_GRAPHICS_VERSION|DEVICE_ID|NUM_COMPUTE_UNITS' \
            | head -3 | sed 's/^/    /' || echo "    （amd-smi static 也無輸出）"
    fi
    echo

    # HIP 端到端
    if [ -r "$HIP_SRC" ]; then
        echo "HIP 端到端實測："
        local bin
        bin="$tmpd/hip-vector-add"
        if hipcc --offload-arch="$gfx" -O2 "$HIP_SRC" -o "$bin" 2>"$tmpd/hipcc.err"; then
            if timeout 120 "$bin" >"$tmpd/hip.out" 2>&1; then
                sed 's/^/  /' "$tmpd/hip.out"
                hip_ok=1
                ok "HIP kernel 執行 PASS"
            else
                sed 's/^/  /' "$tmpd/hip.out"; warn "HIP 執行失敗"
            fi
        else
            tail -5 "$tmpd/hipcc.err" | sed 's/^/  /'; warn "HIP 編譯失敗"
        fi
    else
        echo "（找不到 .rocm-verify/hip-vector-add.cpp，略過端到端測試）"
    fi
    rm -rf "$tmpd"
    echo

    # 判定：HIP 能跑就代表 GPU 堆疊正常；rocminfo 單獨異常不算整體失敗
    if [ "$ri_ok" = "1" ] && [ "$hip_ok" = "1" ]; then
        ok "驗證通過"
        return 0
    elif [ "$hip_ok" = "1" ]; then
        warn "rocminfo 異常，但 HIP 編譯與執行成功 → GPU 堆疊正常，問題在 rocminfo 本身"
        echo "    建議：把上面 rocminfo 的結束碼與 stderr 貼出來判斷（segfault / timeout / 輸出格式）"
        return 0
    elif [ "$ri_ok" = "1" ]; then
        warn "GPU 可被 rocminfo 辨識，但 HIP 實測未通過 → 先別升級，需排查編譯/執行環境"
        return 1
    else
        warn "rocminfo 與 HIP 實測都失敗 → 先排查 GPU 存取（/dev/kfd 權限、群組）"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$ACTION" in
    status)            show_status ;;
    snapshot)          do_snapshot ;;
    plan)              do_plan "$TARGET" ;;
    install)           do_install "$TARGET" ;;
    use)               do_use "$TARGET" ;;
    remove)            do_remove "$TARGET" ;;
    purge)             do_remove "$TARGET" ;;
    restore)           do_restore "$TARGET" ;;
    verify)            verify ;;
    bench)             do_bench "$TARGET" ;;
    *)                 die "未知動作：$ACTION" ;;
esac
