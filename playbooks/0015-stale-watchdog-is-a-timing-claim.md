# 0015 — A stale watchdog is a claim about timing, not liveness

A watchdog decides "this has been stuck too long, reclaim it." The decision is always a claim about
**timing** — *N seconds with no X*. The trap is assuming the signal you timeout on is the one that
actually stops when work stops. Two cases from 2026-11-18:

- **Frozen token counter** ([case](cases/2026-11-18-lmstudio-token-counter-frozen/README.md)): the
  counter stopped, but the engine kept generating. The "no progress" signal (displayed tokens) was an
  accounting rule (text chunks only), not a measure of work.
- **Hung coordinator worker** ([case](cases/2026-11-18-coordinator-hung-worker-local-decode-stall/README.md)):
  the worker kept heartbeating while the backend produced zero output. The "no progress" signal
  (heartbeat) stayed green while work had stopped.

In both, **liveness ≠ progress.** A process can heartbeat happily, keep its connection open, and
produce nothing.

## The method

1. **Name the exact thing the watchdog times out on.** Is it "no bytes"? "no heartbeat"? "no token
   increment"? "no event"? Write it down — this is the claim you're about to test.
2. **Find the process's OWN counter for actual output**, independent of that signal:
   - LLM backend: `n_gen` / `n_decoded` / `tg` (tokens/s) from the engine's own logs, not the UI.
   - Agent worker: stream chunks received, first-event time, `finish_reason` — not the heartbeat.
3. **Reconcile the two.** If the watchdog's signal and the output counter disagree, one of them is
   measuring the wrong thing. The liveness signal is almost always the lie.
4. **Reclaim on output, not liveness.** Set the timeout against actual progress (bytes/chunks/tokens),
   with a separate wall-clock cap (`stream_max_lifetime`) for the "keeps flowing but never ends" case
   that per-event resets can't catch.

## Why this is hard from inside the sandbox

The agent that's stuck is often the one that would notice — and it reads the same liveness signal the
watchdog does, so both agree it's "alive." Step outside: read the backend/engine's own counter, or a
raw stream probe, where the output truth lives independent of the orchestration layer.

## Signals that survive

- Heartbeat on, output flat → wedged backend, not idle.
- Counter moving, display frozen → display accounting bug, engine fine.
- Chunks flowing, no `finish_reason`, no bound → per-event stale won't catch it; need a wall-clock cap.
