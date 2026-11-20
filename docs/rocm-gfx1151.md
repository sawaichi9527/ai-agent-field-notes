# ROCm on `gfx1151` (Ryzen AI Max 395 / PRO 495) — facts worth not rediscovering

Scope: Ubuntu 26.04.x, ROCm Core SDK 10.x (TheRock packaging, `amdrocm*` debs), the integrated GPU of
**Ryzen AI Max+ 395 (Strix Halo)** and **Ryzen AI Max+ PRO 495 (Gorgon Halo)**. Both are `gfx1151`
(RDNA 3.5); everything below applies to both. Numbers were measured on a 495; treat absolute
bandwidth as machine-specific and the *procedures* as portable.

## 1. Packaging model (this is what makes rollback cheap)

| Fact | Value |
|---|---|
| Build system | TheRock since 7.14.0 — not the legacy `/opt/rocm-7.x` layout |
| Install dir | `/opt/rocm/core-<major.minor>` (e.g. `core-10.1`, `core-10.2`) |
| Package names | `amdrocm-<component><major.minor>[-<gfx>]`; **no** `Conflicts` between minor versions |
| Variants | `-gfx1151` (this hardware) · no suffix = every GPU (6 GB+, avoid) |
| "Current version" | `update-alternatives` groups (`core`, `core-10`, `hipcc`, `rocminfo`, `amd-smi`, `rocm-bin`, `rocm-lib`, `amdclang*`, …) |
| Rollback | point the groups back at the other `core-<version>` tree; no reinstall. A switch via `update-alternatives --set` pins the groups to **manual**; `rocm-version-switch.sh --auto` hands them back to auto mode |

`apt full-upgrade` never crosses a minor version here, because the meta-package name contains the
version. Installing a new minor version is a **co-install** (see [playbook 0016](../playbooks/0016-version-you-can-undo.md)).

## 2. Kernel and firmware requirements

- `gfx1151` needs specific **KFD** fixes (queue creation and memory-availability checks). Without
  them, compute may fail to initialize or behave unpredictably.
- Ubuntu **26.04 generic (kernel 7.0)** ships them; verified on `7.0.0-44-generic`.
- Ubuntu 24.04 needs HWE ≥ `6.17.0-19.19~24.04.2` (or OEM ≥ `6.14.0-1018`). Other distros: ≥ 6.18.4.
- Use the **inbox `amdgpu`**. Do **not** install `amdgpu-dkms` / `amdgpu-dkms-firmware`: it replaces
  the inbox driver and can bring an MES firmware that hangs this class of APU.
- Check: `modinfo -n amdgpu` must resolve inside `/lib/modules/$(uname -r)`; `/sys/module/amdgpu/version`
  must not exist; `/lib/firmware/updates/amdgpu/` must be empty.

## 3. Memory: GTT, not VRAM

- No dedicated VRAM: the iGPU maps system RAM. The pool AI workloads actually use is **GTT**, capped by
  TTM: `/sys/module/ttm/parameters/pages_limit` (pages of 4 KiB).
- Default is ≈50 % of RAM. Raise it deliberately (kernel cmdline `ttm.pages_limit=` or `amd-ttm --set`),
  then confirm from the app side (`torch.cuda.mem_get_info`, `rocminfo` "Total global mem").
- `amdgpu.gttsize` is **deprecated** and conflicts with TTM; do not use it.
- Keep the BIOS dedicated-VRAM carveout small and let GTT carry the load.

## 4. Version facts (10.1 vs 10.2)

| | 10.1.0 (2026-10-05) | 10.2.0 (2026-11-18) |
|---|---|---|
| HIP | 7.16.0 | 7.17.0 |
| AMD SMI | 27.1.0 | 27.2.0 |
| LLVM | 24 | 24 (newer build) |
| PyTorch / JAX | 2.14.0 / 0.11.1 | 2.15.0 / 0.11.2 |
| vLLM / SGLang | 0.29.0 / 0.5.18 | 0.32.0 / 0.5.21 |
| Headline | hipFile async fast path, host-NUMA VMM, hipThreads, `rocm-smi` removed | device-wide SPM counters, `rocsys`, complex GEMM in hipBLASLt, `rocm-smi` shim returns (deprecated) |

Release cadence is six weeks; 10.3.0 is expected early next year and will be later than six weeks.

## 5. PyTorch on 10.2: the venv carries its own ROCm

Since 10.2 the TheRock-built wheel installs ROCm **as a dependency** instead of bundling it inside
`torch`:

```
$VENV/lib/python3.14/site-packages/_rocm_sdk_core/lib/libamdhip64.so.7
libtorch_hip.so RUNPATH = $ORIGIN/../../_rocm_sdk_core/lib/…
```

Consequences:

- `torch` uses the venv's ROCm, **not** `/opt/rocm`; switching the system version does not affect it.
  To run torch on an older ROCm, build a separate venv pinned to that `+rocmX.Y.Z` wheel.
- The venv is large (6.8 GB with torch + torchvision + triton).
- Pins that exist for `gfx1151` on 10.2 (checked against AMD's index): `torch==2.15.0+rocm10.2.0`,
  `torchvision==0.29.2+rocm10.2.0`, `torchaudio==2.11.1+rocm10.2.0`.
- `torch.compile` needs **`python3.14-dev`** (Inductor compiles a C shim with gcc; missing `Python.h`
  produces `fatal error: Python.h: no such file or directory`).
- Set `DISABLE_ADDMM_HIP_LT=1` for compiled training on `gfx1151`: hipBLASLt has no fallback Tensile
  kernels for this target, so the GEMM path otherwise JIT-compiles. Measured effect: first compile
  2.0 s instead of minutes, compiled step 1.09 ms vs eager 12.87 ms (small MLP, 11.8×).

## 6. vLLM: container, not a local pip install

Treat vLLM as a container workload on these boxes. A local install drags its own compiled artifacts
into the torch venv and couples two upgrade cycles. Run the ROCm-based image with:

```sh
--device=/dev/kfd --device=/dev/dri --group-add video --group-add render
```

## 7. Known issues to expect

| Symptom | Status |
|---|---|
| `rocm-smi` missing after 10.1 | intentional; use `amd-smi`. 10.2 ships a deprecated Python `rocm-smi` again — still use `amd-smi` |
| `amd-smi` shows `N/A` for power/clocks on `gfx1151` | known; read sysfs/hwmon instead |
| `HSA_OVERRIDE_GFX_VERSION` suggested by old guides | **do not set it** on 10.x; `gfx1151` is natively supported, overriding can produce `hipErrorInvalidImage 209` |
| `torch.compile` very slow / huge a_grid logs | hipBLASLt fallback gap → `DISABLE_ADDMM_HIP_LT=1` |
| `ROCm origami GEMM selection is not supported on ROCm 10.0+` | PyTorch-side limitation in Inductor; affects compiled GEMM tuning only |
| 10.2 AI workloads fail on Ryzen APUs | documented for **WSL2** only (gfx1150/1151/1152/1103/1153); bare-metal Ubuntu not affected |

## 8. Measured baseline (495 and 395, Ubuntu 26.04, kernel 7.0.0-44)

495 (182 GiB, `ttm.pages_limit` 160 GiB):

| Measurement | Value |
|---|---|
| Vector-add bandwidth (16M floats, 192 MiB/iter, warmup 10, median of 50) | **239 GB/s** (10.1: 239.2, 10.2: 239.1) |
| LPDDR5X theoretical (256-bit) | 256 GB/s → ≈93 % |
| `rocminfo` vs HIP compute units | 40 CU reported, HIP `multiProcessorCount` 20 (WGP granularity) |
| PyTorch eager / compiled step (MLP 256-512-512-10, batch 512) | 12.87 ms / 1.09 ms |

Same measurement on a **395** (121 GiB, `ttm.pages_limit` 100 GiB), 2026-11-20:

| Measurement | 495 | 395 |
|---|---|---|
| Vector-add bandwidth (single run, warmup 10, median of 30) | 239.1 GB/s (10.2) | **228.4 GB/s** (10.2) |
| Paired A/B/B/A, per-version mean | 10.1 239.2 / 10.2 239.1 | 10.1 226.1 / 10.2 225.0 (−0.46 %, sign flips with position → equal) |
| LPDDR5X theoretical (256-bit) | ≈93 % | ≈89 % |
| PyTorch eager / compiled ms/step (MLP 256-512-512-10, batch 512) | 12.87 / 1.09 | 14.37 / 1.15 |

The 395 lands in the same bandwidth class but not at the same number: re-measure rather than copying
it. Full sheet: [`cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/395-baseline.md`](../cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/395-baseline.md).

## 9. Bring-up checklist for the second `gfx1151` machine (e.g. a 395)

> This section is the summary; the step-by-step handover page is
> [`docs/rocm-395-handover.md`](rocm-395-handover.md).

The procedure below was written on a 495 and applies unchanged to a 395; only the measured numbers
differ. On a **fresh** machine skip the co-install part and install 10.2 directly.

1. **Confirm the platform before installing anything**

   ```sh
   uname -r                                  # Ubuntu 26.04: 7.0.0-xx-generic is fine
   lscpu | grep -E 'Model name|型號名稱'      # expect "Ryzen AI Max+ 395" / "PRO 495"
   modinfo -n amdgpu                         # must be inside /lib/modules/$(uname -r)
   test -e /sys/module/amdgpu/version && echo "DKMS LEAK" || echo "inbox ok"
   ls /lib/firmware/updates/amdgpu/ 2>/dev/null   # must be empty/absent
   ```

2. **Install (fresh machine: 10.2 only; no need to install 10.1 first)**

   ```sh
   bash tools/linux/rocm/install-rocm.sh --check     # read-only, detects gfx and the repo
   sudo bash tools/linux/rocm/install-rocm.sh        # installs the -gfx1151 variant
   # if ROCm already exists, it stops and points you at rocm-version-switch.sh instead
   ```

3. **Verify, then take a baseline** (numbers from another machine are not a baseline)

   ```sh
   bash tools/linux/rocm/rocm-version-switch.sh --verify
   bash tools/linux/rocm/rocm-version-switch.sh --bench 30
   # or emit the whole baseline sheet in one read-only pass:
   bash tools/linux/rocm/collect-baseline.sh --iters 50 --out /tmp/baseline.md
   ```

   Paste it into `cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/395-baseline.md` (template
   included) and open a PR — that is how the second machine's numbers become comparable instead of
   anecdotal.

4. **PyTorch** (per-machine venv; it carries its own ROCm)

   ```sh
   bash tools/linux/rocm/setup-torch.sh --vision
   sudo apt install python3.14-dev        # only needed for torch.compile
   bash tools/linux/rocm/smoke-torch.sh
   ```

5. **Expect these to match, and these to differ**

   | Should match | Will differ |
   |---|---|
   | `gfx1151`, package names, kernel requirements, alternatives behaviour | core count / SKU, RAM (e.g. 128 vs 182 GiB), measured bandwidth |
   | ROCm 10.2 component versions (HIP 7.17, SMI 27.2) | thermal envelope and fan curve → benchmark variance |
   | rollback procedure (`--use 10.1` if 10.1 is present) | whether GTT tuning is needed at all (depends on RAM) |

6. **Only if large-model loads fail**: raise GTT via `ttm.pages_limit` (section 3), then re-check
   `rocminfo` "Total global mem" from the app side. Do not copy another machine's page count blindly.

## 10. Do not

- `apt install amdrocm` (all-architecture meta, 6 GB+)
- `apt full-upgrade` expecting a ROCm version change (it does not)
- `amdgpu-dkms`, `amdgpu.gttsize`, `HSA_OVERRIDE_GFX_VERSION`
- mix Ubuntu's archive ROCm (`rocm` 7.1) with AMD's `amdrocm*`: same `/usr/bin` paths, alternatives fight
