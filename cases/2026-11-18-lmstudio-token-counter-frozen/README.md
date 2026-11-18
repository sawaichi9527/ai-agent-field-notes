# Case: LM Studio sits at "125 tok" — the engine had already generated 159k

**Tool:** LM Studio 0.4.x (bundled llama.cpp engine, MTP enabled), model `ornith-1.5-35b-a3b@q4_k_m`
(35B-A3B MoE, Q4_K_M, 22.76 GB) · **Hardware:** AMD Ryzen AI MAX+ 395 / Radeon 8060S, 128 GB unified
memory · **OS:** Ubuntu, kernel 7.0.0-43-generic · **Date:** 2026-11-18
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact log lines and timeline)
**Probe:** [`tools/linux/probe-sse-delta-mix.py`](../../tools/linux/probe-sse-delta-mix.py)

## Symptom

The "loaded model" card showed, for over an hour:

```
1032  GEN  (+2 QUEUED)  125 tok   ⟳
```

The spinner kept turning, the token number never moved, and two more requests stayed queued. The
model had an **MTP** badge, 262144 context, GPU offload 41 layers, unified KV cache and context
checkpoints on — the usual suspects for a wedged local backend. The user asked why generation had
stopped at 125 tokens.

It had not stopped. The counter had.

## What the log said

`~/.lmstudio/server-logs/2026-11/2026-11-18.28-30.log`, one request
(`chatcmpl-wng92wkrofqpthzgrc7krg`):

| Time | Event | Number |
|---|---|---|
| 17:43:27 | request accepted (6 messages) | prompt **6104** tok, prefill 1196 t/s |
| 17:43:34 | first packet | — |
| **18:30:03** | **the screenshot moment** | **n_gen = 126,659** |
| 18:45:42 | last running sample | **n_gen = 159,261**, `tg = 42.72 t/s` |
| 18:45:50 | `Model unloaded by user or API request` | generation ends |

`slot print_timing` fired every 3 s for **62 minutes**, with `tg` decaying 60 → 42 t/s as the
context filled. Nothing was waiting: 42 tokens/s is a healthy 35B-A3B on this iGPU.

## Root cause — two independent layers

### 1. The model was looping inside a tool call's JSON

Reconstructing the stream (probe above) splits the 23,397 packets into exactly three delta kinds:

```
delta keys        {'role': 1, 'reasoning_content': 110, 'content': 15, 'tool_calls': 23272}
text chunks       reasoning=110 content=15 -> 125
finish_reasons    none
```

`tool_call[0]` (`web_extract`, three URLs) completed normally. `tool_call[1]` (`web_search`) never
did:

```json
{"query":"","limit":6,"limit":6,"limit":6, … }
```

115,891 characters of `,"limit":6` (≈10,500 repetitions), no closing brace, no `finish_reason` in
62 minutes. A degenerate repetition loop in JSON arguments — valid JSON *prefix*, so nothing
rejects it, and no grammar forces the object to close.

### 2. The counter only counts text chunks

**110 reasoning + 15 content = 125.** That is the number on the card, exactly. The 23,272
`tool_calls` chunks — the entire hour of output — are not part of that count. Once the model stopped
emitting reasoning/content and produced only tool-call fragments, the displayed number froze while
the engine kept decoding.

The number was never a measure of generation. It was a measure of *the part of the message the UI
renders as text*.

## Why it was allowed to run for an hour

| Factor | Value | Effect |
|---|---|---|
| `max_tokens` on that request | **absent** | nothing caps the loop |
| context length | 262144 | ~100 min of headroom at 42 t/s; it would have stopped near 19:2x, not at 125 |
| retries from the caller | every ~15 min, 12- and 67-message requests | each one queued behind the loop — that is the `+2 QUEUED` |

The caller (an agent harness) retried on a timer without cancelling the previous request, so the
queue filled up behind a request that was still legally running.

## Falsified hypotheses

| Hypothesis | Test | Result |
|---|---|---|
| MTP / speculative-decoding decode bug | grep the log for `inconsistent sequence positions`, `failed to process speculative batch` | **0 hits**. The 124-token signature in [lmstudio#2160](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2160) is a different failure (draft batch rejected, slot released) |
| memory pressure / swap | `free -h` during the run | 41 GiB of 121 GiB used, **31 GiB swap, 0 B used** |
| server crash or queue deadlock | `curl http://<LAN-IP>:1234/api/v0/models` | HTTP 200 with an auth error — the server was alive the whole time |
| GPU stall | `tg` across the hour | smooth 60 → 42 t/s, no flat line |

The first hypothesis is the one a screenshot invites, and it was wrong. The screenshot could not
distinguish "engine idle" from "engine working, display not updating"; the log could.

## Guardrails (what actually prevents a repeat)

1. **`max_tokens` on every request** (4k–8k for tool-calling agents). The later request in the same
   log carried `"max_tokens": 8192`; the runaway one carried none.
2. **Context sized to the task.** 262144 turned a 2-minute mistake into a 100-minute one. 32k–64k
   is enough for this workload (prompts here were 6k and 62k).
3. **Repetition/presence penalty** on models used for tool calls, and keep `temperature` modest.
4. **A client-side watchdog**: abort when a stream produces only repeated argument fragments and no
   text/finish for N seconds. A 15-minute retry loop without cancellation makes it worse.
5. **Cancel before retry.** Queue depth is not backpressure if the head never finishes.
6. `reasoning_effort` was `medium` while the model supports only `'on'` (log warning); align it so
   the model is not silently run outside its intended mode.

## Evidence collection

```bash
# 1. what the engine thinks it is doing
tail -f ~/.lmstudio/server-logs/$(date +%Y-%m)/$(date +%F).*.log | grep -E 'print_timing|stop processing'

# 2. what the client was actually sent
python3 tools/linux/probe-sse-delta-mix.py \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.28.log \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.29.log \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.30.log \
  --id chatcmpl-<id>

# 3. what is loaded, from the CLI (read-only)
~/.lmstudio/bin/lms ps
```

## Transferable lesson

"The token counter stopped" is a statement about a **display**, not about a process. Before
diagnosing the engine, find the engine's own counter (`n_gen`, `tg`, `n_decoded`) and reconcile it
with the number on screen. If they disagree, the display has an accounting rule you have not found
yet — here it was "text chunks only". See
[playbook 0014](../../playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md).
