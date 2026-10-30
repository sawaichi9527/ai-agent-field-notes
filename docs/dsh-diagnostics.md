# DSH: where the diagnostics actually are

A map of the files and flags that answer "what happened during this start?" for
`@deepseek-ai/dsh` (verified against 0.2.1-rc.5 on Windows; paths mirror to `~/` on Linux).

## The four sources

| Source | Has timestamps? | Answers | Does not answer |
|---|---|---|---|
| `~/.dsh/dsh-web.log` | **no** | which plugins loaded / were skipped; the authenticated URL | how long a start took |
| `~/.dsh/restart-helper-<pid>.log` | **yes** (ISO) | whether this instance was helper-restarted, and a wall-clock upper bound on startup | console/window state |
| `~/.dsh/logs/startup-*.log` | yes (in filename) | startup **failures** only - written when the audit fails | successful starts |
| `dsh --dump-config` | n/a | the fully composed entry tree | timings; and it **writes** `cordis.yml`, so it fails in a sandbox |

**`dsh-web.log` having no timestamps is the most common trap.** It can tell you *whether*
something was skipped. It can never tell you *how long* anything took.

## Startup timing without a stopwatch

`restart-helper-<pid>.log` contains three distinct lines - do not confuse them:

```
... loaded pid=22156 execPath=... script=... cwd=...
... spawned pid 22668 (attempt 1)
... restart confirmed: fromInstanceId=... thisInstanceId=...
```

| Line | Meaning | Common misreading |
|---|---|---|
| `loaded pid=X` | the helper **module** loaded inside process X | "X was restarted by the helper" - wrong; it only means the plugin imports ran |
| `spawned pid=Y` | the helper launched Y | - |
| `restart confirmed` | the new instance answered | this is *after* the URL was printed, so it is an **upper bound** on startup |

Console state cannot be inferred from any of these. Only `MainWindowHandle` answers that, and
`0` is the **expected** value for a helper-restarted instance.

## Profile anatomy (what to look at, in order)

```
~/.dsh/profiles/<name>/
├─ package.json          dsh.profile.bundles = load ORDER; this is the startup cost driver
├─ cordis.patch.yml      your overrides; the only file you are meant to edit
├─ cordis.yml            REGENERATED on every start - never edit, never trust its mtime
├─ pnpm-workspace.yaml   generated; holds allowBuilds for postinstall-blocked packages
├─ node_modules/         hoisted layout, real directories
└─ .dsh-market/log.ndjson  install / restart events from the plugin manager
```

`~/.dsh/profiles/node_modules/` (one level up) holds **junctions** into the global install - they
cost no disk space, and a `Remove-Item -Recurse` that walks into one deletes the real packages.
Remove junctions with `cmd /c rmdir` first.

## Flags

| Flag | Use | Caveat |
|---|---|---|
| `--dump-config` | print the composed tree | writes `cordis.yml` first → `EPERM` in a sandbox |
| `--dump-default-config` | composed tree **without** the user patch layer | same write |
| `--dump-config-schema` | JSON Schema for entries/patches | same write |
| `-V` | version | safe, no writes |
| `--port`, `--no-open` | safe for measurement harnesses | `--no-open` survives a helper restart because the relaunch reuses argv |

## Plugin / bundle state

| Question | Where |
|---|---|
| Is the bundle listed at all? | profile `package.json` → `dsh.profile.bundles` |
| Was it skipped for peer incompatibility? | `dsh-web.log` → `skipping profile bundle "<name>"` |
| Is there an exact-version exemption? | profile `compatibility.json` - **may not exist**; absence simply means "no exemptions" |
| Is it actually loaded (not just installed)? | call a tool it registers; a host-only plugin has **no UI panel** to look at |
| Did install change anything? | `.dsh-market/log.ndjson` → `{"event":"install",...}` |

`dsh plugin` only updates `bundles` when pnpm exits **0**. A postinstall-blocked package
(`ERR_PNPM_IGNORED_BUILDS`) installs successfully but never becomes active - add an
`allowBuilds` entry and re-run.

## Version-dependent facts (check before trusting an older note)

| Claim | Status |
|---|---|
| `patchReload: live` in `package.json` makes patch edits reload live | **not reproducible in 0.2.1-rc.5**: the key `patchReload` does not appear anywhere in the shipped code (including `.pnpm`). Treat it as vestigial; do not rely on live patch reload without testing |
| `compatibility.json` holds exact-version exemptions | true when the file exists; newer profiles may not have it at all |
| `dsh-web.log` receives stdout/stderr of a helper-restarted instance | true |

When a note says "no restart needed", record the version it was observed on - this is exactly the
kind of claim that silently stops being true.
