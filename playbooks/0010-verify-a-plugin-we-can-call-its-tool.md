# Playbook 0009 — A plugin is "installed"; whether it is usable is a separate load + config + restart chain

**Applies to:** DSH / cordis profile plugins that register host tools (e.g. `@goodandready/dsh-gitea`
for a Forgejo / Gitea instance), on any OS where the bundle, the credential store, and the profile
overlay are separate files.
**Answers:** how to get from "bundle installed" to "a tool call is reliable", and which error text
means which step was skipped.

This is the method behind
[`cases/2026-11-13-dsh-gitea-config-file-windows/`](../cases/2026-11-13-dsh-gitea-config-file-windows/).
It does not duplicate playbook 0003 (console flash) — that case covers what happens **after** the
plugin works.

## The chain (do the steps in order)

```text
install bundle  →  store credential  →  overlay with typed config  →  restart  →  call a tool
```

1. **Install the bundle.** The plugin's own insert usually registers the entry with an **empty**
   `config: {}`. Install alone is worth nothing: the entry exists, the instance does not.
2. **Store the credential separately** (DSH Credentials, `.credentials.yaml`), and reference it in
   config by env-style name (`tokenEnv: <TOKEN-ENV>`). Never write the value into a config overlay.
3. **Supply the full config as a profile overlay** (`cordis.patch.yml`): `baseUrl`, `tokenEnv`,
   `defaultOwner`, `defaultRepo`. Match the contract's types exactly — numbers that must be strings
   need YAML quotes (`"829522"`).
4. **Restart the harness.** A live patch reload does **not** re-run the activation of a plugin whose
   config failed validation at load.
5. **Verify by calling one registered tool** (`gitea_whoami`), not by panels or installed lists.

## Symptom → meaning → action

| Symptom | Meaning | Action |
|---|---|---|
| Every tool errors: "Configure the … in Settings." | entry present, config empty | add the overlay (step 3) |
| Tools are missing entirely (`unknown tool`) after a config edit | config rejected at load (type / validation) | fix types, restart (step 3 + 4) |
| Tools present but wrong owner / repo | overlay present and reloaded | check `defaultOwner` / `defaultRepo` values and types |
| Tools present and correct | fully loaded | proceed with the actual work |

## Always-on rules

- **Tools disappearing is a config-validation failure, not a "removed plugin".** The strict
  validation rejects the whole entry; silence (gone) is a worse symptom than a visible error.
- **Error text names the field, not the fix.** "expected string but got 829522" means "the YAML
  value parsed as a number — quote it", not "the value is wrong". Verify the value against the API
  (`/api/v1/user`) independently before you assume the login itself is bad.
- **Restart is load; reload is not restart.** For a plugin that failed at load, edit + hot reload is
  not enough — a full harness restart re-arms it.
- **Verify by calling the tool.** Marketplace lists and panels label plugins by entry id and can stay
  green for an unusable plugin. One successful call is the only reliable test.
- **Never publish credential values.** Show `tokenEnv: <TOKEN-ENV>`; never copy `.credentials.yaml`
  content or inline keys into notes.

## Deliver

One table with the config fields actually set (baseUrl / tokenEnv / defaultOwner / defaultRepo) and
the result of the first verified tool call. If any gitea-facing step of a later task misbehaves,
re-run the last call (`gitea_whoami`) before assuming the overlay changed.
