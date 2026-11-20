# Case: two ROCm versions on one box — 10.2 installed, 10.1 still bootable

**Tool:** ROCm Core SDK **10.1.0-3 → 10.2.0-2** (TheRock packaging, `amdrocm*` debs) · **Hardware:**
AMD Ryzen AI Max+ PRO 495 / Radeon 8065S, 160 GiB GTT, 182 GiB unified memory · **OS:** Ubuntu 26.04.1
LTS, kernel `7.0.0-44-generic` (inbox `amdgpu`) · **Date:** 2026-11-20
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the numbers and the false starts)
**Tools:** [`tools/linux/rocm/`](../../tools/linux/rocm/) — `rocm-version-switch.sh`, `bench-ab.sh`,
`setup-torch.sh`, `smoke-torch.sh`

## Symptom

ROCm 10.2.0 shipped on 2026-11-18, two days before this was written. The box ran 10.1.0 (installed
2026-10-12) and the requirement was **not** "get 10.2" but "get 10.2 **and keep 10.1**".

The obvious commands are wrong in two different ways:

| Command | What actually happens |
|---|---|
| `sudo apt update && sudo apt full-upgrade` | nothing: `apt list --upgradable` contains **no** `amdrocm*` (the 10.1 meta does not depend on 10.2) |
| `sudo apt install amdrocm-core-sdk10.2-gfx1151` | installs **55 new** packages next to 10.1, **0 removed** — but which one the `hipcc`/`rocminfo`/`amd-smi` commands point at is decided by `update-alternatives` |

## What was measured

| Question | Answer |
|---|---|
| Does installing 10.2 remove 10.1? | **No.** `apt-get -s` → `0 upgraded, 55 newly installed, 0 to remove and 1 not upgraded` |
| Where do the two versions live? | `/opt/rocm/core-10.1` and `/opt/rocm/core-10.2`; `/opt/rocm/core` is the alternatives link |
| Did the switch need manual work? | **No.** 10.2's postinst re-registered 26 alternative groups to `core-10.2` on its own |
| Rollback cost | **one command**, no download, no reinstall: `update-alternatives --set core /opt/rocm/core-10.1` (plus the other groups) |
| Performance difference | **+0.05 %** (0.8414 vs 0.8418 ms median, paired A/B/B/A, 50 samples, 20 s cooldown) |
| Is PyTorch on 10.2 using `/opt/rocm`? | **No** — since 10.2 the wheel installs ROCm into the venv (`_rocm_sdk_core`), so a system rollback does not touch the venv |

## Two false results worth keeping

1. **62.8 GB/s looked like a 34 % regression.** It was a single kernel launch with no warmup
   (`--verify` smoke test). Steady state is 237–242 GB/s; the LPDDR5X ceiling is 256 GB/s.
2. **+2.2 % looked like a 10.2 regression.** Reversing the A/B order flipped the sign (10.2 became
   *faster*), and with cooldown the difference collapsed to +0.05 %. The second measurement in a pair
   is always slower, regardless of version.

## Reproduce

```bash
bash tools/linux/rocm/rocm-version-switch.sh --status      # what is installed, what is pointed at
bash tools/linux/rocm/rocm-version-switch.sh --plan 10.2   # apt simulation, must say 0 to remove
sudo bash tools/linux/rocm/rocm-version-switch.sh --install 10.2
bash tools/linux/rocm/rocm-version-switch.sh --verify
bash tools/linux/rocm/bench-ab.sh --series "10.1 10.2 10.2 10.1" --iters 50 --cooldown 20
sudo bash tools/linux/rocm/rocm-version-switch.sh --use 10.1   # rollback
```

## Second machine

A blank measurement sheet is checked in at [`evidence/395-baseline.md`](evidence/395-baseline.md);
`tools/linux/rocm/collect-baseline.sh` prints the same structure read-only, so filling it means
copying numbers rather than re-deriving them.

## Applies to

Both **Ryzen AI Max+ 395 (Strix Halo)** and **PRO 495 (Gorgon Halo)** are `gfx1151`, and the
packaging, kernel requirement and rollback mechanics are identical. Only core count, memory size and
absolute bandwidth differ. See [`docs/rocm-gfx1151.md`](../../docs/rocm-gfx1151.md).
