# Write-up — "the model does not declare image input"

Date: 2026-11-26 · Clients: dsh 0.2.2-rc.5, opencode, hermes-agent · Server: vLLM `:1234`

## 1. Symptom

An operator switched the shared endpoint to a vision lane (a multimodal checkpoint served under the
same model id used by every lane, here called `aeon`). The agent was asked to read a PowerPoint
slide rendered as an image. Instead of sending pixels, the agent OCR'd the image and read the text.

Asked why, the agent answered: **"aeon does not declare image input capability."**

That answer is correct. The interesting part is *where* the declaration is supposed to live.

## 2. First hypothesis (wrong): advertise the capability from the server

The obvious fix is to make the endpoint say it accepts images. It cannot, and it would not matter.

### 2.1 vLLM has no capability field

`/v1/models` is a pydantic `ModelCard`:

```python
class ModelCard(OpenAIBaseModel):
    id: str
    object: str = "model"
    created: int
    owned_by: str = "vllm"
    root: str | None = None
    parent: str | None = None
    max_model_len: int | None = None
    permission: list[ModelPermission]
```

Checked on v0.10.2 and on `main` (2026-11): no `capabilities`, no `architecture`, no
`input_modalities`. So there is nothing to fill in without patching the server or putting a gateway
in front.

### 2.2 The clients never read it (this is the part that kills the hypothesis)

| Client | Where capability comes from | Calls `/v1/models`? |
|---|---|---|
| **dsh** | pi-ai provider config (`input`) → bundled catalog → route `defaultInput` → `["text"]` | **no** |
| **opencode** | config `models.<id>.modalities` | **no** |
| **hermes-agent** | models.dev catalog or `model.supports_vision` | **no** |

dsh's own source states the rule:

```text
Modalities assumed for a model neither configuration nor the catalog declares.
Text is the floor... nothing can interrogate a gateway for its modalities,
and the two wrong answers do not cost the same.
Under-claiming refuses the image before it is attached, naming the model.
Over-claiming admits one the provider then rejects mid-turn...
const DEFAULT_INPUT = ["text"];
```

The second sentence is the load-bearing one: **under-claim rejects the image before the request is
built.** No server behaviour can recover an image that was never serialized into a request. Patch
`/v1/models`, add a second served name, run a capability-injecting gateway — the request still
arrives with text only.

## 3. Ground truth: what the endpoint actually was

While the misrouting was reported, the endpoint was in fact serving a **text-only** lane (the
operator had switched lanes at some point). A 128×128 PNG probe confirmed both the lane state and
the exact failure mode a client hits after over-claiming:

```text
POST /v1/chat/completions
{"model":"aeon","max_tokens":64,"messages":[{"role":"user","content":[
  {"type":"text","text":"What single capital letter is shown in this image?"},
  {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]}

-> 400 {"error":{"message":"aeon is not a multimodal model",
                 "type":"BadRequestError","code":400}}
```

`/version` = `0.1.dev21830+g8244d1c44.d20261102` (b12x nightly image), `/health` = 200. So: server
healthy, lane correct, **lane has no vision** — and the error names the served id, not the
checkpoint.

## 4. The capability model is three different mechanisms

"Do we also need to declare tool calling and audio?" — no, and it is worth recording why, because
the three tools disagree with each other.

| Capability | dsh | opencode | hermes-agent |
|---|---|---|---|
| image | **gated** by `input` (vocabulary `text \| image` only) | `modalities.input` (`text/audio/image/video/pdf`) | `supports_vision` / models.dev |
| tool calling | **not gated**; `compat` switches only reshape the request (`supportsStrictTools`, `requiresToolResultName`, …) | per-model `tool_call: boolean` | not gated (agent loop) |
| reasoning | catalog / `reasoningEfforts` | per-model `reasoning: boolean` | catalog / effort config |
| audio | **not a modality**; handled by an STT plugin and injected as text | allowed in `modalities.input` | voice / STT path |

Two consequences:

1. A generic "declare everything" schema is a trap: dsh rejects `audio` in `input` outright, and
   opencode's `audio` means something a text lane cannot honour.
2. For these clients, **image is the only capability worth declaring**. Tools already work on every
   lane; audio only exists on one lane and reaches the agent through a transcription pipeline
   anyway.

## 5. Fix, per client (one-off; survives lane switches)

The model id is stable across lanes, so the declaration is not per-lane — it is per endpoint.

### dsh

The 0.2.2 migration moved settings into the profile, so the tempting file is dead:

```text
~/.dsh/settings.yaml          -> renamed to settings.yaml.imported (imported into the profile)
~/.dsh/profiles/<p>/cordis.patch.yml   <- live user layer (patchReload: live)
```

```yaml
- id: llm-pi-ai
  config:
    providers:
      <provider>:
        api: openai-completions
        baseURL: http://<LAN-IP>:1234/v1
        models:
          - id: aeon
            input: [text, image]      # vocabulary is text|image only
```

Verify the composed tree, not the file: `dsh --profile <p> --dump-config` must show
`input: [text, image]`.

### opencode

```jsonc
"aeon": {
  "name": "Aeon",
  "modalities": { "input": ["text", "image"], "output": ["text"] }
}
```

(`tool_call` / `reasoning` / `attachment` are separate booleans; leaving them unset keeps tools on,
so adding them is only drift risk.)

### hermes-agent

```yaml
model:
  provider: custom
  base_url: http://<LAN-IP>:1234/v1
  default: aeon
  supports_vision: true
```

`agent.image_input_mode` stays `auto`; an explicit `auxiliary.vision` backend would force the
describe path even on a vision model.

## 6. The real trade-off: one id, many capability sets

The stable id is what makes the one-off declaration possible — and also what makes it wrong half
the time.

| Client behaviour | Under-claim (default) | Over-claim (declare image) |
|---|---|---|
| vision lane live | image dropped, OCR/description (wrong tool, correct answer) | native pixels (correct) |
| text-only lane live | text path (correct) | **400 mid-turn**; dsh does not fall back |

Because capability changes with the live lane but the id does not, three designs are possible:

1. **Declare once + degrade server-side.** Patch the text-only images so an unsupported
   `image_url` is replaced with an explicit placeholder (`[image omitted: the active lane has no
   vision input]`) instead of raising. Vision lanes are untouched; env-gated, fail-closed.
2. **Second id per capability class** (`aeon` vs `aeon-vision`). Semantically clean, but the native
   TensorFold engines bake the advertised id into the vendored server, so it cannot be done
   uniformly.
3. **Declare once and accept 400s.** Cheapest; the agent session dies mid-turn on text lanes.

Design 1 is the only one that gives "configure once, never think about it again" while keeping the
single id. It was not implemented at the time of writing.

## 7. Falsified hypotheses (kept so nobody re-runs them)

- **"Patch `/v1/models` to advertise `capabilities: ["image"]`."** Dead: no client reads it; and
  vLLM has no field to patch without editing the server.
- **"Add a second served name (`aeon-vision`) so the client detects it."** Dead for these clients:
  they enumerate models from local config/catalog, not from the endpoint. (One runtime in the
  cluster advertises a different id than the one configured for it, and nothing breaks — proof the
  clients never look.)
- **"dsh already parses `input_modalities`, it must be reading it."** True in the *DeepSeek
  provider* package: that listing parser belongs to the Anthropic-Messages route and requires
  `api_capabilities.anthropic_messages`. The custom OpenAI-compatible route uses pi-ai, which has
  no listing fetch at all.
- **"Declare tools and audio in the same place."** Dead: dsh's modality vocabulary is `text|image`
  (schema rejects `audio`), tools are not gated, audio is an STT plugin.
- **"The model is broken."** Dead: `/health` 200, `/version` normal, text completions fine;
  the image request fails exactly at the multimodal gate.

## 8. Reusable rules

1. **Find the gate before the fix.** A capability string is only meaningful if someone reads it.
2. **Ask who sends the bytes.** If the client filters before serialization, server work is moot.
3. **Check the client's vocabulary.** "Modality" means `text|image` in one tool and
   `text/audio/image/video/pdf` in another.
4. **Separate gated capability from request shape and from out-of-band pipelines** (image vs
   tools vs audio).
5. **Measure both sides.** A synthetic image probe gives the endpoint's truth in seconds; a
   `prompt_tokens` delta after attaching an image proves the client actually sent pixels.
