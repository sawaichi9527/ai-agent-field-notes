# Playbook 0022 — An install-script warning is a claim about scripts, not about artifacts

**Applies to:** global installs of Node CLIs whose dependency tree contains native bindings
(`koffi`, `node-pty`, …), on npm releases that gate lifecycle scripts behind an `allowScripts`
allow-list (npm 11/12 do) and end each run with
`N packages had install scripts blocked because they are not covered by allowScripts`.
**Answers:** whether the block actually broke anything, what to check instead of allowing the
scripts, and the two command-shape traps that waste the most time.

This is the method behind
[`cases/2026-11-22-dsh-credentials-dupkey-startup/`](../cases/2026-11-22-dsh-credentials-dupkey-startup/).

## The warning answers a different question than the one you are asking

It says *"these lifecycle scripts did not run"*. It does **not** say *"these packages are broken"*.
Modern native packages ship their binary in one of three ways, and only the third needs the script:

| Delivery | Tell | Runs without the install script? |
|---|---|---|
| **per-platform optional dependency** | a dependency named like `@scope/pkg-<platform>-<arch>`, resolved at require time | yes |
| **prebuilds inside the tarball** | `prebuilds/<platform>-<arch>/*.node` in the package | yes |
| **build from source** | `binding.gyp`/`cnoke` and no prebuilt anywhere | no — this one is genuinely blocked |

So the first check is per package: **is the artifact present, and does it load?**

```bash
node -e "const m=require('<global>/lib/node_modules/<pkg>/node_modules/koffi'); console.log(m.version)"
node -e "const k=require('<...>/koffi'); const l=k.load('libc.so.6'); l.func('size_t strlen(const char *)')('abc')"
```

A real call beats a successful `require` — FFI packages can resolve late. For `node-pty`, list
`prebuilds/win32-x64/` (`conpty.node`, `conpty_console_list.node`) and then open a terminal in the
product; that is the functional test.

Also read what the blocked script *does* before defending it. In the DSH tree, three of four were
not build steps at all: `dsh-subprocess-local`'s postinstall only `chmod +x` a POSIX `spawn-helper`
(no-op on Windows), `pnpm`'s `install.js` belongs to pnpm, and the last two transitive ones were an
`echo` and a version-scheme reminder.

## The two command-shape traps

1. **`npm install -g` with no positional argument installs the current directory**, not "the package
   that was just updated". npm's own advice to re-run `npm install -g --allow-scripts=…` therefore
   fails with `ENOENT … \package.json` unless the cwd happens to be a project:

   ```bash
   npm install -g @deepseek-ai/dsh --allow-scripts=koffi,node-pty,@deepseek-ai/dsh-subprocess-local,pnpm
   ```

   Name the package every time; `-g` selects the destination, it does not select a target.

2. **`--allow-scripts` is one-shot, and `.npmrc`'s `allow-scripts` is a whole list, not a filter.**
   The warning reappearing on the next npm run means nothing was persisted. Persist with
   `--location=user`, and when adding a package, repeat the existing ones:

   ```bash
   npm config set allow-scripts=koffi,node-pty,@deepseek-ai/dsh-subprocess-local,pnpm,protobufjs,@google/genai --location=user
   ```

   A shorter list silently drops the earlier permissions. (npm also warns that CLI and `.npmrc`
   disagree on the same run; CLI wins, that warning is expected.)

## Decision order

```text
warning appears
  ├─ does the artifact exist (optional dep / prebuilds / build dir)?   no  → allow that package's scripts
  │                                                                   yes ↓
  ├─ does a real call succeed?                                        no  → allow, rebuild, retest
  │                                                                   yes ↓
  └─ nothing to fix. Either persist the allow-list for quiet output, or leave the scripts blocked
     (less supply-chain surface) and treat the warning as expected noise.
```

## Always-on rules

- **Do not repair a version you did not break.** A blocked script is unrelated to the failure you
  were chasing unless the runtime test fails; chasing it moves the problem, not the fix.
- **Reinstalling the same version rewrites the tree and re-prints the warning.** `changed N packages`
  with an unchanged version number is churn; check `npm view <pkg> version` against `--version`
  before calling it an upgrade.
- **A blocked-script warning is reproducible on every run.** That very reproducibility means it is
  a policy message, not an incident report.

## Deliver

- per package: the blocked script's actual body, where the artifact comes from, and the test that
  proves it loads;
- the exact install command used (with the package name), and whether the allow-list was one-shot or
  persisted;
- the product's own smoke test after the change (a terminal for `node-pty`, a tool call for FFI).
