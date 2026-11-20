# Baseline: Ryzen AI Max+ 395 / ROCm 10.2.0 (2026-11-20) — MEASURED

> **Status: measured on the second machine** (2026-11-20, same day as the 495 case). Every number
> below was produced on this 395 by the checked-in scripts, not copied. The 495 column is the
> original case's measurement and is kept only for the side-by-side read.
>
> Filled from: `collect-baseline.sh`, `rocm-version-switch.sh --verify`, `--bench 30`,
> `bench-ab.sh --series "10.2 10.1 10.1 10.2" --iters 50 --cooldown 20`, and
> `setup-torch.sh --vision` + `smoke-torch.sh`. No `TBD` left.

## System

| Item | 495 (measured) | 395 (measured) |
| --- | --- | --- |
| SKU | AMD Ryzen AI Max+ PRO 495 / Radeon 8065S | AMD Ryzen AI Max+ 395 / Radeon 8060S |
| RAM | 182 GiB | 121 GiB (128 GB class) |
| OS / kernel | Ubuntu 26.04.1 / 7.0.0-44-generic | Ubuntu 26.04.1 / 7.0.0-44-generic |
| amdgpu | inbox (no dkms) | inbox — `modinfo -n amdgpu` → `/lib/modules/7.0.0-44-generic/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst`; no `/sys/module/amdgpu/version`; `/lib/firmware/updates/amdgpu/` empty |
| `ttm.pages_limit` | 41943040 pages ≈ 160 GiB | 26214400 pages ≈ 100 GiB (pre-existing, not changed by this run) |

## Version identity

| Item | 495 (measured) | 395 (measured) |
| --- | --- | --- |
| ROCm | 10.2.0 (10.1.0 still installed) | 10.2.0-2 (10.1.0-3 still installed; 55 packages per minor, `/opt/rocm/core-10.1` 8.7 G + `core-10.2` 9.2 G) |
| HIP runtime | 7.17.26434 | 7.17.26434-0000000 |
| AMD SMI | 27.2.0 | 27.2.0+2a0e6e67 |
| clang | 24.0.0git (`bdc35841`) | 24.0.0git (`bdc35841c97ff51400273b91d7bc05c96e19c2d9`) |
| gfx target | gfx1151 | gfx1151 |
| "Current version" | `update-alternatives` | `/opt/rocm/core` → `core-10.2` after install, restored to `core-10.2` after the A/B |

## Verification (395, normal user, after install)

```
rocminfo: Runtime Version 1.21 · AMD RYZEN AI MAX+ 395 w/ Radeon 8060S · gfx1151
amd-smi 27.2.0 · ROCm 10.2.0 · HIP 7.17.26434-0000000 · clang 24.0.0git (bdc35841)
HIP vector add, 4,194,304 elements: Mismatches 0 / 4194304, RESULT: PASS
Compute units: 20 (HIP WGP granularity) · Total global mem: 100.0 GiB
```

Component versions are **identical to the 495** — that part of the handover carried over exactly.

## Benchmark (16M floats, 192 MiB/iter, warmup 10)

Single version, `--bench 30` (no cooldown):

| Metric | 495 (measured) | 395 (measured) |
| --- | --- | --- |
| median ms | 0.8418 (10.2) / 0.8414 (10.1) | **0.8813** (10.2) |
| min ms | 0.8376–0.8452 range | 0.8790 |
| median bandwidth | 239 GB/s | **228.4 GB/s** (min 229.0) |
| ceiling (LPDDR5X 256-bit) | 256 GB/s → ≈93 % | 256 GB/s → **≈89 %** |

Paired A/B/B/A, `--iters 50 --cooldown 20` (the only form that can answer "is 10.2 slower?"):

| pos | version | median ms | GB/s |
| --- | --- | --- | --- |
| 1 | 10.2 | 0.9015 | 223.3 |
| 2 | 10.1 | 0.8862 | 227.2 |
| 3 | 10.1 | 0.8950 | 225.0 |
| 4 | 10.2 | 0.8880 | 226.7 |

- per-version mean: **10.2 0.8947 ms (225.0 GB/s)** vs **10.1 0.8906 ms (226.1 GB/s)** → 10.1 ahead by 0.46 %
- same-position pairs: pos1↔pos2 says 10.2 is 1.7 % slower; pos4↔pos3 says 10.2 is 0.78 % faster.
  **The sign flips with position**, so this is the order effect, not the version — exactly the
  495 finding, reproduced on the second machine.
- cold single-shot for reference only (no warmup, not comparable): 10.2 0.707 ms / 71.2 GB/s,
  10.1 0.839 ms / 60.0 GB/s.

## PyTorch

`setup-torch.sh --vision` then `smoke-torch.sh` on the 395 (venv under `~/venvs/rocm102`, 6.8 GB):

| Item | 495 (measured) | 395 (measured) |
| --- | --- | --- |
| torch | 2.15.0+rocm10.2.0 | 2.15.0+rocm10.2.0 |
| torchvision | 0.29.2+rocm10.2.0 | 0.29.2+rocm10.2.0 |
| HIP runtime inside the venv | 7.17.26434 | 7.17.26434 |
| venv size | 6.8 GB | 6.8 GB |
| eager ms/step (MLP 256-512-512-10, batch 512) | 12.87 | **14.37** (mean of 20) |
| compiled ms/step | 1.09 | **1.15** |
| `torch.compile` first-compile time | 2.0 s | **2.0 s** |

Correctness on the 395: matmul max abs err **2.289e-04** vs CPU, autocast fp16 PASS,
`torchvision.ops.nms` OK, loss 2.3050 → 0.1408, grad norm 0.2092.

Prerequisites observed: `python3.14-dev` is required (Inductor compiles a C shim and dies on
`Python.h` without it) and `python3.14-venv` for the venv itself; neither was installed before this
run. `DISABLE_ADDMM_HIP_LT=1` is set by the script. The
`ROCm origami GEMM selection is not supported on ROCm 10.0+` warning appears as documented and is
harmless.

## Notes / deltas worth explaining

- The 395 lands at ≈89 % of the LPDDR5X ceiling vs the 495's ≈93 %: same bandwidth class, different
  thermal envelope / memory bin. Re-measure per machine; do not carry the number over.
- **Alternatives leftovers after a switch.** Groups that exist only in 10.2 (`rocm-smi`, `rocsys`,
  `rocprof-*`) stay pinned at `core-10.2` after `--use 10.1`, and the script warns about it. So a
  rollback to 10.1 is not 100 % pure: `hipcc` / `rocminfo` / `amd-smi` do move, those extra tool
  groups do not. Harmless for compute, worth knowing before diffing "which version am I on".
- **`--bench` was broken as shipped** on this box: `do_bench` looked only for
  `.rocm-verify/bench-vector-add.cpp` while the source lives in `tools/linux/rocm/src/`. Fixed in the
  same PR (plus `HIP_SRC`'s no-op fallback and the `sample` expectation text — `0x3f` fill is ≈0.747,
  so `a+b ≈ 1.494`, not 1.0; the measured 1.494 was correct all along).
