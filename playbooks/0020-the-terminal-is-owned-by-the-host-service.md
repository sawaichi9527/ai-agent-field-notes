# Playbook 0020 — The terminal you see is owned by a host service, not the plugin that draws it

**Applies to:** agent CLIs where a sidebar / workbench UI plugin renders a terminal. The plugin may
draw the view and even list "shells", while a **host service** spawns and owns the PTY.
**Answers:** where to patch so the spawned shell actually changes, and how to prove it from the
spawned process itself.

This is the method behind
[`cases/2026-11-21-dsh-portable-pwsh-terminal-win/`](../cases/2026-11-21-dsh-portable-pwsh-terminal-win/).

## Find who spawns the PTY before touching anything

1. **Grep the plugin's client bundle for the host's terminal surface** (`webTerminals`,
   `terminal-controller`, `launchShells`, `selectShell`). Read the package's
   `src`/`lib` `.js`/`.ts` only — a full-tree grep of a `node_modules` root times out.
2. If the plugin only **reads** the host's terminal list and renders it (no import of the host
   package, `dsh.client.inject` missing the terminal surface → degraded), then patching the plugin
   changes nothing.
3. Name the host service from the mount row: `- id: terminal-controller`, name
   `@deepseek-ai/dsh-api-terminal-controller`.

## The shell decision chain (measured on DSH 0.2.2-rc.5)

```text
service entry config: Config.shell                      ← patch here
 (absent) → subprocess environment default             (Windows → built-in PowerShell)
new terminal with no shellPath → remote.shells(session)  (discoverShells puts configured/default first)
   → localStorage preference dsh.terminal.shell wins by EXACT path equality
   → else shells[0] = configured shell
```

Actions, in order of leverage:

- **Patch the profile overlay of the host service entry** (never the plugin). On a profile whose
  `package.json` has `patchReload: "live"`, a config change that passes validation hot-applies —
  no restart (record the CLI version with every "no restart needed" claim; see handoff trap #7).
- **Watch the localStorage preference.** If a user ever picked a shell in the host's shell menu,
  `dsh.terminal.shell` holds a path; a config change loses by exact-path equality. Clear or
  overwrite the preference before re-testing.
- **A config that failed validation still needs a restart** — hot reload does not re-arm a
  rejected entry (see the 2026-11-13 dsh-gitea case).

## Portable-shell traps (Windows, measured)

- Portable pwsh's `PSModulePath` is relative to its own exe dir (`<exe dir>\Modules`). A **mixed or
  damaged pack folder poisons every host that loads it** — the old broken folder must be replaced,
  never repaired or referenced.
- Keep the pack folder self-contained and untouched: version string + process path must both come
  from the pack you configured.

## Verify from the process, not the label

Never trust a shell-name label or the plugin's own display; a label can say "PowerShell" while
`$PSVersionTable.PSVersion` is 5.1. In a **newly opened** terminal run:

```powershell
$PSVersionTable.PSVersion.ToString(); (Get-Process -Id $PID).Path
```

Compare the path with the `shell.path` you configured. Already-open terminals keep the old process —
open a new one.

## Deliver

The overlay row applied (`config.shell` path / name / args), the `--dump-config` composition line
showing the host row overridden, and the spawned process path + PSVersion from a fresh terminal.
If a later task still shows the built-in shell, check `dsh.terminal.shell` in localStorage before
touching the overlay again.
