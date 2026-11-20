# Case: "stopped answering me" — a stale-stream breaker latched, and the timeout was measuring queue position

**Tool:** hermes-agent v0.23.2 (multi-profile gateway, 9 profiles)
**Backend:** local `ornith-1.5-35b-a3b` Q4_K_M via LM Studio @ `<LAN-IP>:1234` (single request slot, 262144 ctx)
**Hardware:** AMD Ryzen AI MAX+ 395 / Radeon 8060S (Strix Halo), unified memory · **OS:** Ubuntu, kernel 7.0 · **Date:** 2026-11-20
**Probe:** [`tools/linux/probe-ttft-under-contention.py`](../../tools/linux/probe-ttft-under-contention.py)
**Predecessor:** [`../2026-11-18-coordinator-hung-worker-local-decode-stall/`](../2026-11-18-coordinator-hung-worker-local-decode-stall/) — same backend, same knob, opposite direction

> **STATUS: unblocked and measured; the setting is a regression on the earlier fix.** The session
> answers again (breaker cleared by restart, timeout raised 300 → 900 s in every profile). But 900 s
> re-opens the silent-stall window that the 2026-11-18 case deliberately closed, and the probe shows
> the real limit is **queue position**, not model speed. See [What this re-opens](#what-this-re-opens).

## Symptom

Every message to one profile's chat channel came back in **0.5 s** with:

```
❌ custom rejected the request and retrying won't help:
Provider has been unresponsive (no response received) for 6 consecutive stale attempts —
aborting this call to avoid an indefinite stall. Switch models or start a new session, then retry.
```

Retrying never helped, for a 17-character message and for a 2-character one alike. From the user's
side it looks like the agent "stopped listening"; from the log side the agent never even opened a
socket.

## What the log said

The chatbot reply was not a model answer — it was a **client-side pre-flight abort**:

| Time | Evidence |
|---|---|
| 19:08:18 | inbound `msg='我按了"批准升級"按鈕為什麼沒反應'` (17 chars) → `API call failed (attempt 1/3, not retryable)`, `6 consecutive stale attempts` → `response ready … time=0.5s api_calls=1` |
| 19:17:58 | inbound `msg='停止'` (2 chars) → identical 0.5 s abort |
| both | `sessions/request_dump_*.json` → `reason: non_retryable_client_error`, request never sent |

The number in the message is the whole story: `_consecutive_stale_streams` had reached 6, and past
the give-up threshold (`HERMES_STREAM_STALE_GIVEUP`, default 5) the call raises **before any network
attempt**. Nothing was wrong with the provider at that moment — a direct 16-token completion to the
same endpoint returned HTTP 200 in 0.29 s.

## Root cause — three layers

### 1. The latch: a per-agent circuit breaker that only clears on success

`agent/chat_completion_helpers.py`:

```python
def _check_stale_giveup(agent):
    if _giveup > 0 and _streak >= _giveup:
        raise RuntimeError("Provider has been unresponsive … aborting this call …")
```

`_consecutive_stale_streams` is bumped on every stale kill and reset **only** when a call completes,
the provider/model is swapped (`/model`, fallback activation), or the process restarts. It is an
in-memory attribute — no file, no session store. So a session that accumulated 6 stale kills keeps
refusing forever: it is not slow, it is *wedged by its own retry accounting*.

### 2. The stale kills: 300 s was below time-to-first-token *under queueing*

The profile had `agent.local_stream_stale_timeout: 300` (set by the 2026-11-18 case to bound silent
stalls). Across the retained logs, the distribution of what a stale kill actually saw:

| chunks received | byte count | kills |
|---|---|---|
| **0** | 0 | **188** |
| 45 – 4011 | non-zero | 13 |

So 93.5 % of "stale" events were **not mid-stream drops** — they were requests that produced nothing
at all before the deadline. The knob is therefore a **TTFT (time-to-first-token) budget**, not a
"slow model" tolerance: once tokens flow, every chunk resets the timer, and output length does not
count against it at all.

### 3. Why TTFT was exceeding 300 s: the endpoint has exactly one request slot

Measured (this probe, idle endpoint, fresh random prefixes so the prompt cache is cold):

| Scenario | prompt tokens | TTFT | effective prefill |
|---|---|---|---|
| cold, alone | 117,146 | **195.5 s** | 599 tok/s |
| same prompt again (prefix-cache hit) | 117,146 | **0.25 s** | — |
| cold, alone | 59,669 | **69.4 s** | 860 tok/s |
| cold, **queued behind one other 100 k request** | 115,651 | **400.8 s** | 289 tok/s (includes the wait) |

Decode: 28.9 – 36.7 tok/s throughout.

Three facts follow, and they decide the whole case:

1. **A single cold 98 k request takes 195 s** — *under* the 300 s deadline. On its own, 300 s is a
   defensible value.
2. **The second concurrent request waits 400 s** — `195 (first request's prefill) + 195 (its own)`.
   The server is strictly serial: no batching, no parallelism. 300 s cannot survive *one* other
   request, and there are seven profiles pointed at the same endpoint.
3. **A warm prompt cache is 780× faster** (0.25 s vs 195 s), because consecutive turns in one session
   share the prefix. This is why some calls in the same log finish in 6 s with 59 k tokens of input
   while others stall — the number that varies is not the model, it is the cache and the queue.

So the failures were the *sum* of a healthy prefill and someone else's prefill, not a broken engine.

## The fix (and what it is not)

- `agent.local_stream_stale_timeout` 300 → **900 s** in every profile that streams to the local
  backend. Per-profile files only: a named profile reads **only** its own
  `~/.hermes/profiles/<name>/config.yaml` and does not merge the global one.
- Reset the latch: restarting the gateway (or `/model` twice) zeroes `_consecutive_stale_streams`.
  The restart is for the breaker, **not** for the value — `load_config_readonly()` re-reads by file
  mtime, so a new value applies on the next request.
- Verified by loading each profile's config through Hermes' own loader, not by grepping the file:

```
$ HERMES_HOME=…/profiles/<name> python -c "from hermes_cli.config import load_config_readonly; …"
900 | custom | <LAN-IP>:1234 | ornith-1.5-35b-a3b@q4_k_m     # × 7 local profiles
900 | custom | <LAN-IP-2>:1234 | aeon                     # remote box, untouched
900 | opencode-go | (cloud) | deepseek-v4.1-flash          # cloud, untouched
```

900 s covers TTFT up to `195 × n` for `n` overlapping cold 100 k requests — i.e. **4 concurrent**
requests, 5 breaks it. That is a derived boundary from the table above, not a default inherited from
upstream (the upstream local default *is* 900, which is where the number came from — but it needed the
measurement to know what it buys).

## Falsified hypotheses

| Hypothesis | Test | Result |
|---|---|---|
| the provider is down / model unloaded | 16-token completion to the same endpoint while the session was refusing | **refuted** — HTTP 200 in 0.29 s |
| the model is just slow on big contexts, so raise the timeout | measure cold TTFT at 60 k and 117 k | **partly refuted** — 195 s single-request TTFT is *below* the old 300 s; the failures needed a queue, not a bigger timeout |
| it is the same bug as the 2026-11-18 silent-backend stall | compare signatures | **different mechanism, same surface** — that one was a wedged engine (900 s, frozen context, heartbeat alive); this one is a request waiting for the single slot, and a retry fixes it |
| the stale timer bounds the whole request | read the monitor loop | **refuted** — `last_chunk_time` is stamped on every chunk; only the first-token gap (and mid-stream gaps) count |
| the config edit needs a gateway restart | edit, then read through `load_config_readonly()` | **refuted** — mtime-keyed cache invalidates; the restart was only needed for the latch |

## What this re-opens

The 2026-11-18 case lowered this knob 900 → 300 **on purpose**: a genuinely wedged backend should be
reclaimed in minutes, because the kanban stale detector (3600 s of *no heartbeat*) never sees a
worker that keeps heartbeating while producing nothing. Raising it back costs, explicitly:

- a dead backend now burns **900 s per attempt × up to 3 attempts ≈ 45 min** per API call;
- reaching the breaker now takes **5 × 900 s ≈ 75 min** of consecutive stalls.

So 900 is a stop-gap that trades "false kills while queueing" for "slow detection of a real wedge".
The options that remove the trade instead of moving it:

1. **Stop sharing one single-slot endpoint across seven agents.** The queue wait is unbounded in
   principle; no timeout value is a fix for it.
2. **Shrink the context.** 98 k → 20–30 k turns cold TTFT from 195 s into ~25 s and makes even 300 s
   comfortable.
3. **Route chat to a hosted model** (the config already carries a fallback provider) and keep the
   local box for interruptible batch work.
4. **Cap total stream wall-clock** with `agent.stream_max_lifetime` for the "keeps flowing, never
   ends" case that per-chunk resets cannot catch.

## Transferable lesson

A stale timeout is a statement about **how long a request may sit in a queue**, and the queue is
invisible from inside the model call. The same numeric value can be generous for one request and
half of what is needed for the second one — and a retry budget turns that arithmetic into a
permanently muted session. Measure TTFT alone, then under contention, and only then pick the value.
See [playbook 0019](../../playbooks/0019-a-timeout-measures-queue-position.md).
