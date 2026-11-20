#!/usr/bin/env bash
#
# STATUS : proven (2026-11-20, gfx1151)
# PLATFORM: linux
# NEEDS  : an existing torch venv, /dev/kfd; python3.14-dev for the torch.compile leg
# ANSWERS: does the training path work (eager forward/backward, fp16 autocast, torch.compile)
# SIDE EFFECTS: temp files only; --device cpu runs without a GPU

# smoke-torch.sh — PyTorch 真實負載煙測：forward/backward、FP16 autocast、torch.compile
#
# 為什麼需要：`import torch` 能過不代表訓練路徑可用。gfx1151 的已知痛點是
#   hipBLASLt 缺 fallback kernel（torch.compile 會 JIT 很久），所以要用真實訓練驗一次。
#
# 用法：
#   bash smoke-torch.sh                        # 用 ~/venvs/rocm102，GPU，20 步，含 torch.compile
#   bash smoke-torch.sh --no-compile           # 跳過 torch.compile（快很多）
#   bash smoke-torch.sh --steps 50 --venv ~/venvs/x
#   bash smoke-torch.sh --device cpu           # 自我測試用（不需要 GPU）
#
# 判定：
#   * eager 訓練必須 PASS（loss 下降、梯度有限）→ 否則整體失敗
#   * autocast / torch.compile 失敗只警告，不影響整體判定（compile 在 gfx1151 可能很慢）
set -uo pipefail

VENV="${HOME}/venvs/rocm102"
DEVICE="cuda"
STEPS=20
DO_COMPILE=1
COMPILE_TIMEOUT=900

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --venv)            VENV="${2:-}"; shift ;;
        --device)          DEVICE="${2:-cuda}"; shift ;;
        --steps)           STEPS="${2:-20}"; shift ;;
        --no-compile)      DO_COMPILE=0 ;;
        --compile-timeout) COMPILE_TIMEOUT="${2:-900}"; shift ;;
        --help|-h)         usage ;;
        *) die "未知參數：$1（用 --help）" ;;
    esac
    shift
done

PY="$VENV/bin/python"
[ -x "$PY" ] || die "找不到 venv 的 python：$PY（先跑 setup-torch.sh）"

echo "venv   : $VENV"
echo "device : $DEVICE"
echo "steps  : $STEPS"
echo "compile: $DO_COMPILE（timeout ${COMPILE_TIMEOUT}s）"
echo

# torch.compile 的 Inductor 會用 gcc 編譯 C 擴充，需要 Python.h（python3.14-dev）
COMPILE_SKIP=""
if [ "$DO_COMPILE" = "1" ]; then
    INC="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])' 2>/dev/null || echo)"
    if [ -z "$INC" ] || [ ! -f "$INC/Python.h" ]; then
        warn "找不到 Python.h（預期在 ${INC:-?}/Python.h）→ torch.compile 無法運作"
        echo "    修法： sudo apt install python3.14-dev   然後重跑本腳本"
        echo "    本次先跳過 torch.compile（eager 訓練仍會完整驗證）"
        DO_COMPILE=0
        COMPILE_SKIP="缺少 Python.h（需 python3.14-dev）"
    fi
fi

# gfx1151 的 torch.compile 建議值（只在使用 compile 時設定）
[ "$DO_COMPILE" = "1" ] && export DISABLE_ADDMM_HIP_LT=1

"$PY" - "$DEVICE" "$STEPS" "$DO_COMPILE" "$COMPILE_TIMEOUT" <<'PY'
import os, signal, sys, time
import torch
import torch.nn as nn

device_arg, steps, do_compile, compile_timeout = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", int(sys.argv[4])
compile_skip = sys.argv[5] if len(sys.argv) > 5 else ""
fail = []

print(f"torch        : {torch.__version__}")
print(f"HIP runtime  : {torch.version.hip}")

if device_arg == "cuda":
    if not torch.cuda.is_available():
        print("[x] 要求 cuda 但 torch.cuda.is_available() == False")
        sys.exit(1)
    dev = torch.device("cuda:0")
    print(f"device       : {torch.cuda.get_device_name(0)}")
else:
    dev = torch.device("cpu")
    print("device       : CPU（自我測試）")

torch.manual_seed(0)

# 小型 MLP：足以觸發 GEMM/激活/反向，又不會太慢
model = nn.Sequential(
    nn.Linear(256, 512), nn.GELU(),
    nn.Linear(512, 512), nn.GELU(),
    nn.Linear(512, 10),
).to(dev)

opt = torch.optim.AdamW(model.parameters(), lr=1e-3)
loss_fn = nn.CrossEntropyLoss()
x = torch.randn(512, 256, device=dev)
y = torch.randint(0, 10, (512,), device=dev)

def run_steps(m, n):
    losses = []
    t0 = time.perf_counter()
    for _ in range(n):
        opt.zero_grad(set_to_none=True)
        out = m(x)
        loss = loss_fn(out, y)
        loss.backward()
        if dev.type == "cuda":
            torch.cuda.synchronize()
        opt.step()
        losses.append(loss.item())
    if dev.type == "cuda":
        torch.cuda.synchronize()
    dt = time.perf_counter() - t0
    return losses, dt

# ---------------- eager ----------------
print("\n[eager] forward + backward")
losses, dt = run_steps(model, steps)
gnorm = float(torch.nn.utils.clip_grad_norm_(model.parameters(), 1e9))
finite = all(map(lambda v: v == v and abs(v) != float("inf"), losses))
decreased = losses[-1] < losses[0]
print(f"loss         : first={losses[0]:.4f} last={losses[-1]:.4f}")
print(f"grad norm    : {gnorm:.4f}")
print(f"time         : {dt*1000/steps:.2f} ms/step（{steps} 步）")
if finite and decreased and gnorm > 0:
    print("eager        : PASS")
else:
    print("eager        : FAIL（loss 未下降或梯度異常）")
    fail.append("eager")

# ---------------- autocast fp16 ----------------
print("\n[autocast fp16] forward + backward")
try:
    model.zero_grad(set_to_none=True)
    with torch.autocast(device_type=dev.type, dtype=torch.float16):
        out = model(x)
        loss = loss_fn(out, y)
    loss.backward()
    if dev.type == "cuda":
        torch.cuda.synchronize()
    print(f"loss         : {loss.item():.4f}")
    print("autocast     : " + ("PASS" if loss.item() == loss.item() else "FAIL（NaN/Inf）"))
    if loss.item() != loss.item():
        fail.append("autocast")
except Exception as e:
    print(f"autocast     : FAIL（{type(e).__name__}: {e}）")

# ---------------- torch.compile ----------------
if do_compile and dev.type == "cuda":
    print(f"\n[torch.compile] 首次編譯上限 {compile_timeout}s（DISABLE_ADDMM_HIP_LT={os.environ.get('DISABLE_ADDMM_HIP_LT','0')}）")

    def _timeout(signum, frame):
        raise TimeoutError(f"compile 超過 {compile_timeout}s")

    signal.signal(signal.SIGALRM, _timeout)
    signal.alarm(compile_timeout)
    try:
        cmodel = torch.compile(model)
        t0 = time.perf_counter()
        out = cmodel(x)
        loss = loss_fn(out, y)
        loss.backward()
        torch.cuda.synchronize()
        compile_s = time.perf_counter() - t0
        signal.alarm(0)
        # 編譯後的穩定態
        _, dt_c = run_steps(cmodel, max(3, steps // 2))
        print(f"compile time : {compile_s:.1f}s")
        print(f"time         : {dt_c*1000/max(3, steps//2):.2f} ms/step（編譯後）")
        print("compile      : PASS")
    except TimeoutError as e:
        signal.alarm(0)
        print(f"compile      : TIMEOUT（{e}）→ 可先跳過 compile，功能不受影響")
    except Exception as e:
        signal.alarm(0)
        print(f"compile      : FAIL（{type(e).__name__}: {e}）")
        print("               建議：export DISABLE_ADDMM_HIP_LT=1、或先不用 compile")
elif do_compile:
    print("\n[torch.compile] 略過（CPU 模式）")
elif compile_skip:
    print(f"\n[torch.compile] 略過（{compile_skip}）")
else:
    print("\n[torch.compile] 已用 --no-compile 略過")

print()
if fail:
    print("RESULT: FAIL（" + ", ".join(fail) + "）")
    sys.exit(1)
print("RESULT: PASS")
PY

RC=$?
echo
if [ "$RC" -eq 0 ]; then
    ok "煙測通過（eager 訓練可用）"
else
    warn "煙測失敗（rc=$RC）— 請看上面 eager 區塊"
fi
exit "$RC"
