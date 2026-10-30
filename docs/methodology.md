# Methodology: how these cases were solved

Order matters. Doing these out of order is what produced most of the dead ends recorded in
`cases/`.

## 0. Decide the genre of the problem first

Every "it is slow / it is weird" report is really one of three things:

| Question | Measurement that answers it |
|---|---|
| Is it doing work, or waiting? | CPU time ÷ wall time for the process |
| Is it the same on a clean configuration? | same measurement with plugins removed |
| Is it this component at all? | observation from *outside* that component's own process tree |

Answer 1 and 3 before you touch 2. Most people start at 2 and spend hours optimizing something
that was never the bottleneck.

## 1. Measure the ratio, not the duration

`CPU/wall < 50 %` means waiting (I/O, network, a filter driver). `> 90 %` means computing.
`> 100 %` is normal for a JS runtime — background threads add CPU time that overlaps the same wall
clock.

Do **not** trust a duration on its own: the same 20 s can be a busy CPU or a stalled network call,
and the fix for one makes the other worse.

## 2. Validate the instrument before trusting the reading

Before interpreting any number, prove the probe can distinguish the two outcomes it claims to
distinguish. Concretely: include a control group that *must* produce the opposite result.

In `cases/2026-10-30-dsh-console-flash-win/` the probe reported the same value for all four
configurations — which looked like a strong negative result. It was worthless: the environment
could not create the object being tested. The control group worked only because it *inherited* that
object rather than creating one.

Two questions to ask of any probe:

1. Can this environment produce the effect at all? (test it directly, not by assumption)
2. If the effect were present, would the probe show it? (a control group that must differ)

## 3. Never measure from inside the thing you are measuring

An agent's own sandbox changes: what may be written, whether child processes may capture output,
whether process metadata may be read, and whether a child may acquire a console. All four were true
here, and each one silently biased a measurement.

Rules of thumb:

- ratio-style measurements (CPU/wall) are only valid **outside** the sandbox
- inside the sandbox you may prove "it ran", never "it is slow/fast"
- if the agent must run the probe, have it emit results to a **file** (pipes are denied) and read
  the file afterwards

## 4. When the component under suspicion is exonerated, keep the exoneration

It is tempting to delete a falsified hypothesis. Keep it. A clean negative result ("this chain
cannot produce the effect, here are the four combinations") is reusable and prevents the next
person from re-running the same dead end. Record **what was measured**, not just the conclusion.

## 5. Attribute by ancestry, not by timing

"X happened right after Y" is the weakest possible evidence. Two stronger ones:

- **ancestry**: the process that caused it is a descendant of the suspect
  (`git.exe` ← `node.exe` ← the agent). Ancestry survives coincidence.
- **cadence**: two independent pollers have different periods. Stopping one changes the observed
  interval from 5.2 s to 4.0 s — a change in rhythm is proof of a second source, and the period
  itself is a fingerprint you can match against source code (`setInterval(…, 4000)`).

## 6. Change one variable, and prefer the fix that is also a test

The last step in the console-flash case was a two-token edit (`windowsHide: true`). It was chosen
because it is simultaneously:

- the most probable fix
- a discriminating experiment: if the flash survives, the spawn options were not the cause

Prefer such edits over "try a bunch of things and see". And always keep a one-line rollback.

## 7. Write down the environment's own hostility

Record the things that are *not* the bug but corrupt your view of it: the machine's age, whether
real-time AV is on, whether the disk is spinning rust, whether the sandbox is active, whether the
log has timestamps. Future you will otherwise re-litigate all of it.
