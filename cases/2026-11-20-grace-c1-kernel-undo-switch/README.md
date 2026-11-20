# Case: kernel boot default is a pointer, not a version — switch 1043 → 1067 and keep the rollback

**Tool:** Ubuntu kernel packages, `nvidia-64k` flavor · **Hardware:** NVIDIA Grace C1 (peer-a,
72-core Arm Neoverse V2) · **OS:** Ubuntu (non-x86 Grace), kernel lineage `6.8.0-XXXX-nvidia-64k`
· **Date:** 2026-11-20
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the numbers and the false starts)
**Tools:** [`tools/linux/grace/kernel-default-status.sh`](../../tools/linux/grace/kernel-default-status.sh)

## Symptom

The box booted `6.8.0-1043-nvidia-64k` and was asked to run `6.8.0-1067-nvidia-64k` — the newest
kernel in the same NVIDIA 64K lineage — **while keeping the ability to go back to 1043**, and
**without** `apt autoremove` (an ordinary, unthinking package-manager command) silently deleting the
rollback packages.

Two naive intuitions are wrong on this platform:

| Intuition | What is actually true |
|---|---|
| "The newest installed kernel is what boots" | No. Boot is decided by `GRUB_DEFAULT`, which is a **menuentry string**, not a version. `needrestart` reports the newest kernel as "expected" and GRUB's top-level 'Ubuntu' entry follows the newest install — both are noise against the pointer. |
| "A fallback kernel is another installed kernel, it stays" | No. `apt autoremove` has **already** consumed six intermediate kernels on this box (1055 → 1064 are all `rc`). A kernel the default no longer points at is exactly the shape of package apt autoremove prunes. |

## What was measured

| Question | Answer |
|---|---|
| Which kernel boots after the switch? | `6.8.0-1067-nvidia-64k` — `uname -r`, `/proc/cmdline` (`BOOT_IMAGE=/vmlinuz-6.8.0-1067-nvidia-64k`), `PAGE_SIZE=65536` |
| What does `GRUB_DEFAULT` say? | `Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-1067-nvidia-64k` (also the `set default` line in grub.cfg) |
| Does the 1043 rollback entry survive `update-grub`? | **Yes** — grub.cfg keeps a menuentry for *every* installed kernel (1043 at lines 223/237, recovery included), so rollback is flipping one string, no download |
| Is 1043 safe from `apt autoremove`? | The 7 packages of the 1043 lineage are `apt-mark manual` (verified via `apt-mark showmanual`); autoremove will not touch them |
| Did the switch add kernel-side risk? | **No.** kernel warn/err/fail lines per boot = **4 on boot 0 (1067) and 4 on boot -1 (1043)** — identical; `systemctl --failed` = 0 |

## The trap this case exists to show

Two different answers to "what boots next" live on the same box:

- **GRUB's top-level 'Ubuntu' entry** and `/boot`'s kernel symlinks point at the **newest installed
  kernel** — regenerated automatically, out of your control.
- **`GRUB_DEFAULT`** (submenu pinning, NVIDIA's verified-kernel guidance) points at **one specific
  kernel** — your rollback/roll-forward control.

They disagree on purpose. Whatever you decide, the safety net is: keep the old lineage installed and
`apt-mark manual` it, so the package manager cannot decide for you.

The generic (`4K`) lineage makes it worse: `linux-image-7.0.0-43-generic` is installed and GRUB
offers it, and `needrestart` calls it "expected" — but on Grace the generic flavor is the wrong
**page size** (4K vs the 64K Grace requires), so "the newest" and "the bootable" diverge. That is
why the walk-up question (`why does apt dist-upgrade expect 7.0.0-43-generic on this machine?`)
answered *itself* after the pointer was understood.

## Reproduce

```bash
bash tools/linux/grace/kernel-default-status.sh              # read-only: pointer + installed lineage + manual state
# switch (root):
#   GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-1067-nvidia-64k"
#   update-grub
# protect the fallback (root):
#   apt-mark manual linux-image-6.8.0-1043-nvidia-64k linux-modules-6.8.0-1043-nvidia-64k \
#     linux-modules-nvidia-fs-6.8.0-1043-nvidia-64k linux-tools-6.8.0-1043-nvidia-64k \
#     linux-headers-6.8.0-1043-nvidia-64k linux-nvidia-headers-6.8.0-1043 linux-nvidia-tools-6.8.0-1043
# verify (reboot, then):
#   uname -r; cat /proc/cmdline; getconf PAGE_SIZE
```

## Applies to

Any Ubuntu box where a **flavor** (`nvidia-64k` vs generic) selects the page size and kernels are
installed side-by-side with versioned names — i.e. NVIDIA Grace / GB10-class machines. The generic
parts of the method (GRUB_DEFAULT is a string pointer; `apt-mark manual` is the autoremove
shield) apply to any systemd/GRUB Ubuntu.
