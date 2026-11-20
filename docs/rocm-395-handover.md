# Handover: bringing up a second `gfx1151` machine (395 / Strix Halo)

This is the concrete "do this on the other box" page. Background and reasoning live in
[`docs/rocm-gfx1151.md`](rocm-gfx1151.md); the measured case is
[`cases/2026-11-20-rocm-10.2-coexist-upgrade/`](../cases/2026-11-20-rocm-10.2-coexist-upgrade/).

Applies to: **Ryzen AI Max+ 395 (Strix Halo)** and **Ryzen AI Max+ PRO 495 (Gorgon Halo)** — both
`gfx1151`. Everything here was validated on the 495; the properties that carry over are package
names, kernel requirements and rollback mechanics. Absolute numbers do not carry over.

## 0. Get the toolkit

```sh
git clone https://github.com/sawaichi9527/ai-agent-field-notes
cd ai-agent-field-notes
```

## 1. Confirm the platform before installing anything

```sh
uname -r                                   # Ubuntu 26.04: 7.0.0-xx-generic
lscpu | grep -E 'Model name|型號名稱'       # "Ryzen AI Max+ 395" or "PRO 495"
modinfo -n amdgpu                          # must resolve inside /lib/modules/$(uname -r)
test -e /sys/module/amdgpu/version && echo 'DKMS LEAK — remove amdgpu-dkms' || echo 'inbox ok'
ls /lib/firmware/updates/amdgpu/ 2>/dev/null   # must be empty/absent
```

Do not install `amdgpu-dkms` on these APUs. It replaces the inbox driver and can bring MES firmware
that hangs the GPU.

## 2. Install ROCm

**Fresh machine** — install the current release directly; there is nothing to preserve yet:

```sh
bash tools/linux/rocm/install-rocm.sh --check          # read-only: gfx target, repo, disk, pitfalls
sudo bash tools/linux/rocm/install-rocm.sh             # installs amdrocm-*-gfx1151
```

**Machine that already has ROCm** — `install-rocm.sh` stops on purpose and points at the co-install
path:

```sh
bash tools/linux/rocm/rocm-version-switch.sh --status
bash tools/linux/rocm/rocm-version-switch.sh --plan 10.2   # must say 0 to remove
sudo bash tools/linux/rocm/rocm-version-switch.sh --install 10.2
```

## 3. Verify, then take *this machine's* baseline

```sh
bash tools/linux/rocm/rocm-version-switch.sh --verify
bash tools/linux/rocm/rocm-version-switch.sh --bench 30
```

`--verify` answers "does the GPU stack work"; `--bench` answers "how fast is this box". Do not skip
the second one and do not reuse another machine's number — thermal envelope and memory size differ.

## 4. PyTorch (per-machine venv; it carries its own ROCm)

```sh
bash tools/linux/rocm/setup-torch.sh --vision
sudo apt install python3.14-dev        # only needed for torch.compile (Python.h)
bash tools/linux/rocm/smoke-torch.sh
```

Expected pins on 10.2: `torch==2.15.0+rocm10.2.0`, `torchvision==0.29.2+rocm10.2.0`,
`torchaudio==2.11.1+rocm10.2.0`. Because the wheel installs ROCm **into the venv**, later system
ROCm switches do not disturb it.

## 5. Record the numbers (this is what makes the handover useful)

```sh
bash tools/linux/rocm/collect-baseline.sh --iters 50 --out /tmp/baseline.md
```

Paste into [`cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/395-baseline.md`](../cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/395-baseline.md)
(replace the `TBD` cells; the 495 column is already filled), re-read
[`SANITIZE.md`](../SANITIZE.md), then open a PR titled
`docs: add Ryzen AI Max+ 395 baseline for ROCm 10.2 (gfx1151)`.

## 6. What should match, and what will not

| Should match | Will differ |
|---|---|
| `gfx1151`, `amdrocm-*-gfx1151` package names | CPU SKU, core count, RAM size |
| kernel/firmware requirements, inbox driver | thermal envelope, fan curve, benchmark spread |
| ROCm component versions (HIP 7.17, SMI 27.2 on 10.2) | absolute bandwidth and ms/step |
| rollback procedure (`--use 10.1` if 10.1 present) | whether GTT tuning is needed at all |

## 7. If something looks wrong

| Symptom | First check |
|---|---|
| `rocminfo` cannot open `/dev/kfd` | are you in a sandbox/container? `id` shows `render`? |
| `amd-smi` shows `N/A` for clocks | known on `gfx1151`; read sysfs/hwmon instead |
| `torch.cuda.is_available()` false | installed `+rocm…` wheel, not CUDA; `render` group; `/dev/kfd` |
| `torch.compile` fails on `Python.h` | `sudo apt install python3.14-dev` |
| `torch.compile` takes minutes | `DISABLE_ADDMM_HIP_LT=1` (the smoke script sets it) |
| large model fails to load | raise GTT via `ttm.pages_limit`, then re-check from the app side |
| version changed unexpectedly after an `apt` run | `rocm-version-switch.sh --status`, then `--use 10.2` or `--restore <snapshot>` |

## 8. Do not copy from the 495

- page counts for `ttm.pages_limit` (depends on installed RAM)
- benchmark milliseconds or GB/s (depends on clocks/thermals)
- venv paths under `~` are per-user; the venv is not transferable
- any `HSA_OVERRIDE_GFX_VERSION` advice from older guides — `gfx1151` is natively supported on 10.x
