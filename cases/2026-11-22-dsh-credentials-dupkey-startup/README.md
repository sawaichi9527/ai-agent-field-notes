# Case: one duplicated key in `.credentials.yaml` failed the whole profile — a required plugin's data file is fatal, and its error is positional

**Tool:** DSH CLI 0.2.2-rc.5 (`@deepseek-ai/dsh`, npm 12.2.3), profile `web`, market plugin `dshmarket` 1.77.0 · **OS:** Windows 10 Enterprise LTSC · **Date:** 2026-11-22
**Full write-up (Chinese):** [`write-up.md`](write-up.md)
**Reusable method:** [playbook 0021](../../playbooks/0021-a-required-plugin-fails-on-its-data-file.md) · [playbook 0022](../../playbooks/0022-an-install-script-warning-is-not-a-missing-artifact.md)
**Probe:** [`find-duplicate-keys.mjs`](find-duplicate-keys.mjs)

> **STATUS: fixed by deleting one line.** No reinstall, no reboot, no version change. The interesting
> part is not the typo: (a) one duplicated key in a **data** file stopped 13 plugins, and (b) the
> diagnostic deliberately withholds the key name — so the visible symptom ("the market update broke
> DSH") pointed at the wrong thing for two rounds of updates.

## Symptom

After updating the market plugin and rebooting, every `dsh web` start ended the same way:

```
dsh: startup failed: 1 required plugin did not activate

Failed plugins (1):
  credentials
    Package: @deepseek-ai/dsh-credentials-local
    Error: credentials-local: invalid document at C:\Users\<you>\.dsh\.credentials.yaml:
           DUPLICATE_KEY at line 21, column 3

Plugins waiting for services (12):
  connection (required)  credentials
  authorization          credentials
  deepseek-account       credentials, authorization
  session-log-download   connection
  …
```

Nothing about the previous run was wrong: the plugin graph, the profile composition and the package
tree were untouched. One YAML document could not be parsed, and the plugin that could not load is
`required`.

## Root cause

`.credentials.yaml` is a versioned YAML store:

```yaml
version: 1

refs:            # env-style name → secret value
  DEEPSEEK_API_KEY: sk-…
  GITEA_TOKEN: <token A>      # line 19

records:         # <owner>/<id> → typed record
  llm-pi-ai/openai-codex:
    kind: api-key
```

`dsh-credentials-local` parses it with the equivalent of

```js
parseDocument(text, { uniqueKeys: true, prettyErrors: true })
```

and converts any parser error into a **fatal** one. `uniqueKeys: true` turns a repeated key into
`DUPLICATE_KEY`, so this document had `GITEA_TOKEN` twice — line 19 and, two lines later, line 21:

```yaml
  GITEA_TOKEN: <token A>      # line 19
                              # line 20
  GITEA_TOKEN: <token A>      # line 21  ← same value pasted a second time
```

Both entries were live tokens; the user kept the first and deleted the second.

Two consequences make this failure look much larger than it is:

1. **`credentials` is `required`.** Its failure is not "this plugin is degraded" — it aborts the
   start, and the 12 plugins downstream of it are listed as *waiting*, not as failed. The list is a
   dependency cascade, not 12 separate bugs: `connection` needs `credentials`, and one of the twelve
   (`session-controller`) needs `fileUploads`, which is itself behind `connection`.
2. **The diagnostic withholds the key name on purpose.** The parser's own message would quote the
   offending source line, and in this file that line is the secret. So the error carries only the
   code and the position — `DUPLICATE_KEY at line 21, column 3`. You cannot read the culprit out of
   the error; you have to compute it.

The column is the useful part: **column 3 = two-space indent = a direct child of `refs:` or
`records:`** — i.e. a repeated credential name or a repeated record id, never a nested field.

## Hypotheses that were wrong (and their evidence)

| Hypothesis | Why it looked right | Evidence it was wrong |
|---|---|---|
| The `dshmarket` 1.77.0 update broke DSH | the failure appeared right after that update + reboot | the error names a **data file**, not the plugin; reinstalling/updating dsh produced byte-identical output, same line and column |
| `npm update -g @deepseek-ai/dsh` will repair it | the first log line was from the same minute as the update | on 2026-11-22 registry `latest` **was** 0.2.2-rc.5 — nothing to upgrade to; the second run failed identically |
| A reboot left a stale file handle | the symptom started after a reboot | restarting changes nothing; the file is read at boot and fails deterministically |
| The token is invalid | `GITEA_TOKEN` appeared in the message | the failure is at *parse* time, before any network call; a bad token shows up as a 401 from `gitea_whoami`, not as a boot abort |

The durable lesson: **the second identical error after an "update" is evidence, not bad luck** — see
[playbook 0021](../../playbooks/0021-a-required-plugin-fails-on-its-data-file.md).

## Fix

```powershell
# 1. back up (the file is plaintext secrets — keep the backup short-lived)
copy "$env:USERPROFILE\.dsh\.credentials.yaml" "$env:USERPROFILE\.dsh\.credentials.yaml.bak"

# 2. find the duplicate without printing values
node find-duplicate-keys.mjs "$env:USERPROFILE\.dsh\.credentials.yaml"
#   "GITEA_TOKEN"  (in refs)
#     first   line 19, column 3
#     again   line 21, column 3

# 3. delete the duplicate line, then verify
node find-duplicate-keys.mjs "$env:USERPROFILE\.dsh\.credentials.yaml"   # → OK
dsh web
```

Rules that made the edit safe:

- **Delete, do not blank.** An empty value is rejected on purpose (`""` is not "no key"; removing
  the key is). Records are multi-line (`kind:` + `payload:`), so a duplicate record must be removed
  as a block.
- **Keep the value that actually works.** Both tokens here were plausible; the accepted one was
  confirmed by a working `gitea_*` call afterwards. Gitea shows a token in full only once, so
  "which one is real" is answered by a call, not by inspection.
- **No reboot and no reinstall.** The store is read at every boot; once the document parses, the
  next `dsh web` is enough. (A *live reload* of an invalid file keeps the last good snapshot, but an
  invalid file at startup is fatal — the two paths behave differently.)

## The probe

`find-duplicate-keys.mjs` loads the `yaml` package **from the installed dsh** and parses with the
same options DSH uses, then walks the AST printing **key names and positions only** — never a value:

```
duplicate keys in …\.credentials.yaml:

  "GITEA_TOKEN"  (in refs)
    first   line 19, column 3
    again   line 21, column 3
```

That is the only reason the second occurrence could be located: the product's own error stops at the
first one it sees, and the file has no searchable key name in the message.

## The other half of the session: install-script warnings

While chasing the boot failure, every `npm install -g` printed:

```
npm warn install-scripts 4 packages had install scripts blocked because they are not covered by allowScripts:
npm warn install-scripts   koffi@3.1.1 (install: node ./cnoke.cjs … --prebuild --release)
npm warn install-scripts   node-pty@1.2.0-beta.15 (install: node scripts/prebuild.js || node-gyp rebuild; postinstall: …)
npm warn install-scripts   @deepseek-ai/dsh-subprocess-local@0.2.2-rc.5 (postinstall: node scripts/ensure-spawn-helper.mjs)
npm warn install-scripts   pnpm@12.4.2 (preinstall: node install.js; postinstall: node install.js)
```

That warning is advisory, and none of those four packages needed the script to work here:

- `koffi` 3.x resolves its native binary from a per-platform optional dependency
  (`@koromix/koffi-<platform>`); the `cnoke` script is the from-source build path. On the reference
  Linux box `require('koffi')` + a real call worked with `cnoke` never having run.
- `node-pty` **ships** `prebuilds/win32-x64/conpty.node` (and peers) in the tarball; the install
  script is the fallback.
- `dsh-subprocess-local`'s postinstall only `chmod +x` a POSIX `spawn-helper` — a no-op on Windows.
- `pnpm`'s `install.js` belongs to pnpm, not to dsh's runtime.

The command npm suggested (`npm install -g --allow-scripts=…`, no package name) also fails outright:
with no positional argument npm treats it as installing the *current directory*, and
`C:\Users\<you>` has no `package.json` → `ENOENT … C:\Users\<you>\package.json`.

Method, flags and the persistent-config caveat: [playbook 0022](../../playbooks/0022-an-install-script-warning-is-not-a-missing-artifact.md).

## Verification

| Check | Expected |
|---|---|
| `node find-duplicate-keys.mjs …` | `OK`, no duplicate keys |
| `dsh web` | reaches the Web UI with no `startup failed` line |
| plugin panel / startup lines | the 12 waiting plugins activate; `dsh-gitea` can call `gitea_whoami` |
| terminal panel, `dir` | node-pty works after the reinstall |
| `npm update -g @deepseek-ai/dsh` | no install-script warnings once `.npmrc` carries the allow-list |
