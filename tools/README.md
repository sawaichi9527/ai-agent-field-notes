# tools

Every script here is a **probe**: it produces a number or a name, not a fix. Pick by the
question you are asking, not by filename.

Read [`win/README.md`](win/README.md) for per-script status and limits before running anything.

## Decision table

| I want to know | Use | Needs | Platform |
|---|---|---|---|
| How long until the CLI is ready, and is it computing or waiting? | [`win/measure-startup.ps1`](win/measure-startup.ps1) | a CLI that starts | Windows |
| Which process creates the console window that keeps flashing? | [`win/watch-console-windows.ps1`](win/watch-console-windows.ps1) | nothing (read-only) | Windows |
| Does this two-hop spawn chain create a **visible** console? | [`win/probe-console-visible.ps1`](win/probe-console-visible.ps1) | a normal (non-sandboxed) terminal | Windows |
| Which **one** spawn option changes the behaviour? | [`win/isolate-spawn-options.ps1`](win/isolate-spawn-options.ps1) | a normal terminal | Windows |
| Does a window's `app_id` resolve to a **usable** `.desktop` entry (right icon, no duplicate, valid file)? | [`linux/probe-desktop-match.sh`](linux/probe-desktop-match.sh) | python3 + PyGObject + Gtk 3 typelib | Linux |
| A fix stopped working after an "update" — is the variant package that carries it still installed? | [`linux/probe-package-variant.sh`](linux/probe-package-variant.sh) | dpkg (read-only) | Linux |
| A menu click "does nothing" — which stage of the launch chain is dead (entry, integrator, stale singleton lock, hidden window)? | [`linux/probe-appimage-launch-chain.sh`](linux/probe-appimage-launch-chain.sh) | bash + procps; optional xwininfo | Linux |
| — | [`linux/README.md`](linux/README.md) — the agent-CLI probes are still unwritten, and why | — | Linux |

## Conventions

**Naming is `verb-object.ps1`.** No numeric prefixes: tools are not a sequence, and numbering
forces a rename every time one is inserted between two others.

| Verb | Meaning |
|---|---|
| `measure-` | produce numbers |
| `watch-` | observe over time, catch events |
| `probe-` | run an experiment with a control group |
| `isolate-` | change exactly one variable |

**Every script starts with a machine-readable header.** This is the part that keeps the repo
honest - it says whether the tool can be trusted and what it touches.

```powershell
# STATUS : proven | template | diag-only
# PLATFORM: windows | linux
# NEEDS  : ...
# ANSWERS: the question this tool settles, in one sentence
# SIDE EFFECTS: what it writes, spawns, or kills - "none, read-only" if that is true
# USED BY: playbooks/000N, cases/<slug>/
```

`STATUS` meanings:

- **proven** - used to reach a conclusion recorded in `cases/`; safe to trust
- **template** - a working skeleton modelling one particular chain; adapt the hops, and keep the
  control group
- **diag-only** - changes nothing but the answer is diagnostic, not a measurement

## Rules for adding a tool

1. **Only publish what works.** A probe that failed is more useful as a snippet inside the
   playbook that explains *why* it failed - shipping it as a runnable script invites misuse.
2. **No hard-coded product names or paths.** Take `-Bin`/`-Args` style parameters; put a product
   example in the header comment instead of in the code.
3. **Never capture a child's output through a pipe** if the tool is meant to run in a restricted
   environment; redirect to a file and read it back.
4. **A negative result needs a control group**, or it is not a result (see
   [`playbooks/0002`](../playbooks/0002-sandbox-measurements-lie.md)).
5. **State the side effects.** Anything that spawns an extra instance or kills a process must say
   so in the header, in one line.
