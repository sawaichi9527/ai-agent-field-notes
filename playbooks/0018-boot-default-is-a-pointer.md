# 0018 — The boot default is a pointer to a menuentry, and `apt autoremove` will delete the fallback you did not shield

**Claim.** On a GRUB Ubuntu system, "which kernel boots" is not answered by "the newest installed
kernel". The boot default is `GRUB_DEFAULT`, a **string that points into the Advanced-options
submenu**. The top-level 'Ubuntu' entry and `/boot`'s kernel symlinks track the newest install;
`needrestart` reports the newest as "expected" — all three are separate from the pointer. And a
forest of installed kernels is not stable storage: `apt autoremove` classifies a kernel the pointer
no longer selects as an unused dependency and removes it. A rollback you can actually use is **an
installed fallback lineage + `apt-mark manual`** on that lineage.

## The three questions, in order

1. **What selects the boot kernel, on this box?**

   ```sh
   grep '^GRUB_DEFAULT=' /etc/default/grub
   update-grub   # then: grep -n 'set default=' /boot/grub/grub.cfg
   ```

   The value is `Advanced options for Ubuntu>Ubuntu, with Linux <version>`. The `Advanced options
   for Ubuntu>` part is the submenu that keeps **every installed kernel's** entry; the comma string
   selects one. So the pointer selects among entries, and regeneration (`update-grub`) preserves all
   of them — a fallback kernel never loses its entry, only the *default* moves.

2. **Is this kernel's *lineage* the one this platform can boot?**

   On NVIDIA Grace / GB10-class (arm64, 64K-page requirement), the usable lineage is `nvidia-64k`;
   the `generic` flavor (4K pages) is installed on the same box, GRUB offers it, and needrestart may
   call it "expected" — but it is the wrong page size and must not be chosen. **Check the flavor
   before the version number.** (`getconf PAGE_SIZE`; installed kernels:
   `dpkg -l | grep 'linux-image'`.)

3. **What will the package manager do to the fallback, and how do you stop it?**

   > ```
   > ii  linux-image-6.8.0-1043-nvidia-64k    # the fallback (protected)
   > rc  linux-image-6.8.0-1055…1064-nvidia-64k  # what autoremove already consumed
   > ```

   `apt autoremove` removes packages it deems unused dependencies. The fallback kernel is exactly
   that shape once the default no longer points at it. The shield is `apt-mark manual` on that
   lineage's packages — telling apt "this package was installed explicitly" — and the check is
   `apt-mark showmanual`. This is a **protection step**, not an option.

## The rules that survive this case

- **A boot plan is a pointer, and only the booted kernel is a fact.** Change `GRUB_DEFAULT` +
  `update-grub`, then verify from the boot itself (`uname -r`, `/proc/cmdline`, `getconf PAGE_SIZE`)
  — not from "grub should be right" intuition.
- **`needrestart` and the top-level Ubuntu entry are 'newest' signals, not boot decisions.** They
  track installation order; the pointer tracks your decision. They disagree on purpose.
- **Distinguish flavor from version first.** On Grace, `nvidia-64k` (64K pages) is the only
  bootable lineage; `generic` (4K) is installed and offered but not bootable. "Newest" and
  "bootable" are two different answers.
- **A rollback you can use = installed fallback + `apt-mark manual`.** Without the manual mark,
  ordinary `apt autoremove` (run by anyone) can silently remove exactly the kernel you were keeping
  for rollback. (The consumed 1055–1064 kernels on this box prove the mechanism was already active.)
- **Compare boot logs before claiming "the switch is clean".** kernel warn/err/fail per boot
  (`journalctl -b 0` vs `-b -1`) and `systemctl --failed`; when the new boot has the *same* known
  lines as the old boot, the switch added no kernel-side risk.

## Evidence

- [`cases/2026-11-20-grace-c1-kernel-undo-switch/`](../cases/2026-11-20-grace-c1-kernel-undo-switch/) —
  the pointer before/after, the surviving 1043 menuentry, the 7 `apt-mark manual` rows, and the
  boot-log comparison
- [`tools/linux/grace/kernel-default-status.sh`](../tools/linux/grace/kernel-default-status.sh) —
  read-only: pointer, installed lineage (ii vs rc), generic 4K presence, manual shield

## Limits

- Applies to GRUB/systemd Ubuntu with versioned side-by-side kernels. Non-GRUB boot managers
  (EFI stub / chainload designs) store the pointer elsewhere — find the equivalent config object.
- `apt-mark manual` shields the fallback from *autoremove*, not from a deliberate
  `apt-get remove` or a `release-upgrade` that replaces the lineage wholesale. It is a shield for
  ordinary package-manager drift, not a force field.
- This case switched within the same lineage (nvidia-64k 1043 → 1067). Switching *flavor*
  (generic → nvidia-64k, or the reverse) is a different operation with different boot
  prerequisites (see the case write-up's page-size discussion).
