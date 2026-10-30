# Playbook 0004 — Separate causes that share the same symptom

**Applies to:** anything with a periodic symptom.
**Answers:** is this one bug or two, and which one am I looking at?

## The signal: the cadence changes

A periodic symptom has a **fingerprint**: its period. Two independent culprits rarely share one.

Observed here:

| After stopping… | measured interval |
|---|---|
| — (both running) | 5.2 s understood as "the" interval, plus noise |
| NVIDIA Sync (5.2 s poller) | **4.0 s**, consistently |

The period change is the proof that there were two sources and the first one was not the cause.
Without that step, stopping the wrong process would have looked like "the fix didn't work" or,
worse, like "the bug is intermittent".

## Procedure

1. **Record the baseline cadence numerically** (intervals, not "every few seconds").
   Nine intervals in a row is enough: `3.96 / 4.32 / 3.68 / 4.03 / 4.01 / 4.04 / 3.98 / 3.98 / 4.08`.
2. **Stop exactly one candidate.** Fully — a tray app that "closed" but still polls is not stopped.
3. **Re-measure the cadence.**
   - unchanged → this candidate is innocent (or not really stopped)
   - changed but still present → **there is a second source**; the new period is its fingerprint
   - gone → confirmed
4. **Match the period to code.** `setInterval(fetchStatus, 4000)` in the source is a stronger
   identification than any amount of observing.

## Why cadence beats timing correlation

"X flashed right after I did Y" is nearly worthless — with a 4-second period, *something* will
flash within a few seconds of anything you do. Human time perception plus a periodic signal
produces a false cause-and-effect almost every time.

Cadence is a property of the culprit alone; it does not depend on what you were doing.

## Corollary: check the phase after a state change

In this case the symptom appeared "only after a restart". That was true and still not causal:
the restart is what *starts the browser*, and the browser is what begins polling. The real trigger
was three steps removed from where it appeared.

Ask: **what does the action change besides the thing I suspect?**
