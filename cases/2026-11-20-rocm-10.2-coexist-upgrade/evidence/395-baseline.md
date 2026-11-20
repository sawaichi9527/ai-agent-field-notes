# Baseline: 395 / ROCm 10.2.0 (2026-11-20) — TEMPLATE

> **Status: template.** The 495 numbers are real (measured 2026-11-20); every `TBD` belongs to the
> second machine and should be filled from measurement, not assumed.
>
> How to fill it:
>
> 1. On the 395, from the repo root:
>    ```sh
>    bash tools/linux/rocm/collect-baseline.sh --iters 50 --out /tmp/395-baseline.md
>    ```
>    It is read-only and prints the system, ROCm state, verification, benchmark and torch sections.
> 2. Copy the output over the `TBD` cells below (or replace this file's body with it). Delete rows
>    that do not apply; keep the two comparison tables.
> 3. Run `bash tools/linux/rocm/smoke-torch.sh` and paste its eager/compile lines into the PyTorch
>    table.
> 4. Re-read [SANITIZE.md](../../../SANITIZE.md): no hostname, no user name, no LAN IP. Paths as `~`.
> 5. PR title: `docs: add Ryzen AI Max+ 395 baseline for ROCm 10.2 (gfx1151)`.

## System

| Item | 495 (measured) | 395 (TBD) |
| --- | --- | --- |
| SKU | AMD Ryzen AI Max+ PRO 495 / Radeon 8065S | TBD |
| RAM | 182 GiB | TBD |
| OS / kernel | Ubuntu 26.04.1 / 7.0.0-44-generic | TBD |
| amdgpu | inbox (no dkms) | TBD |
| `ttm.pages_limit` | 41943040 pages ≈ 160 GiB | TBD |

## Version identity

| Item | 495 (measured) | 395 (TBD) |
| --- | --- | --- |
| ROCm | 10.2.0 (10.1.0 still installed) | TBD |
| HIP runtime | 7.17.26434 | TBD |
| AMD SMI | 27.2.0 | TBD |
| clang | 24.0.0git (`bdc35841`) | TBD |
| gfx target | gfx1151 | TBD |

## Verification

```
# paste the `--verify` tail here: rocminfo line, HIP PASS line, device name
```

## Benchmark (16M floats, 192 MiB/iter, warmup 10, 50 samples)

| Metric | 495 (measured) | 395 (TBD) |
| --- | --- | --- |
| median ms | 0.8418 (10.2) / 0.8414 (10.1) | TBD |
| min ms | 0.8376–0.8452 range | TBD |
| median bandwidth | 239 GB/s | TBD |
| ceiling (LPDDR5X 256-bit) | 256 GB/s | same |

If both minors are installed on the 395, run the paired form and report both:

```sh
bash tools/linux/rocm/bench-ab.sh --series "10.2 10.1 10.1 10.2" --iters 50 --cooldown 20
```

## PyTorch

| Item | 495 (measured) | 395 (TBD) |
| --- | --- | --- |
| torch | 2.15.0+rocm10.2.0 | TBD |
| torchvision | 0.29.2+rocm10.2.0 | TBD |
| venv size | 6.8 GB | TBD |
| eager ms/step (MLP 256-512-512-10, batch 512) | 12.87 | TBD |
| compiled ms/step | 1.09 | TBD |
| compile time | 2.0 s | TBD |

## Notes / deltas worth explaining

- Thermal or fan-curve differences that showed up as run-to-run spread: TODO
- Anything from the 495 write-up that did **not** reproduce: TODO
- GTT tuning needed? (only if large-model loads failed): TODO
