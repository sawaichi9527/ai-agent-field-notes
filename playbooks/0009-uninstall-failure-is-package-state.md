# Playbook 0009 — An uninstall that refuses is package state, and the wrapper hides why

**Applies to:** any installer UI or CLI that shells out to a package manager — plugin managers,
marketplaces, extension galleries, "one-click remove" buttons (npm/pnpm/yarn, apt, cargo, pip).
**Answers:** "Remove failed with exit code 1 and no message" and "it looks uninstalled, but it is
still there and retrying never works."

## The trap

A management wrapper compresses a package-manager run into a status line. `ERR_PNPM_UNUSED_PATCH`,
`ELIFECYCLE`, a peer-dependency conflict and a timeout all render as the same `exit code 1`. The
package manager almost always printed the reason — to a log the UI never shows.

The second half of the trap is **staging order**. A remove is rarely one atomic write; it touches
several files, in sequence:

| # | Artifact | Typical owner |
|---|---|---|
| 1 | selection list / "enabled" state | the wrapper's own config |
| 2 | dependency declaration (`package.json`) | package manager |
| 3 | lockfile | package manager |
| 4 | installed tree (`node_modules`, site-packages) | package manager |
| 5 | overlay rows / disabled entries referencing the package | the wrapper or host config |

If the wrapper commits #1 **before** the package manager runs, a failure leaves #1 applied and
#2–#4 untouched. The result looks removed (it does not load) but is still installed, and every
retry fails the same way — so the state never converges.

## Ask four questions, in this order

1. **What exact command did the wrapper run?** Every manager keeps a per-operation log directory
   (e.g. `.plugin-manager/logs/operation-*/pnpm.log`). If the log holds only a command line, that
   is the whole bug report: upstream swallowed stderr.

2. **Reproduce it where you can see stderr — on a copy.** Copy the profile/project directory, run
   the command read-only and watch the real error:

   ```bash
   cp -a ~/.dsh/profiles/web ~/tmp/web-copy
   cd ~/tmp/web-copy && pnpm remove -w <package> --reporter=append-only
   ```

3. **Classify the error family — each has a different fix:**

   | Error | Meaning | Fix |
   |---|---|---|
   | `ERR_PNPM_UNUSED_PATCH` / "patch not used" | a declared patch lost its last dependent | delete the declaration **before** removing |
   | peer-dependency conflict | a remaining package still needs it | remove the dependent first, or `--force` consciously |
   | lockfile policy failure (supply-chain check) | the lock is being verified against policy | update the policy or the version, not the lock by hand |
   | registry offline / auth | resolution, not removal | fix access; do not delete files manually |

4. **Does the package have side artifacts the manager doesn't own?** Search for its name outside
   the package manager's files: patch declarations (`patchedDependencies` in `pnpm-workspace.yaml`,
   `pnpm.patchedDependencies` in `package.json`, `patches/`), overrides/resolutions, overlay rows,
   host config entries. These are precisely what "remove package" forgets.

## The patch-specific rule

A patch declaration is owned by whoever added it, and package managers treat it as a **hard
requirement**: every patch must be used. So the removal order is:

```
delete the patch declaration  →  remove the package  →  delete the now-orphan patch file
```

Doing it in the reverse order aborts the removal, and doing the first step alone leaves an
installed package with no declaration — which is fine only for the seconds before step two.

Then re-verify the composed configuration (the host's effective config), not just the package list:
a deselected package can still leave a `disabled: true` overlay row that makes the next boot warn
(`patch: entry "<id>" not found`) or silently disable an unrelated future plugin that reuses the id.

## Verify all five artifacts, then the composed view

```bash
# 1-4
dsh plugin --profile web list --depth=0      # dependency declaration present? => not removed
grep -c "<package>" pnpm-lock.yaml           # => must be 0
ls -d node_modules/<package>                 # => must not exist
# 5
grep -rn "<package>\|<row-id>" cordis.patch.yml pnpm-workspace.yaml patches/
# composed host config — the only check that proves what will actually load
dsh --profile web --dump-config              # stderr must be empty
```

A running instance may report success through hot reload while a *restart* would fail; treat the
composed dump as the ground truth, then confirm the live endpoint still answers.

## Generalizes to

- npm `overrides` / yarn `patch:` / pnpm `patchedDependencies` — all are declarations that must be
  withdrawn with the package.
- apt packages that were `Conflicts/Replaces`-installed: "removed" leaves conffiles (`rc`) and the
  capability actually lives in the replaced package (see [playbook 0007](0007-same-version-different-artifact.md)).
- cargo `[patch.crates-io]`, pip `--constraint` files, VS Code extension folders: same shape —
  the declaration outlives the thing it patched.
