# 0026 — A capability flag is a client claim, not a model property

**When to use:** a model that clearly supports a modality (vision, audio, tools) is served behind an
OpenAI-compatible endpoint, but the agent behaves as if it does not — it OCRs the image, refuses the
attachment, or skips tool calling — and the obvious "make the server advertise it" fix does nothing.

**The rule:** capability is decided by the client, usually from **its own configuration or bundled
catalog**. The endpoint's model list is not a capability source in the OpenAI-compatible protocol.
Before touching the server, find out whether the client asks it at all.

## Steps

### 1. Establish the endpoint's truth with a synthetic probe

Cheap, unambiguous, no agent involved. For vision, generate a small image with a deterministic
answer and post it:

```text
POST /v1/chat/completions
{"model":"<id>","max_tokens":64,"messages":[{"role":"user","content":[
  {"type":"text","text":"What single capital letter is shown?"},
  {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}
```

Record `/version` and `/health` at the same time. Three outcomes:

- **200 + correct answer** → the endpoint has the capability; the problem is the client.
- **400 `"<id> is not a multimodal model"`** (vLLM) → the live deployment does not; the client would
  fail mid-turn if it over-claimed.
- **200 but nonsense** → the lane is degraded or the model is not what you think.

### 2. Find the gate in the client

Search the client's source for the capability vocabulary (`modalities`, `input`, `supports_vision`,
`input_modalities`), then read the **default** when nothing is declared.

- Look for a comment or constant like `DEFAULT_INPUT = ["text"]`.
- Check whether the client ever fetches `/v1/models` for the route in question. Many have two
  providers: one that parses a listing and one that does not.
- Note the **defaults file location** and whether a migration moved it (settings files get imported
  into profile overlays and the old file is left as `.imported` — editing it is a no-op).

### 3. Determine whether the client drops the bytes locally

If the client "refuses the image before attaching it" (a good design protects against mid-turn
failures), then **no server-side change can help**: the request is built without the image. Verify
by watching `prompt_tokens` after attaching an image — a vision model costs a few hundred prompt
tokens per image; a text path costs none.

### 4. Check the client's modality vocabulary before writing anything

| Tool family | Vision key | Vocabulary | Tools | Audio |
|---|---|---|---|---|
| pi-ai-based (dsh) | model `input` / route `defaultInput` | `text`, `image` only | not gated | STT plugin |
| opencode | `models.<id>.modalities.input` | `text`, `audio`, `image`, `video`, `pdf` | `tool_call: boolean` | same list |
| hermes-agent | `model.supports_vision` / models.dev | boolean | not gated | voice/STT |

A declaration the schema rejects (e.g. `audio` in pi-ai) is worse than none: it fails the config
load and hides the real problem.

### 5. Decide under-claim vs over-claim explicitly

- **Under-claim** (default): the client silently uses a fallback (OCR, description). Correct tool,
  degraded result, no failure.
- **Over-claim**: pixels are sent; a text-only deployment answers **400 mid-turn**, and most agents
  do not retry with a fallback.

With a **stable model id that serves lanes of different modalities**, over-claim is wrong half the
time. Two workable designs:

1. **Declare once + server-side graceful degradation** — on text-only deployments, replace the
   unsupported media part with an explicit placeholder text instead of raising. Keeps one id, one
   client config, no mid-turn failure.
2. **A second id per capability class** — clean semantics, but only if every engine can advertise
   the second name (native/vendored servers often bake the id in and cannot).

### 6. Verify from the client, not from the config

`dump-config` proves the config composed. It does not prove the client sent pixels. Re-run the
image and compare `prompt_tokens` on the server side. That delta is the only end-to-end evidence.

## Traps

- **"The endpoint must advertise it."** OpenAI-compatible `/v1/models` carries no capability field;
  vLLM returns `id / root / max_model_len / permission`. Even a gateway that injects capability is
  useless to a client that never reads it.
- **"It already parses `input_modalities` somewhere in its code."** Check *which provider*. A tool
  can parse modalities for its first-party API and not for custom OpenAI-compatible endpoints.
- **"A second served name will make it detectable."** Only if the client enumerates from the
  endpoint. Most enumerate from config or a bundled catalog.
- **"Declare tools too."** Tools are frequently never gated; the switches that exist
  (`supportsStrictTools`, `requiresToolResultName`) change the request **shape**, not availability.
- **"Audio is a modality."** For at least one major client it is not; it is a speech-to-text plugin
  that injects text. Declaring it in `input` is rejected.
- **Editing the migrated settings file.** After a CLI upgrade, the live layer may be a profile
  patch file; the old `settings.yaml` is renamed `.imported` and is dead.

## Evidence this rule came from

[Case: a vision model served under a stable id, still OCR'd](../../cases/2026-11-26-unified-model-id-vision-capability/)
— three clients compared, the 400 probe, and the four hypotheses that failed.
