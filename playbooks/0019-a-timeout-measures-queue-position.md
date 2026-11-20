# 0019 — A timeout measures queue position, not model speed

A stale/response timeout says: *give up if nothing arrives for N seconds.* That reads like a
statement about the **model**, but on a busy or single-slot backend it is usually a statement about
**how long this request waited behind other requests** — a number the caller cannot see, because
both a slow prefill and a queued request look identical from outside (`HTTP 200`, `chunks=0`,
`ttfb=-`).

Case: [`cases/2026-11-20-hermes-stale-breaker-latched/`](../cases/2026-11-20-hermes-stale-breaker-latched/README.md).
Companion idea: [0015](0015-stale-watchdog-is-a-timing-claim.md) (liveness ≠ progress). This one is
about the *value*, that one is about the *signal*.

## The trap

You observe "N seconds elapsed, zero bytes" and conclude "the model is slow, so raise N." Both
halves can be wrong independently:

- The single request may already fit comfortably under N (measured: 195 s for a cold 117 k-token
  prefill vs a 300 s deadline) — so `N` was never the problem.
- The second concurrent request to the **same single-slot server** waits for the first one to finish
  completely (measured: 400.8 s ≈ 195 + 195). No model is slow here; the request is just second in
  line.

So `N` must be chosen against **queue depth × single-request TTFT**, and the depth is a property of
your deployment, not your model.

## The method

1. **Measure single-request TTFT, cold.** Randomize a prefix so the prompt cache cannot answer it,
   and read `prompt_tokens` from the response `usage` — do not estimate from characters (a 20 %
   error changes the conclusion).
2. **Run the same payload again immediately.** If it collapses to sub-second, you are looking at
   prefix-cache reuse. Now you know why identical "slow" reports coexist with fast turns in the same
   log: the variable is the cache, not the model.
3. **Send two cold requests at once and compare.** Second request's TTFT ≈ 2× single → strictly
   serialized, one slot. ≈ 1× single → there is real batching and the arithmetic changes.
4. **Now pick the value** as `single_request_TTFT × max_overlap_you_accept`. Write down the
   concurrency it covers. "900 s" means nothing until it reads "4 concurrent cold 100 k requests".
5. **Check what the number costs on the other side.** A larger deadline also delays detection of a
   genuinely wedged backend, and the retry budget multiplies it (900 s × 3 attempts, then × 5 before
   a breaker latches).

## The amplifier: retry budgets turn slowness into refusal

If the client keeps a cross-call counter ("stale N times in a row → stop calling"), the timeout
becomes an **availability** setting:

- slow request → stale kill → counter +1
- counter ≥ threshold → every subsequent call aborts **before opening a socket**
- from the user's side: the agent instantaneously "stops listening", while the backend is healthy

Reset paths are typically: a successful call (impossible now), a model/provider switch, or a process
restart. That asymmetry is the real bug: the breaker can be entered by ordinary slowness but only
left by an explicit operator action.

## Signals that survive

- 0.5 s error responses with a "consecutive … attempts" message → client-side pre-flight abort, not a
  provider error. Look for a counter, not a network.
- Kill records where `chunks=0` dominate (measured 188/201) → the deadline is a **TTFT** budget, not
  a mid-stream-gap budget; output length is irrelevant to it.
- Second-request TTFT ≈ 2× first → queueing, and no timeout value can fix it. Reduce concurrency,
  shrink the context, or split the endpoint.
