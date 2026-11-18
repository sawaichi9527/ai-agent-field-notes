# Playbook 0014 — A frozen progress counter is a claim about the UI, not the engine

**Applies to:** any local-inference front end with a live token counter (LM Studio, Ollama,
llama.cpp's web UI, vLLM dashboards), and to any agent CLI that renders "thinking… / N tokens" —
i.e. every place where the number you watch is produced by a different component than the work it
claims to measure.
**Answers:** "generation stopped at N tokens", when the process is alive, the queue is filling, and
nothing looks crashed.

## The trap

A progress number looks like a measurement of the engine. It usually is a measurement of **what the
UI chose to render**. Two different counters, two different units, one screen:

| Counter | Lives in | Counts | Keeps moving when… |
|---|---|---|---|
| `tok` on the model card | renderer | text the UI can display (reasoning + content chunks) | the model emits text |
| `n_gen` / `tg` in the server log | engine | decoded tokens, per slot, every few seconds | the model decodes anything |

When output becomes **tool-call argument fragments**, the two diverge: the engine is emitting
hundreds of tokens per second into a JSON string, and the renderer, which counts only text chunks,
stops at the last one. The screen says "stuck"; the log says "42 t/s for the last hour".

## Fingerprints

| Observation | Meaning |
|---|---|
| engine log advances (`print_timing`, `n_gen` up), UI number flat | **display accounting**, not a hang — find what the UI counts |
| UI number flat **and** no new engine lines for minutes | a real stall; go to resource/driver/speculative decoding |
| no `finish_reason` in the stream | the request never completed — still generating, not "finished early" |
| one tool call's `arguments` grows without a closing `}` | model-level repetition loop; valid prefix, so nothing rejects it |
| every ~N minutes a new request arrives and the queue grows | caller retries without cancelling; the queue is not backpressure |
| `n_gen` climbs but `tg` decays smoothly | normal long-context slowdown, not a fault |

## Recipe

1. **Find the engine-side counter first.** In LM Studio it is `~/.lmstudio/server-logs/<yyyy-mm>/`
   (`slot print_timing … n_gen = …, tg = … t/s`); for llama.cpp it is `n_decoded`/`eval time`; for
   vLLM it is the per-request metrics line. Never diagnose from the screen alone.
2. **Reconcile the number on screen by arithmetic, not by intuition.** Reconstruct the stream's
   delta mix (`tools/linux/probe-sse-delta-mix.py`). If `reasoning + content` chunks equal the
   displayed count exactly, the counter's rule is found — and it explains the freeze without any
   engine fault. (This case: 110 + 15 = 125.)
3. **Check `finish_reason`.** Its absence separates "still running" from "ended at N".
4. **Look at what the output *is*.** A single tool call whose `arguments` is a repeated fragment
   with no closing brace is a model loop, not a transport problem.
5. **Only then** test the engine-level suspects: speculative decoding errors
   (`inconsistent sequence positions`, `failed to process speculative batch`), swap, GPU stalls.
   Grep for the exact error strings — a symptom that *looks* like a known issue often is not
   (the 124-token MTP bug is a rejected draft batch and a released slot; it logs, and it stops).
6. **Measure the blast radius.** Without `max_tokens`, a loop runs until the context fills:
   `(context − prompt) / t/s` is how long you will wait before it ends by itself.

## Rules

- **A progress number without a unit is not a measurement.** "125 tok" does not say whether it
  counts decoded tokens, rendered chunks, or characters.
- **The engine's log is the source; the UI is a second observer with its own bugs** — the same
  reason [playbook 0002](0002-sandbox-measurements-lie.md) says never measure from inside the
  sandbox.
- **Bound the runaway at the request, not at the UI.** `max_tokens` (4k–8k for tool calling) and a
  right-sized context turn a 100-minute accident into a 2-minute one.
- **Cancel before retry.** A retry timer without cancellation converts one stuck request into an
  ever-growing queue — and makes the symptom look like a deadlock.
- **A loop is cheap to detect and expensive to wait out:** repeated argument fragments with no
  text and no finish for N seconds is enough to abort.

## Related

- [playbook 0001](0001-measure-cpu-vs-wall.md) — the same "busy vs waiting" split, one layer down
- [playbook 0004](0004-separate-correlated-causes.md) — two counters disagreeing is two causes
- [`cases/2026-11-18-lmstudio-token-counter-frozen/`](../cases/2026-11-18-lmstudio-token-counter-frozen/)
