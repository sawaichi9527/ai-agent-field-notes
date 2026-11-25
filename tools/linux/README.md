# tools/linux — status: 7 probes + a ROCm toolkit

The agent-CLI probes answer narrow questions surfaced by the Linux cases: desktop entry identity,
package variant identity, launch-chain stage, what an engine actually streamed, and — added with the
2026-11-20 timeout case — time-to-first-token alone versus behind a queue.

## Written

| Probe | Question | Needs |
|---|---|---|
| [`probe-desktop-match.sh`](probe-desktop-match.sh) | does a window's `app_id` resolve to a **usable** `.desktop` entry — by which rule, with every matched entry's `Icon` resolving, and with no invalid entry hiding from GLib? | python3 + PyGObject + Gtk 3 typelib |
| [`probe-package-variant.sh`](probe-package-variant.sh) | of two conflicting packages, which is installed, and does it own the file that carries the capability? | dpkg (read-only) |
| [`probe-appimage-launch-chain.sh`](probe-appimage-launch-chain.sh) | when a menu click does nothing: is the entry valid, is an integrator GUI in the path, is the Chromium singleton lock stale, is the window merely hidden? | bash + procps; optional xwininfo, desktop-file-validate |
| [`probe-sse-delta-mix.py`](probe-sse-delta-mix.py) | when a UI's "N tokens" stops moving: what did the engine actually stream, how much of it was text vs tool-call arguments, and is one argument string repeating? | python3 + a server log with verbatim SSE packets |
| [`probe-ttft-under-contention.py`](probe-ttft-under-contention.py) | a stalled request produced zero bytes — is the model slow, is the prompt cache cold, or was the request second in line behind a single-slot server? | python3 + an OpenAI-compatible streaming endpoint (bearer token in `TTFT_API_KEY`) |
| [`grace/kernel-default-status.sh`](grace/kernel-default-status.sh) | which kernel does `GRUB_DEFAULT` point at, which kernel lineages are installed (nvidia-64k vs generic), and is the fallback lineage shielded from `apt autoremove`? | dpkg + apt-mark (read-only) |
| [`probe-nuc6-audio.sh`](probe-nuc6-audio.sh) | audio is silent although ALSA/PipeWire report it healthy: is the config layer broken (SOF/AVS grabbing `00:1f.3`, `power_save`, a `model=` name that does not exist), or is every register open and the fault past the codec? | bash + amixer + pactl (read-only) |

Exit code is `0` when identity resolves, every matching entry's `Icon` resolves at at least one
standard size, and no explicit/exec-referencing entry is invalid; `1` when the window would fall back
to the generic icon or could bind to an entry with a missing icon. It also reports hidden duplicates
(`NoDisplay=true` may still match windows) and structurally invalid entries that
`Gio.AppInfo.get_all()` silently drops. Used by [playbook 0006](../../playbooks/0006-window-identity-not-icon.md),
[`cases/2026-11-02-appimage-dock-gear-linux/`](../../cases/2026-11-02-appimage-dock-gear-linux/) and
[`cases/2026-11-02-appimage-desktop-structural-repair/`](../../cases/2026-11-02-appimage-desktop-structural-repair/).

`probe-ttft-under-contention.py` sends cache-hostile payloads (random salt prefix) and reports
`ttfb` vs first-token separately, reading `prompt_tokens` back from `usage` instead of estimating from
characters. Run it three ways — cold alone, the same payload again (`--warm`, expect sub-second if the
prefix cache is answering), and `--concurrency 2` (second request's TTFT ≈ 2× the first means the
server has exactly one slot). Used by [playbook 0019](../../playbooks/0019-a-timeout-measures-queue-position.md)
and [`cases/2026-11-20-hermes-stale-breaker-latched/`](../../cases/2026-11-20-hermes-stale-breaker-latched/).

`probe-package-variant.sh` exits `0` when the variant package is installed **and** owns the
capability artifact, `1` otherwise — usable as an upgrade guard. Used by
[playbook 0007](../../playbooks/0007-same-version-different-artifact.md) and
[`cases/2026-11-04-rustdesk-wayland-unattended/`](../../cases/2026-11-04-rustdesk-wayland-unattended/).

`probe-nuc6-audio.sh` exits `1` when the config layer is broken (SOF/AVS loaded, `power_save` not 0,
a `model=` that is not one of the four ALC283 fixup names, or no card) and `0` when every stage reads
open — the point where the answer stops being a setting. Used by
[playbook 0025](../../playbooks/0025-power-cycle-resets-what-reboot-cannot.md) and
[`cases/2026-11-25-nuc6-alc283-cold-boot-not-reboot/`](../../cases/2026-11-25-nuc6-alc283-cold-boot-not-reboot/).

## ROCm toolkit (not probes)

[`rocm/`](rocm/) holds five scripts that **operate on** ROCm instead of observing it: version
co-install / switch / rollback, paired A/B benchmarking, a pinned PyTorch venv, a training smoke
test, and a fresh installer. They change packages and `update-alternatives`, so start at
[`rocm/README.md`](rocm/README.md) and use `--status` / `--plan` / `--verify` first.
Background: [case 2026-11-20](../../cases/2026-11-20-rocm-10.2-coexist-upgrade/),
[docs/rocm-gfx1151.md](../../docs/rocm-gfx1151.md).

## What is still needed (agent-CLI probes)

| Windows probe | Linux equivalent | Notes |
|---|---|---|
| `measure-dsh-web.ps1` (time to first URL + CPU time) | shell script reading `/proc/<pid>/stat` fields 14+15 (utime+stime) before signal | must sample before the process is stopped; `/proc` disappears on exit |
| `watch-console-windows.ps1` (who created the window) | `bpftrace`/`execsnoop`, or `auditd` `-a always,exit -S execve` | no window object exists; attribute via parent PID of `execve` |
| `observe-consoles.ps1` (who is polling) | `perf trace -e syscalls:sys_enter_execve` over a fixed window | same idea, different observation surface |
| `Get-Process … MainWindowHandle` | not applicable | no console concept; "terminal" is the TTY of the session |

## Rules that carry over unchanged

- CPU time ÷ wall time classifies busy vs waiting on every OS.
- Validate the instrument before trusting a negative result (see
  [playbook 0002](../../playbooks/0002-sandbox-measurements-lie.md)).
- Cadence is a fingerprint; match it to source code (see
  [playbook 0004](../../playbooks/0004-separate-correlated-causes.md)).

## Rules that do not carry over

- `windowsHide`, `detached`, `CREATE_NO_WINDOW`, `conhost.exe` — Windows-only concepts.
- Anything about focus stealing: on Linux the analogue is a terminal window raised by the window
  manager, which is a different mechanism entirely.

If you add a probe here, include the exact command used to collect the evidence in the case
write-up — the value of this repo is reproducibility.
