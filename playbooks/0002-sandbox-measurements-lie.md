# Playbook 0002 — Sandbox measurements lie

**Applies to:** any agent that runs its own tools inside a sandbox (all of them, effectively).
**Answers:** why did the number from inside the agent disagree with reality?

## What a sandbox actually changes

It is easy to assume the sandbox only restricts *writes*. In practice, four independent things
were observed here, and each one biases a different measurement:

| Restriction | Effect on measurement |
|---|---|
| writes limited to a working directory | the tool refuses to start at all (`EPERM` while rewriting its own config) |
| piped stdio denied for spawned children | the probe cannot read the child's output; the failure looks like "no result" |
| process enumeration denied (`Get-Process -Name`, `tasklist`, CIM) | CPU time, parent PID, and window handles are unavailable |
| new console allocation suppressed | "does a console appear?" is answered **False** regardless of the real behaviour |

## The signature to watch for

**Every configuration produces the same value.**

- real-world bug present → probe says "not present"
- control group still works, because it *inherits* the object instead of creating it

That combination is not evidence. It is the sandbox answering a question it cannot answer.

## Concrete numbers from this repo

| Measurement | sandbox | outside |
|---|---|---|
| startup wall time, same profile | **37–48 s** | **21.6 s** |
| CPU/wall | **55–70 %** (looks like "waiting") | **106–109 %** (computing) |

The sandbox inflated wall time without inflating CPU time, which pushed the ratio out of the
correct band and produced a wrong diagnosis that survived several rounds of "verification".

## Rules

1. **Ratio measurements only outside the sandbox.** Wall time alone is survivable; the ratio is not.
2. If the agent must run it, write results to a **file** and read the file afterwards — do not
   capture stdout through a pipe.
3. Prove the environment can produce the effect *before* interpreting a negative result:
   - can it create a console? (`Start-Process cmd /c "timeout 5"` must open a window)
   - can it write outside the workspace? (write one byte to the config dir)
4. Hand the final measurement to a human-run terminal. It costs one paste and removes all doubt.

## Why this is worth its own playbook

A sandboxed negative result is the most expensive kind of wrong answer: it looks like a clean
experiment, it has "data", and it causes you to abandon a real bug. The only defence is to test the
instrument before trusting its output.
