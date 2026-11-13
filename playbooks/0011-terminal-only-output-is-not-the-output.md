# Playbook 0011 — Terminal-only output is not the output

**Applies to:** any CLI whose human-facing output is conditioned on `isatty()` — apt, dnf, git,
npm/pnpm, cargo, `systemctl`, `docker`, `sudo`.
**Answers:** "the tool printed nothing when I ran it, but the user sees warnings" and "my grep
counted 0 notices, so it's fixed" — when it is not.

## The trap

Many tools print their low-severity channel — `Notice:`, progress bars, colour, interactive
prompts — **only when stdout is a tty**. Redirect to a pipe or a file and the lines disappear
without a trace: not hidden behind `-q`, not sent to stderr, just never emitted.

A captured run therefore reports "clean" for a machine whose terminal shows problems on every
invocation. Absence of evidence in a pipeline is not evidence of absence.

Measured example (`apt update`, same machine, same config, seconds apart):

| How it was run | Lines matching `^(Notice\|N:\|W:\|E:)` |
|---|---|
| `apt-get update 2>&1 \| tail` | **0** |
| `script -q -c "apt-get update" /dev/null` | **3** (`N: Skipping acquire … 'i386'` ×2, `N: Missing Signed-By …`) |

The non-tty run also dropped the `N:` prefix entirely, so grepping for `^N:` cannot recover them.

## Why tools do it

- progress bars and colour are meaningless (or harmful) in a log file;
- `Notice:` sits below `Warning:`; several tools treat it as "interactive nicety";
- apt in particular keeps `W:`/`E:` in pipes but suppresses `Notice:` — an inconsistent split that
  makes the loss invisible when you only look at warnings.

## Recipe

Run the command under a pseudo-terminal whenever the question is "does it still print X?":

```bash
# util-linux script(1): allocates a pty, mirrors the session to stdout
script -q -c "apt-get update" /dev/null | tr '\r' '\n' | grep -E '^(Notice|N:|W:|E:)'
```

In a container: `docker run --rm -t …` (add `-t`), or `script` inside the container.

Sanity check before trusting a "0":

```bash
test -t 1 && echo tty || echo "piped — notices will be suppressed"
```

Then confirm the probe can see what it claims to see: get the same command to print a *known*
notice once (e.g. before the fix). A probe that never observed a positive case proves nothing.

## The other half: what a `Notice:` means

A notice is not a failure — exit code and functionality are unaffected. It is a queue of
"this will break one day". For apt specifically, three families exist and they need different
fixes:

| Notice | Meaning | Fix |
|---|---|---|
| `Skipping acquire … doesn't support architecture '<arch>'` | a configured architecture has no index in this repo | scope the entry: `Architectures: amd64` (do **not** remove a foreign architecture the system needs) |
| `Missing Signed-By in the sources.list(5) entry` | entry relies on the deprecated global `trusted.gpg.d` | give the entry its own `Signed-By:` keyring path |
| `… does not seem to provide it` / component misspelt | typo in `Components:`/`Suites:` | fix the entry, the repo probably has the file |

## Generalizes to

- `git clone`/`fetch` progress and `npm install` summaries vanish under redirection; "no output" is
  not "no work".
- `sudo` prints its password prompt only on a tty — a non-interactive run fails with
  "interactive authentication required", which looks like a permissions bug.
- `docker pull` prints layer progress only on a tty.
- `systemctl status` colourises only on a tty — the same text is a different string in a pipe.

## Related

- [Playbook 0002](0002-sandbox-measurements-lie.md) — a sandbox also changes what a probe can see.
- Case: [`cases/2026-11-13-apt-update-three-notices/`](../cases/2026-11-13-apt-update-three-notices/)
  — the apt instance of this trap, with the `Signed-By` and architecture fixes.
