# Case: Removing a DSH plugin fails with "exit code 1" — a stale pnpm patch holds the uninstall

**Tool:** DSH `0.2.2-rc.1`, profile `web`, `pnpm` 12.4.2 · **Plugin:** `dsh-multi-lang-ui` 0.1.1
(GitHub git dependency) · **OS:** Ubuntu 24.04.5 LTS · **Date:** 2026-11-12
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)

## Context

A Web UI language plugin was installed months earlier and later superseded by another
multilingual bundle. Removing it from the Plugin Manager failed with a single line and no
detail. Retrying changed nothing, and the plugin still appeared in some lists but not others.

## What I measured before changing anything

- The GUI tool and `dsh plugin --profile web remove dsh-multi-lang-ui` both failed with:

  ```
  Command failed with exit code 1: pnpm remove -w dsh-multi-lang-ui --reporter=ndjson
  ```

  The plugin manager's per-operation log (`.plugin-manager/logs/operation-*/pnpm.log`) contained
  **only that command line** — pnpm's own error was never captured.

- Running the same command by hand in a **copy** of the profile produced the real error:

  ```
  Error: ERR_PNPM_UNUSED_PATCH
    × removing a package
    ╰─▶ The following patches were not used: dsh-multi-lang-ui@0.1.1
    help: Either remove them from "patchedDependencies" or update them to match
          packages in your dependencies.
  ```

- The profile state was already **half-removed**: the dependency and `node_modules/dsh-multi-lang-ui`
  were still there, the package was gone from `dsh.profile.bundles`, and `cordis.patch.yml` had been
  given `- id: multi-lang-ui` / `disabled: true`.

## Root cause

Two independent traps stacked:

1. **A patch outlived its package.** In 2026-10-05 the plugin had been fixed for DSH 0.2.0-rc.2
   using pnpm's native patch mechanism: `patchedDependencies` in `pnpm-workspace.yaml`, the patch
   file under `patches/`, and a `patch_hash` in `pnpm-lock.yaml`. pnpm 12 requires every declared
   patch to be used by some dependency; removing the only dependent makes the patch "unused", and
   pnpm aborts the whole `remove` instead of dropping the declaration.
2. **The manager mutates before it knows the outcome.** `removeBundle` first deselects the bundle
   (writes `dsh.profile.bundles`) and only then runs `pnpm remove`. When pnpm exits non-zero the
   failure is reported, but the deselection is already on disk — hence a plugin that looks removed
   (not loaded) yet is still installed and can never be removed by retrying.

## Fix

1. Back up `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `cordis.patch.yml` and the patch file.
2. Delete the stale patch declaration from `pnpm-workspace.yaml` (`patchedDependencies` block).
3. Re-run the removal (`remove_bundle` / `dsh plugin remove`) → exit 0, `Packages: -1`, dependency
   and lockfile entries cleaned in 3 s.
4. Delete the now-orphan overlay row in `cordis.patch.yml` (`--dump-config` warned
   `patch: entry "multi-lang-ui" not found`).
5. Delete the orphan patch file under `patches/` (backup kept).

## Verification

| Check | Method | Result |
|---|---|---|
| Composition clean | `dsh --profile web --dump-config` | stderr 0 bytes, 202 rows, no `multi-lang` |
| Dependency gone | `dsh plugin --profile web list --depth=0` | 6 packages, plugin absent |
| Files gone | `node_modules/`, `pnpm-lock.yaml` | directory missing, 0 lockfile references |
| No dangling config | profile search + `patches/` | 0 references, directory removed |
| Runtime healthy | `GET http://127.0.0.1:3080/` | HTTP 401 without a token (expected auth) |

HMR applied the change live (`application: applied`); no restart was needed. The plugin was already
deselected, so the running process never held it.

## Lessons

- **An uninstall that refuses is usually package state, and the wrapper is hiding the reason.**
  Find the exact package-manager command in the operation log, then re-run it where you can see
  stderr — here with an `ERR_PNPM_UNUSED_PATCH` that never reached the UI.
- **"Not loaded" is not "removed."** While the manager stages a change across several files
  (selection list → package files → overlay rows), a failure can leave any prefix of that sequence
  applied. Verify every artifact, not one.
- **Patch declarations are owned by whoever added them.** A compatibility patch written for an
  older host version must be reverted in the same breath as removing its package — the upstream
  "remove this plugin" path does not know about it.

Codified in [playbook 0009](../../playbooks/0009-uninstall-failure-is-package-state.md).
