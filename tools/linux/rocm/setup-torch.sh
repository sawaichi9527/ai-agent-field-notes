#!/usr/bin/env bash
#
# STATUS : proven (2026-11-20, torch 2.15.0+rocm10.2.0)
# PLATFORM: linux
# NEEDS  : python3.14 + venv, network to stable.repo.amd.com, /dev/kfd for the GPU check
# ANSWERS: is the pinned ROCm PyTorch wheel installed and can it run a real GPU matmul
# SIDE EFFECTS: creates a venv and pip-installs packages into it; no sudo, nothing system-wide

# setup-torch.sh — 建立 ROCm 10.2 專用的 PyTorch venv，並實際在 GPU 上驗證
#
# 為什麼要用腳本：PyTorch 的版本必須與 ROCm 版本嚴格對應（torchvision/torchaudio 也一樣），
# 直接 pip install torch 會抓到 CUDA 版或版本不匹配的 wheel。本腳本固定版本並驗證。
#
# 用法：
#   bash setup-torch.sh                      # 建立 ~/venvs/rocm102 並安裝 torch 2.15.0+rocm10.2.0
#   bash setup-torch.sh --venv ~/venvs/x     # 自訂 venv 路徑
#   bash setup-torch.sh --vision             # 加裝 torchvision
#   bash setup-torch.sh --audio              # 加裝 torchaudio
#   bash setup-torch.sh --check              # 只驗證既有 venv，不安裝
#   bash setup-torch.sh --torch 2.14.0+rocm10.2.0   # 指定其他版本
#
# 注意：
#   * 不需要 sudo；venv 在使用者家目錄
#   * 必須在「有 /dev/kfd 的一般終端機」執行（沙箱/容器無法驗證 GPU）
#   * 不要設 HSA_OVERRIDE_GFX_VERSION
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDX="https://stable.repo.amd.com/rocm/whl-next/"
VENV="${HOME}/venvs/rocm102"
PY="${PYTHON:-python3.14}"
TORCH="2.15.0+rocm10.2.0"
VISION=""
AUDIO=""
CHECK_ONLY=0
GFX="gfx1151"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --venv)   VENV="${2:-}"; shift ;;
        --python) PY="${2:-}"; shift ;;
        --torch)  TORCH="${2:-}"; shift ;;
        --gfx)    GFX="${2:-}"; shift ;;
        --vision) VISION="1" ;;
        --audio)  AUDIO="1" ;;
        --check)  CHECK_ONLY=1 ;;
        --help|-h) usage ;;
        *) die "未知參數：$1（用 --help）" ;;
    esac
    shift
done

[ -n "$VENV" ] || die "--venv 不能是空字串"
command -v "$PY" >/dev/null 2>&1 || die "找不到 Python：$PY"

# ---------------------------------------------------------------------------
# 環境檢查
# ---------------------------------------------------------------------------
ROCM_VER="$(cat /opt/rocm/core/.info/version 2>/dev/null || echo '?')"
echo "系統      : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "ROCm      : $ROCM_VER（/opt/rocm/core -> $(readlink -f /opt/rocm/core 2>/dev/null)）"
echo "Python    : $("$PY" --version 2>&1)"
echo "venv      : $VENV"
echo "torch pin : torch[device-${GFX}]==${TORCH}"
echo

case "$TORCH" in
    *rocm10.2.0) [ "$ROCM_VER" = "10.2.0" ] || warn "torch pin 是 rocm10.2.0，但目前指向 ROCm $ROCM_VER（仍會安裝，但請確認）" ;;
    *) warn "torch pin（$TORCH）不是 rocm10.2.0，請自行確認與目前 ROCm 相符" ;;
esac

if [ ! -e /dev/kfd ]; then
    warn "/dev/kfd 不存在：可安裝但【無法驗證 GPU】。建議在一般終端機執行。"
fi

# ---------------------------------------------------------------------------
# 安裝
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" = "0" ]; then
    if [ -x "$VENV/bin/python" ]; then
        ok "venv 已存在，沿用：$VENV"
    else
        log "建立 venv"
        "$PY" -m venv "$VENV" || die "venv 建立失敗（需要 python3.14-venv 套件）"
    fi
    # shellcheck disable=SC1091
    . "$VENV/bin/activate"

    log "更新 pip / wheel"
    pip install -q --upgrade pip wheel || die "pip 升級失敗"

    log "安裝 PyTorch（約 1–3 GB，視快取）"
    pip install --index-url "$IDX" "torch[device-${GFX}]==${TORCH}" || die "torch 安裝失敗"

    PKGS=()
    if [ -n "$VISION" ]; then
        for v in 0.29.2 0.29.0; do
            if pip install --index-url "$IDX" "torchvision[device-${GFX}]==${v}+rocm10.2.0" 2>/dev/null; then
                ok "torchvision ${v} 安裝完成"; break
            fi
            warn "torchvision ${v} 失敗，嘗試下一個"
        done
    fi
    if [ -n "$AUDIO" ]; then
        pip install --index-url "$IDX" "torchaudio==2.11.1+rocm10.2.0" \
            || warn "torchaudio 安裝失敗（可略過；不影響 torch）"
    fi
else
    [ -x "$VENV/bin/python" ] || die "--check 需要既有的 venv：$VENV"
    # shellcheck disable=SC1091
    . "$VENV/bin/activate"
fi

# ---------------------------------------------------------------------------
# GPU 驗證
# ---------------------------------------------------------------------------
log "在 GPU 上驗證"
python - <<'PY'
import sys
try:
    import torch
except Exception as e:
    print(f"[x] import torch 失敗：{e}")
    sys.exit(1)

print(f"torch        : {torch.__version__}")
print(f"HIP runtime  : {torch.version.hip}")
print(f"device count : {torch.cuda.device_count()}")

if not torch.cuda.is_available():
    print("[x] torch.cuda.is_available() == False")
    print("    → 確認使用者有 render 群組、/dev/kfd 存在、且安裝的是 +rocm 版本")
    sys.exit(1)

dev = torch.device("cuda:0")
print(f"device       : {torch.cuda.get_device_name(0)}")

# 1) 矩陣乘法正確性（GPU vs CPU）
torch.manual_seed(0)
a = torch.randn(1024, 1024, device=dev)
b = torch.randn(1024, 1024, device=dev)
c = a @ b
ref = a.cpu() @ b.cpu()
err = (c.cpu() - ref).abs().max().item()
print(f"matmul       : max abs err = {err:.3e}")
ok_mm = err < 1e-2

# 2) 逐元素 + 同步（確認 kernel 真的在裝置上跑）
x = torch.randn(4096, 4096, device=dev)
ys = x * 2.0
torch.cuda.synchronize()
ok_ew = bool(torch.allclose(ys[0, :8].cpu(), x[0, :8].cpu() * 2.0))

print(f"elementwise  : {'OK' if ok_ew else 'FAIL'}")
if ok_mm and ok_ew:
    print("\nRESULT: PASS")
    sys.exit(0)
print("\nRESULT: FAIL")
sys.exit(1)
PY
RC=$?

if [ "$RC" -ne 0 ]; then
    warn "GPU 驗證失敗（rc=$RC）"
    warn "排查順序：1) id 有 render 群組 2) /dev/kfd 存在 3) 安裝的是 +rocm10.2.0 而非 CUDA 版"
    exit "$RC"
fi
ok "PyTorch 已可用"

# ---------------------------------------------------------------------------
# 選用元件的匯入驗證
# ---------------------------------------------------------------------------
if python -c "import torchvision" 2>/dev/null; then
    python - <<'PY'
import torch, torchvision
print(f"torchvision  : {torchvision.__version__}")
# 抓「operator torchvision::nms does not exist」這類版本錯配
boxes = torch.tensor([[0., 0., 10., 10.], [1., 1., 5., 5.]], device="cuda")
scores = torch.tensor([0.9, 0.8], device="cuda")
try:
    keep = torchvision.ops.nms(boxes, scores, 0.5)
    print(f"nms          : OK（保留 {len(keep)} 個）")
except Exception as e:
    print(f"[x] torchvision.ops.nms 失敗：{e}")
    print("    → torchvision 與 torch 版本不匹配，請重裝對應版本")
    raise SystemExit(1)
PY
fi

echo
ok "完成"
VENV_SIZE="$(du -sh "$VENV" 2>/dev/null | cut -f1)"
cat <<EOF

  體積        : ${VENV_SIZE:-未知}（venv 內自帶 ROCm 執行環境，與 /opt/rocm 解耦）
                  → 系統 ROCm 切換版本不會影響這個 venv；要換 ROCm 版本請重建 venv 並改 pin。

  啟用方式：
      source "$VENV/bin/activate"

  之後每次使用都建議：
      export DISABLE_ADDMM_HIP_LT=1     # gfx1151 的 hipBLASLt 缺 fallback kernel（僅 torch.compile 訓練需要）

  不要設定 HSA_OVERRIDE_GFX_VERSION。
EOF
