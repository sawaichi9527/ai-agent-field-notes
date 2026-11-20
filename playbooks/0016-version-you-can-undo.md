# 0016 — A version you must be able to undo: read the install model before you upgrade

**Claim.** "Upgrade" is underspecified. If the packages carry the version in their **name** and the
files live in a **versioned directory**, the new version is a *different artifact installed beside*
the old one, and rollback is a pointer change. If instead the package name is stable and the files
live in a shared path, the install is destructive and rollback means reinstalling.

You cannot tell which from the version numbers, the release notes, or the vendor's blog. You tell it
from `apt-get -s` and from where the files land.

## The three questions, in order

1. **Does the new version replace or accompany the old one?**

   ```sh
   LC_ALL=C apt-get -s install <new-meta-package> | tail -1
   ```

   - `0 upgraded, N newly installed, 0 to remove` → accompanying (side-by-side)
   - any `Remv` line → replacing; stop and read those lines before continuing

   On TheRock-based ROCm this is decisive: `amdrocm-core-sdk10.1-gfx1151` and
   `…10.2-gfx1151` are different packages with different prefixes (`/opt/rocm/core-10.1`,
   `/opt/rocm/core-10.2`), so the simulation says `0 to remove`.

2. **What decides which one is "current"?**

   Almost always `update-alternatives` (or a `current` symlink). Enumerate the groups that point into
   the versioned directory **before** installing, so you know what to flip back:

   ```sh
   update-alternatives --get-selections | grep '/opt/rocm/'
   ```

   Save that output as the rollback point. A rollback you cannot enumerate is not a rollback.

3. **Does the package manager's normal upgrade path ever cross the boundary?**

   Usually **no**, and this is the trap: a stable meta-package name that depends on a fixed version
   never becomes the new version. Here `apt list --upgradable` contained no `amdrocm*` at all, so
   `apt full-upgrade` would have done nothing while looking like it did something.

## The rules that survive this case

- **Named-version packages are not upgrades.** Installing them is a *co-install*. Say that out loud
  when planning, because it changes the risk model: nothing can be "half upgraded".
- **Make `0 to remove` a gate, not an observation.** If the simulation removes anything, the change
  is destructive and needs a different plan.
- **Rollback is a pointer change, so test the pointer, not the install.** After switching, verify
  identity from the tools themselves (`hipcc --version`, `rocminfo`, `amd-smi version`) rather than
  trusting that the post-install hook did the right thing.
- **A post-install hook that switches for you is a convenience, not a guarantee.** In this case the
  10.2 packages re-registered 26 alternative groups automatically. That is exactly why the rollback
  path must be recorded independently.
- **Expect asymmetric leftovers.** When rolling back, alternative groups whose files do not exist in
  the older version stay pointed at the newer one (here: `rocprof-*`, `rocsys`, `rocpd`, `rocm-smi`).
  That is not damage; it is the older version not shipping those tools. Record it so the next person
  does not "fix" it.

## Evidence

- [`cases/2026-11-20-rocm-10.2-coexist-upgrade/`](../cases/2026-11-20-rocm-10.2-coexist-upgrade/) —
  simulation output, 55+55 package lists, the 26 switched groups, and the rollback command
- [`tools/linux/rocm/rocm-version-switch.sh`](../tools/linux/rocm/rocm-version-switch.sh) —
  `--status` / `--plan` are read-only; `--install`, `--use`, `--remove` mutate

## Limits

- Applies to distribution packages with versioned names. Python/Node ecosystems usually use a
  *single* environment per version (venv, `node_modules`), where the equivalent of rollback is
  rebuilding the environment — see [0017](0017-version-comparison-needs-pairing.md) for the PyTorch
  twist (the wheel ships its own runtime).
- A side-by-side install costs disk (here: 8.7 GB + 9.2 GB). That is the price of a cheap rollback;
  decide it before, not after.
