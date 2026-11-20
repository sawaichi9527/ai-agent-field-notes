# tools/linux/rocm — operational toolkit for `gfx1151`

These are **not probes**. They change the system when asked to, which is why every script carries the
usual machine-readable header and every mutating action is behind an explicit flag.

Provenance: [case 2026-11-20 — ROCm 10.1 → 10.2 co-install](../../../cases/2026-11-20-rocm-10.2-coexist-upgrade/),
facts in [docs/rocm-gfx1151.md](../../../docs/rocm-gfx1151.md), method in
[playbook 0016](../../../playbooks/0016-version-you-can-undo.md) and
[0017](../../../playbooks/0017-version-comparison-needs-pairing.md).

## Pick by question

| I want to know / do | Script | Mutates? | Needs |
|---|---|---|---|
| Which ROCm versions are installed, which one is current, what is disk usage | [`rocm-version-switch.sh --status`](rocm-version-switch.sh) | no | dpkg, update-alternatives |
| Would installing version X remove anything? | `rocm-version-switch.sh --plan X` | no | apt lists |
| Is the current version actually working (GPU visible, kernel runs) | `rocm-version-switch.sh --verify` | no | `/dev/kfd` |
| How fast is the current version (median bandwidth, warmup included) | `rocm-version-switch.sh --bench 30` | no | `/dev/kfd` |
| Install version X **beside** the existing one, keep the old one | `rocm-version-switch.sh --install X` | **yes** (packages + alternatives) | root, network |
| Roll back to version X | `rocm-version-switch.sh --use X` | **yes** (alternatives only) | root |
| Restore alternatives from a saved snapshot | `rocm-version-switch.sh --restore FILE` | **yes** | root |
| Remove one version, keep the other | `rocm-version-switch.sh --remove X` | **yes** | root |
| Compare two versions properly (warmup, cooling, A/B/B/A, averaging) | [`bench-ab.sh`](bench-ab.sh) | temporarily (restores) | `/dev/kfd`, sudo |
| Create a pinned PyTorch venv and verify a real GPU matmul | [`setup-torch.sh`](setup-torch.sh) | venv only | python3.14, network |
| Does training work (eager, fp16 autocast, `torch.compile`) | [`smoke-torch.sh`](smoke-torch.sh) | no | existing venv, `/dev/kfd` |
| Fresh machine: install ROCm at all | [`install-rocm.sh`](install-rocm.sh) | **yes** | root, network |

## Safety model

- `--plan` is the gate: it runs `apt-get -s` and **refuses to continue** if the simulation would
  remove a package. `--install` repeats that check before touching anything.
- Every mutating run stores a snapshot (`update-alternatives` selections + installed versions) under
  `$ROCM_SWITCH_STATE` (default `~/.local/state/rocm-switch/`). Logs and TSVs from `bench-ab.sh` go to
  `$ROCM_BENCH_OUT` (default `~/.local/state/rocm-switch/bench/`).
- Nothing removes the *other* version automatically. `--remove` only removes what you name, and
  refuses to remove the last usable version unless you use `--purge`.
- `install-rocm.sh` stops if any `amdrocm*` package is already installed — so a human who means
  "upgrade" cannot accidentally trigger a reinstall; `--force` is the explicit override.

## Platform

| | Strix Halo | Gorgon Halo |
|---|---|---|
| Example SKUs | Ryzen AI Max+ 395 / 390 | Ryzen AI Max+ PRO 495 |
| gfx target | `gfx1151` | `gfx1151` |
| Packages used | `amdrocm-*-gfx1151` | same |
| `install-rocm.sh` gfx detection | by CPU model table | same (495 included) |

`gfx` is auto-detected from the installed package suffix (or `--gfx`). Nothing in the toolkit is
tied to a specific SKU; absolute performance numbers are, so re-run `--bench` on each machine.

## Files

```
rocm-version-switch.sh   install / switch / roll back / verify / bench  (the only entry point you need)
bench-ab.sh              paired A/B across versions, compiles src/bench-vector-add.cpp
setup-torch.sh           pinned torch venv + GPU verification
smoke-torch.sh           training smoke test (eager / autocast / torch.compile)
install-rocm.sh          fresh install only
src/hip-vector-add.cpp   4194304-element vector add (correctness smoke test)
src/bench-vector-add.cpp 16M-element, warmup + N samples, median/min bandwidth
```
