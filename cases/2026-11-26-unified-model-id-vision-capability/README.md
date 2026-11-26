# A vision model is served, but the agent still OCRs the image (2026-11-26)

**One line:** the model endpoint was serving a multimodal model under a stable id, yet the agent
answered "that model does not declare image input" and routed the screenshot through OCR — because
**image capability is a client-side claim, and none of the three clients ever asks the endpoint.**

## Environment

| | |
|---|---|
| Clients | `@deepseek-ai/dsh` 0.2.2-rc.5 (Windows 10), opencode, hermes-agent |
| Model server | vLLM on a 2-node DGX Spark cluster, OpenAI-compatible `:1234` |
| Model id | one stable id (`aeon`) for every lane; the live lane is switched by an operator CLI |
| Lanes | 6 of 10 are vision-capable; 4 are text-only (same id) |
| Probe | 128×128 PNG with the letter "A"; `POST /v1/chat/completions` |

## Root cause

1. **The OpenAI-compatible protocol has no model-capability field.** vLLM's `/v1/models` returns
   `id / object / created / owned_by / root / parent / max_model_len / permission` only.
2. **Every client in use declares capability locally** and never queries the endpoint:
   - dsh (pi-ai provider): `input` → bundled catalog → route `defaultInput` → `["text"]`.
   - opencode: `models.<id>.modalities`.
   - hermes-agent: models.dev catalog, or `model.supports_vision`.
3. dsh **refuses the image before attaching it** when the model is text-only. The bytes never
   leave the client, so a server-side capability advertisement cannot help even in principle.

## Fix

One-off client declaration (the stable id makes it survive lane switches):

```yaml
# dsh — live config is the profile patch layer, NOT settings.yaml (0.2.2 migrates it away)
# ~/.dsh/profiles/<profile>/cordis.patch.yml
- id: llm-pi-ai
  config:
    providers:
      <provider>:
        models:
          - id: aeon
            input: [text, image]
```

```jsonc
// opencode — ~/.config/opencode/opencode.jsonc
"aeon": { "modalities": { "input": ["text", "image"], "output": ["text"] } }
```

```yaml
# hermes-agent — ~/.hermes/config.yaml
model:
  supports_vision: true
```

## Residual risk (the reason to keep this case)

The same id serves text-only lanes. With image declared, a text-only lane answers
**`400` `"<served-id> is not a multimodal model"`** mid-turn, and dsh does not fall back. Two
honest options: (a) a server-side graceful-degradation patch on the text-only images that replaces
`image_url` with an explicit placeholder instead of failing, or (b) give vision lanes a second
served id and switch ids (which the native TensorFold engines cannot do — the id is baked in).

## Reusable lesson

[Playbook 0026 — a capability flag is a client claim](../../playbooks/0026-a-capability-flag-is-a-client-claim.md)

Full evidence, the client comparison, and the falsified hypotheses: [write-up.md](write-up.md).
