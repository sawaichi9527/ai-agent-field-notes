# Case: coordinator's kanban worker sits at `running` for hours with no output

**Tool:** hermes-agent v0.23.2 (commit `ae2a81ccc00e`), multi-profile OPC set
**Backend:** local `ornith-1.5-35b-a3b` Q4_K_M via LM Studio @ `192.168.23.217:1234`
**Hardware:** AMD Ryzen AI MAX+ 395 / Radeon 8060S (Strix Halo), unified memory · **OS:** Ubuntu, kernel 7.0 · **Date:** 2026-11-18
**Full write-up:** [`docs/editions/opc-personal/coordinator-hung-worker-local-stream-stall.md`](https://github.com/sawaichi9527/hermes-agent-opc-deploy/blob/main/docs/editions/opc-personal/coordinator-hung-worker-local-stream-stall.md) (in the sibling `hermes-agent-opc-deploy` repo)
**Probe:** [`tools/linux/probe-watchdog-stale-timeout.py`](../../tools/linux/probe-watchdog-stale-timeout.py) — Layer-1 mechanism verification

> **STATUS: fix applied, NOT confirmed resolved.** The mechanism that should make a stalled
> local stream get reclaimed faster has been verified in isolation (Layer 1). Whether it actually
> bounds real hangs still needs **long-term observation** of live `coordinator → researcher → writer`
> chains. See [Observation](#observation--long-term-status).

## Symptom

The coordinator (`local-e769f47c…`) had its 4th hung-worker this session. A kanban task it handed
off (a light `research + write`) sat in `running`:

```
events: heartbeat … heartbeat … heartbeat   (no new comment, no spawn, no deliverable)
```

The board never cleared it. No worker was producing anything, yet nothing killed it either. This is
the orchestration-layer symptom; the *engine* reason for the silence is what this case is about.

## What the log said

SSH to the local backend host `.217`, read the coordinator worker's own agent log (session
`local-e769f47c…`, task `t_ee930e8e`):

| Time | Event | Number |
|---|---|---|
| 17:41 | coordinator finishes tool listing, fires first request | — |
| 17:41→~00:31 | **HTTP 200 but ~900s with zero output** | `Stream stale for 900s — no chunks received`, `http_status=200 bytes=0 chunks=0 ttfb=-` |
| (throughout) | context **frozen at ~32,569 tokens**, never grew | **researcher never dispatched** |
| 18:45 | `Model unloaded` | generation ends |

The worker heartbeat kept jumping (~60 s), so the kanban stale detector — which needs **3600 s** of
no heartbeat to reclaim — never saw it. The backend was alive but producing nothing.

**This refutes the earlier "tool-call JSON repeat loop" hypothesis.** The signature is *zero output*
(`bytes=0 chunks=0`), not garbage repetition. It is the **same class of bug** as the
[LM Studio token-counter-frozen case](2026-11-18-lmstudio-token-counter-frozen/README.md): a backend
that stays up, keeps its heartbeat, and stops producing — invisible to a detector that only watches
for silence.

⚠️ **The exact engine trigger (prefill stall vs decode stall) is not 100% confirmed.** LM Studio's
server-log was unavailable (it wasn't running on `.217` at the time, log location unknown). The
agent.log HTTP-level evidence is conclusive that it was a **backend output stall, not a dispatch
defect**, but the llama.cpp/LM Studio layer itself was not directly observed.

## Root cause — two independent layers

### 1. Orchestration: no reclaim for a live-but-silent worker

The kanban stale threshold (3600 s no-heartbeat) is measured against *heartbeat*, and a wedged worker
keeps heartbeating while decoding nothing. Combined with the coordinator's completion-deferral, a
`running` task can sit for hours with no signal that anything is wrong.

### 2. Backend: the local decode stall (the real stopper)

The request the coordinator fired never produced a single chunk for ~900 s. The local ornith backend
accepted the connection (HTTP 200) and then went silent — the same "engine working, output not
flowing" failure as the frozen token counter, but manifesting as **zero tokens** rather than a frozen
counter.

## The fix: `agent.local_stream_stale_timeout` 900 → 300

The local endpoint's stale-stream ceiling (base 180 s, pulled up to a 900 s default for local
servers) is lowered to **300 s (5 min)**. Each stall now trips at 5 min instead of 15 min, so retry
damage scales down proportionally.

**⚠️ The config has to go in each profile's own file, not the global one.** Every named profile reads
only `~/.hermes/profiles/<name>/config.yaml` — it does **not** merge the global `~/.hermes/config.yaml`.
Editing the global file is silently ignored (measured: `hermes -p coordinator config get
agent.local_stream_stale_timeout` stayed 900). The rule is simply *"does this profile stream to the
local ornith backend @ `.217:1234`?"* — those six got it:

| profile | endpoint | before | after |
|---|---|---|---|
| secretary | local ornith @`.217` | 900 | **300** |
| coordinator | local ornith @`.217` | 900 | **300** |
| researcher | local ornith @`.217` | 900 | **300** |
| writer | local ornith @`.217` | 900 | **300** |
| runes-holder | local ornith @`.217` | 900 | **300** |
| builder | local ornith @`.217` | 900 | **300** |
| aeon-builder | remote `aeon` @ `192.168.23.215` | — | untouched (remote DGX vLLM) |
| opencode-researcher | cloud deepseek (opencode-go) | — | untouched (cloud) |

Each file changed `agent: {}` → `agent: local_stream_stale_timeout: 300`. **No restart needed**:
`load_config_readonly()` re-reads per streaming request by file mtime, so the next request picks it
up. (This differs from the concurrency fix's `max_in_progress_per_profile`, which *did* need a
gateway restart.)

## Layer 1 — mechanism verification (PASSED)

The probe [`tools/linux/probe-watchdog-stale-timeout.py`](../../tools/linux/probe-watchdog-stale-timeout.py)
does **not** reproduce a real stall. It proves the two things the fix relies on, against the live
DUT (`ae2a81ccc0`, v0.23.2):

```
=== Test 1: local endpoint uses the local stale ceiling ===
  local endpoint   ttfb_timeout = 600.0  (expect 600.0) -> PASS
  hosted endpoint  ttfb_timeout = 120.0  (expect 120.0) -> PASS
=== Test 2: ttfb watchdog does NOT kill when events flow ===
  return value is sentinel           -> PASS
  no codex_ttfb_kill close           -> PASS (closes=['request_complete'])

RESULT: ALL PASS        EXIT=0
```

- **Test 1** confirms a local endpoint honors the configured stale ceiling as its implicit
  no-event TTFB cutoff — so the real value of **300** will be respected (the test uses 600 as a
  stand-in). Hosted endpoints keep the 120 s default.
- **Test 2** confirms a stream that is actually emitting events is **not** killed past the cutoff —
  so the 300 s ceiling will not false-positive a healthy full chain.

This closes the loop on *"does the lever actually do what we set?"*. It does **not** yet prove the
fix bounds real hangs — that needs [Layer 2](#observation--long-term-status).

## Falsified hypotheses

| Hypothesis | Test | Result |
|---|---|---|
| tool-call JSON repeat loop (garbage, like the frozen counter) | reconstruct the stream, count delta kinds / `finish_reason` | **refuted** — `bytes=0 chunks=0 ttfb=-`, zero output, not repetition |
| dispatch/orchestration defect (coordinator never hands off) | agent.log shows coordinator finished tool listing and fired the request | the stall is *after* the request goes out, at the backend |
| dispatcher stale-reap threshold too long / `--no-skills` | checked process state, dispatcher logs, child comments | present but secondary; the primary stopper was the backend stall |
| LM Studio MTP / speculative-decoding bug | grep server-log for `inconsistent sequence positions`, `failed to process speculative batch` | not directly observed (server-log unavailable); agent.log says backend output stall |

## Guardrails (what actually prevents a repeat)

1. **Bound the silent-stall window at the client.** The 300 s `local_stream_stale_timeout` is the
   first layer — a local backend that stops producing should be noticed in minutes, not 15.
2. **A task-layer backstop**: kanban `enforce_max_runtime` (`max_runtime_seconds` per task) is still
   unset and under observation as a second guard.
3. **Watch for the trickling case**: if a stall ever manifests as "keeps emitting chunks, never
   ends," the per-chunk stale reset won't catch it — that needs `agent.stream_max_lifetime` (a wall
   clock cap on a single stream).
4. **Heartbeat is not progress.** Same lesson as the frozen counter: a worker can heartbeat happily
   while producing nothing. Reclaim decisions must look at *output*, not just liveness.

## Observation — long-term status

**The fix is NOT confirmed resolved.** Layer 1 proves the mechanism; it does not prove a real hang is
now bounded. Until then, treat this as *applied, under observation*:

- **What to watch**: the next real `coordinator → researcher → writer` chain that wedges. With the
  fix it should be reclaimed by the stale detector within **~5 min** instead of dragging to ~15 min.
- **How to confirm**: time-to-reclaim on the next natural hang (read board state / worker logs). If a
  hang still drags ~15 min, the setting didn't take effect (wrong file / merged into global).
- **If it still hangs or "never ends"**: escalate to `agent.stream_max_lifetime`.
- **Re-confirm after `hermes update`**: these are profile config values, not source patches, so an
  update won't touch them — but if the stale-detection *logic* ever changes upstream, re-run Layer 1.

## Transferable lesson

"A worker that heartbeats but produces nothing looks healthy to any detector that only watches for
silence." The frozen token counter was a display that stopped accounting; this hung worker was a
backend that stopped producing while keeping its heartbeat. In both cases the fix is to stop trusting
the liveness signal and measure **actual output** — here, stream chunks and first-event timing — then
reclaim on that. See
[playbook 0015](../../playbooks/0015-stale-watchdog-is-a-timing-claim.md).
