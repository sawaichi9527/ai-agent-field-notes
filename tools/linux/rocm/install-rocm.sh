#!/usr/bin/env bash
#
# STATUS : template (fresh install only; use rocm-version-switch.sh once ROCm exists)
# PLATFORM: linux
# NEEDS  : root, network to stable.repo.amd.com; Ubuntu 22.04/24.04/26.04
# ANSWERS: can this machine get the ROCm Core SDK for its detected gfx target, without amdgpu-dkms
# SIDE EFFECTS: registers an apt repo and keyring, installs packages, adds the user to render,video

# install-rocm.sh — AMD Ryzen AI (RDNA 3.5) APU 的 ROCm 安裝腳本
#
# 適用硬體：Ryzen AI Max / Ryzen AI 系列 APU（gfx1151 / gfx1150 / gfx1152 / gfx1153 / gfx1103）
# 適用系統：Ubuntu 26.04（首選）、24.04、22.04
# 搭配文件：ROCm-install-runbook.md
#
# 特色：
#   * 自動從 CPU 型號偵測 gfx target（可用 --gfx 覆蓋）
#   * 自動從 AMD repo 找出最新 ROCm 版本
#   * 使用 Ubuntu 內建（inbox）amdgpu 驅動，絕不安裝 amdgpu-dkms
#   * 安裝前偵測 Ubuntu archive 的衝突套件
#
# 用法：
#   bash install-rocm.sh --check          # 只檢查環境，不修改系統（可不用 root）
#   sudo bash install-rocm.sh             # 安裝完整 Core SDK（預設）
#   sudo bash install-rocm.sh --runtime   # 只裝 runtime（不含編譯器）
#   sudo bash install-rocm.sh --gfx gfx1150
#   sudo bash install-rocm.sh --force      # 已安裝時仍要重裝／修復（預設會擋下並提示升級路徑）
#   sudo bash install-rocm.sh --user alice
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 預設值
# ---------------------------------------------------------------------------
GFX=""                       # 空 = 自動偵測
ROCM_SERIES=""               # 空 = 自動偵測最新
MODE="sdk"                   # sdk | runtime
TARGET_USER="${SUDO_USER:-${USER}}"
DO_CHECK=0
FORCE=0
UBUNTU_REPO=""

is_installed() {
    local st
    st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
    case "$st" in *"install ok installed"*) return 0 ;; *) return 1 ;; esac
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   DO_CHECK=1 ;;
        --force)   FORCE=1 ;;
        --runtime) MODE="runtime" ;;
        --sdk)     MODE="sdk" ;;
        --gfx)     GFX="${2:-}"; shift ;;
        --series)  ROCM_SERIES="${2:-}"; shift ;;
        --user)    TARGET_USER="${2:-}"; shift ;;
        --help|-h) usage ;;
        *) die "未知參數：$1（用 --help）" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 官方 CPU -> gfx 對照表（來源：ROCm docs/data/gpus.yaml）
# ---------------------------------------------------------------------------
detect_gfx() {
    local model key
    model="$(lscpu 2>/dev/null | awk -F: '/^型號名稱|^Model name/ {gsub(/^ +/,"",$2); print $2; exit}')"
    [ -n "$model" ] || return 1
    key="${model#AMD }"
    key="${key%% w/*}"
    key="${key%% with*}"
    key="$(printf '%s' "$key" | sed 's/ *$//')"
    echo "  偵測到 CPU：${key}" >&2
    case "$key" in
        "Ryzen AI Max+ PRO 495"|"Ryzen AI Max PRO 490"|"Ryzen AI Max PRO 485"|\
        "Ryzen AI Max+ PRO 395"|"Ryzen AI Max PRO 390"|"Ryzen AI Max PRO 385"|\
        "Ryzen AI Max PRO 380"|"Ryzen AI Max+ 395"|"Ryzen AI Max+ 392"|\
        "Ryzen AI Max+ 388"|"Ryzen AI Max 390"|"Ryzen AI Max 385")
            echo gfx1151 ;;
        "Ryzen AI 9 HX PRO 475"|"Ryzen AI 9 HX PRO 470"|"Ryzen AI 9 PRO 465"|\
        "Ryzen AI 9 HX 475"|"Ryzen AI 9 HX 470"|"Ryzen AI 9 465"|\
        "Ryzen AI 9 HX PRO 375"|"Ryzen AI 9 HX PRO 370"|"Ryzen AI 9 HX 375"|\
        "Ryzen AI 9 HX 370"|"Ryzen AI 9 365")
            echo gfx1150 ;;
        "Ryzen AI 7 PRO 450"|"Ryzen AI 5 PRO 440"|"Ryzen AI 7 450"|\
        "Ryzen AI 7 PRO 350"|"Ryzen AI 5 PRO 340"|"Ryzen AI 7 350"|\
        "Ryzen AI 7 345"|"Ryzen AI 5 340"|"Ryzen AI 5 330")
            echo gfx1152 ;;
        "Ryzen AI 5 PRO 435"|"Ryzen AI 5 435"|"Ryzen AI 5 430"|"Ryzen AI 7 445")
            echo gfx1153 ;;
        "Ryzen 7 PRO 250"|"Ryzen 5 PRO 230"|"Ryzen 5 PRO 220"|"Ryzen 5 PRO 215"|\
        "Ryzen 3 PRO 210"|"Ryzen 9 270"|"Ryzen 7 260"|"Ryzen 7 250"|\
        "Ryzen 5 240"|"Ryzen 5 230"|"Ryzen 5 220"|"Ryzen 3 210")
            echo gfx1103 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 環境偵測
# ---------------------------------------------------------------------------
log "1. 偵測系統"

[ -r /etc/os-release ] || die "找不到 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case "${VERSION_ID:-}" in
    26.04) UBUNTU_REPO="ubuntu2604" ;;
    24.04) UBUNTU_REPO="ubuntu2404" ;;
    22.04) UBUNTU_REPO="ubuntu2204" ;;
    *) die "不支援的 Ubuntu 版本：${VERSION_ID:-未知}（本腳本支援 26.04 / 24.04 / 22.04）" ;;
esac
echo "  OS          : ${PRETTY_NAME:-Ubuntu $VERSION_ID}"
echo "  Kernel      : $(uname -r)"
echo "  Repo 代號   : $UBUNTU_REPO"

KREL="$(uname -r)"
KMAJ="${KREL%%.*}"
if [ "$UBUNTU_REPO" = "ubuntu2604" ]; then
    case "$KREL" in
        7.0.0-*) ok "核心 $KREL 為官方支援的 Ubuntu 26.04 GA 系列" ;;
        *) warn "核心 $KREL 不在官方驗證的 Ubuntu 26.04 7.0 GA 系列內（仍可能可用）" ;;
    esac
elif [ "$UBUNTU_REPO" = "ubuntu2404" ]; then
    warn "Ryzen AI APU 在 Ubuntu 24.04 需要 HWE >= 6.17.0-19.19~24.04.2 或 OEM >= 6.14.0-1018"
    warn "或是改用 Ubuntu 26.04.1（官方首選）。目前核心：$KREL"
else
    warn "Ubuntu 22.04 並非 Ryzen AI APU 的理想組合，建議 26.04.1。目前核心：$KREL"
fi

if grep -q '^amdgpu ' /proc/modules; then ok "amdgpu 已載入"; else warn "amdgpu 未載入"; fi
if [ -e /dev/kfd ]; then ok "/dev/kfd 存在"; else warn "/dev/kfd 不存在（若為容器環境請忽略）"; fi

if is_installed amdgpu-dkms; then
    die "偵測到 amdgpu-dkms！Ryzen APU 必須使用 inbox 驅動。
    請先移除： sudo apt autoremove --purge amdgpu-dkms amdgpu-dkms-firmware"
fi
ok "未安裝 amdgpu-dkms"

CONFLICT=()
for p in rocm rocminfo amd-smi hipcc rocm-smi hip-utils; do
    is_installed "$p" && CONFLICT+=("$p")
done
if [ "${#CONFLICT[@]}" -gt 0 ]; then
    die "偵測到 Ubuntu archive 的衝突套件：${CONFLICT[*]}
    它們與 amdrocm* 搶佔相同路徑（/usr/bin/rocminfo 等）。
    請先移除： sudo apt autoremove ${CONFLICT[*]}"
fi
ok "無 Ubuntu archive ROCm 套件衝突"

# ---------------------------------------------------------------------------
# 已安裝偵測：避免把「升級／切換版本」誤跑成重裝
# ---------------------------------------------------------------------------
INSTALLED_SERIES="$(dpkg-query -W -f='${Package}\n' 'amdrocm-core-sdk*' 2>/dev/null \
    | sed -nE 's/^amdrocm-core-sdk([0-9.]+)-.*$/\1/p' | sort -V -u | tr '\n' ' ')"
if [ -n "${INSTALLED_SERIES// /}" ] && [ "$FORCE" != "1" ]; then
    warn "偵測到已安裝 ROCm 系列：${INSTALLED_SERIES}"
    echo "  目前 alternatives 指向：$(readlink -f /opt/rocm/core 2>/dev/null || echo '未知')"
    echo
    echo "  若目的是升級或切換版本，請改用（不會動到既有版本）："
    echo "      bash rocm-version-switch.sh --status"
    echo "      bash rocm-version-switch.sh --plan 10.2"
    echo "      sudo bash rocm-version-switch.sh --install 10.2"
    echo
    echo "  若確定要重裝／修復目前版本： sudo bash $0 --force ..."
    if [ "$DO_CHECK" = "1" ]; then
        echo "  （--check 模式：僅提示，繼續進行環境檢查）"
    else
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# gfx target
# ---------------------------------------------------------------------------
log "2. 決定 gfx target"
if [ -z "$GFX" ]; then
    GFX="$(detect_gfx)" || GFX=""
    if [ -z "$GFX" ]; then
        cat >&2 <<'EOF'
  無法自動辨識此 CPU 的 gfx target。
  請對照 AMD 官方清單 https://rocm.docs.amd.com/en/docs-10.1.0/compatibility/compatibility-matrix.html
  然後用 --gfx 指定，例如： sudo bash install-rocm.sh --gfx gfx1151
EOF
        die "需要 --gfx 參數"
    fi
    ok "自動偵測：$GFX"
else
    ok "使用者指定：$GFX"
fi

# ---------------------------------------------------------------------------
# 記憶體 / 空間
# ---------------------------------------------------------------------------
log "3. 資源檢查"
free -h | sed 's/^/  /'
if [ -r /sys/module/ttm/parameters/pages_limit ]; then
    PL="$(cat /sys/module/ttm/parameters/pages_limit)"
    echo "  ttm.pages_limit = $PL 頁 ≈ $(( PL * 4096 / 1024 / 1024 / 1024 )) GiB（GTT 共享記憶體）"
    echo "  （若明顯小於系統 RAM 的一半，見 runbook 的『共享記憶體調校』）"
fi
AVAIL_GB="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
echo "  / 可用空間：${AVAIL_GB} GB（Core SDK 需要約 10 GB）"
[ "${AVAIL_GB:-0}" -ge 12 ] || warn "可用空間可能不足 10 GB"

if [ "$DO_CHECK" = "1" ]; then
    echo
    ok "--check 完成：環境檢查通過，未修改系統。"
    echo "  實際安裝請執行： sudo bash $0 --gfx $GFX"
    exit 0
fi

# ---------------------------------------------------------------------------
# 取得 root
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log "需要 root，改用 sudo 重新執行"
    exec sudo --preserve-env=TARGET_USER bash "$0" --gfx "$GFX" --series "$ROCM_SERIES" \
         --user "$TARGET_USER" $([ "$MODE" = "runtime" ] && echo --runtime)
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 來源與版本
# ---------------------------------------------------------------------------
REPO_BASE="https://stable.repo.amd.com/rocm/core/packages/${UBUNTU_REPO}/"
KEYRING="/etc/apt/keyrings/amdrocm.gpg"
SOURCES="/etc/apt/sources.list.d/amdrocm-stable.sources"

log "4. 安裝前置套件"
apt-get update -qq || die "apt-get update 失敗"
apt-get install -y --no-install-recommends wget gpg perl ca-certificates \
    libatomic1 libquadmath0
ok "前置套件完成"

log "5. 註冊 AMD ROCm apt 來源"
mkdir -p --mode=0755 /etc/apt/keyrings
if [ ! -s "$KEYRING" ]; then
    wget -qO- "https://stable.repo.amd.com/rocm/gpg/packages.gpg" \
        | gpg --dearmor > "$KEYRING" || die "GPG 金鑰處理失敗"
    chmod 0644 "$KEYRING"
fi
cat > "$SOURCES" <<EOF
X-Repo-Id: amdrocm-stable
Types: deb
URIs: ${REPO_BASE}
Suites: stable
Components: main
Architectures: amd64
Signed-By: ${KEYRING}
Enabled: yes
EOF
apt-get update -qq || die "加入來源後 apt-get update 失敗"
ok "來源已設定：$SOURCES"

log "6. 決定 ROCm 版本"
if [ -z "$ROCM_SERIES" ]; then
    ROCM_SERIES="$(apt-cache search --names-only "^amdrocm-core-sdk[0-9.]+-${GFX}$" 2>/dev/null \
        | awk '{print $1}' \
        | sed -E "s/^amdrocm-core-sdk([0-9.]+)-${GFX}$/\1/" \
        | sort -V | tail -1)"
fi
[ -n "$ROCM_SERIES" ] || die "無法從 repo 判斷 ROCm 版本，請用 --series 指定（例如 --series 10.1）"
ok "ROCm 系列：$ROCM_SERIES"

if [ "$MODE" = "runtime" ]; then
    PKG="amdrocm${ROCM_SERIES}-${GFX}"
else
    PKG="amdrocm-core-sdk${ROCM_SERIES}-${GFX}"
fi

CAND="$(apt-cache policy "$PKG" 2>/dev/null | awk '/候選|Candidate/ {print $2; exit}')"
[ -n "$CAND" ] && [ "$CAND" != "(無)" ] && [ "$CAND" != "(none)" ] \
    || die "找不到套件 $PKG —— 請確認 $GFX 是否為受支援的目標"
ok "將安裝：$PKG（$CAND）"

log "7. 安裝（約 1 GB 下載，請耐心等候）"
apt-get install -y "$PKG" || die "安裝失敗"
ok "ROCm 安裝完成"

log "8. 設定 GPU 存取權限"
usermod -a -G render,video "$TARGET_USER" && ok "已將 $TARGET_USER 加入 render,video"

log "9. 驗證"
echo "  版本：$(cat "/opt/rocm/core-${ROCM_SERIES}/.info/version" 2>/dev/null || echo '?')"
for c in rocminfo amd-smi hipcc; do
    printf '  %-10s -> %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo '(找不到)')"
done
ls /lib/firmware/updates/amdgpu/ >/dev/null 2>&1 \
    && warn "偵測到 dkms 韌體覆蓋層，請檢查！" || ok "無 dkms 韌體覆蓋層"

echo
# 注意：不可寫成 `rocminfo | grep -q`。本腳本啟用 pipefail，grep -q 提前結束會讓
# rocminfo 收到 SIGPIPE（結束碼 141），導致明明成功卻被判定失敗。
RI_OUT="$(mktemp)"
timeout 60 rocminfo >"$RI_OUT" 2>/dev/null
RI_RC=$?
if [ "$RI_RC" -eq 0 ] && grep -q "$GFX" "$RI_OUT"; then
    ok "rocminfo 成功辨識 $GFX ✅"
elif [ "$RI_RC" -eq 0 ]; then
    warn "rocminfo 結束碼 0 但輸出沒有 $GFX（請人工確認：rocminfo | head -40）"
else
    warn "rocminfo 結束碼 $RI_RC（若為容器或未重新登入，請以一般使用者於終端機複驗）"
fi
rm -f "$RI_OUT"

cat <<EOF

$(printf '\033[1;32m')安裝完成$(printf '\033[0m')

  套件     : $PKG
  路徑     : /opt/rocm/core-${ROCM_SERIES}
  使用者   : $TARGET_USER 已加入 render,video

下一步：
  1. 重新登入（或重開機）讓群組生效
  2. 在一般終端機（非 root）驗證：
         rocminfo | grep -i $GFX
         amd-smi version
  3. 建議做一次 GPU 實測（見 runbook 的「驗證」章節）

注意：
  * 不要安裝 amdgpu-dkms（Ryzen APU 用 inbox 驅動）
  * 不要設定 HSA_OVERRIDE_GFX_VERSION
  * 不要混裝 Ubuntu archive 的 rocm 套件
EOF
