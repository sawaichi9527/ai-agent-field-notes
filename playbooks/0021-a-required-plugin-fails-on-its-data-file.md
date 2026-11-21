# Playbook 0021 — A required plugin that will not activate is usually its data file, and the error gives you a position instead of a name

**Applies to:** agent CLIs whose plugin graph has *required* entries that read a user-owned document
(DSH `.credentials.yaml`, but the shape repeats in any loader that parses a store at start).
**Answers:** how to tell a data-file failure from a code/version failure, how to find the offending
key when the message deliberately withholds it, and which actions are provably useless first.

This is the method behind
[`cases/2026-11-22-dsh-credentials-dupkey-startup/`](../cases/2026-11-22-dsh-credentials-dupkey-startup/).

## Read the failure as two lists, not one problem

```
Failed plugins (1):      credentials   → the root
Plugins waiting for services (12):     → the cascade
```

A `waiting` plugin has not failed; it declared a dependency on a service the failed plugin would
have provided. So "13 plugins broke" is one bug plus arithmetic. Before touching anything, classify
the one failure:

| Error shape | Class | What can fix it |
|---|---|---|
| `invalid document at <path>: CODE at line L, column C` | user data | editing the file |
| `Cannot find module` / peer-dependency conflict | package tree | install / version |
| `config rejected` / validation error | profile overlay | overlay + restart |
| `did not activate` with no error at all | missing service upstream | find the upstream entry |

Only the second and third rows respond to a version change. The first one never does.

## The position is the whole diagnostic

`DUPLICATE_KEY at line 21, column 3` — no key name. That is deliberate: the parser's native message
quotes the offending line, and in a credentials file that line is the secret. The product replaces
the message with `code + line/col`.

Recover the name by re-parsing with **the same options** the product uses:

```js
parseDocument(text, { uniqueKeys: true, prettyErrors: true })
```

then walk the AST and report every key that repeats inside one mapping, with all of its positions.
Print key names and positions only — a duplicate-key checker that echoes the line is a leak.

Two properties make this reliable enough to act on:

- the parser is the same package (load `yaml` from the installed CLI, not a global one), so the
  verdict matches boot;
- a duplicate is a structural fact, not a heuristic — no guessing about which line "looks wrong".

## Turn the column into a section

Indentation is schema. In a store shaped as `version: 1` / `refs:` / `records:`:

| Column | Meaning |
|---|---|
| 1 | a top-level section (`version`, `refs`, `records`) — usually a whole-section duplicate |
| 3 | a **direct child** of `refs:` or `records:` — a repeated credential name or record id |
| 5+ | a field inside a record |

So column 3 says "the same credential name is defined twice", which is a two-line diff, not a
rewrite. Same trick generalises to any YAML/TOML store: indent level names the container.

## Fix, and the two ways to get it wrong

- **Delete the duplicate line; do not blank the value.** An empty string usually means "no value"
  and is rejected on purpose — in DSH the removal of the key *is* the removal of the credential.
- **A record is a block, not a line.** `<owner>/<id>` entries carry `kind:` plus payload/env maps;
  a duplicate record must be removed with its indented body.
- **Keep the value that works.** When both copies are plausible (two real API tokens), one tool call
  settles it; tokens are usually shown in full only once, so visual comparison is not available.
- **Restart is not reload.** A live reload of an invalid document keeps the last good snapshot, so a
  broken file can look harmless until the next start — where it is fatal. Verify with a fresh start.

## Falsify "the update did it" in one move

Re-run the *same* failing command after the update and compare **content**, not impression:

- identical `code`, identical line/column, identical file path → the update did not change the
  input; stop upgrading and open the file;
- the file is user data outside the package, so `npm update`, reinstall and reboot cannot touch it.

A second identical error is evidence. A changed line number is also evidence — of an edit, not of a
fix.

## Deliver

- the failing path, the error code, and the position (never the value or the whole line);
- the document's section layout and which container the position maps to;
- the duplicate key names with their positions, from a checker that prints nothing else;
- one fresh start that reaches the UI, plus one call that uses a credential, as the acceptance test.
