# Case: installing `dsh-gitea` gives you no instance — config must be supplied, typed, and reloaded

**Tool:** `@goodandready/dsh-gitea` 0.7.44 (DSH profile `web`, cordis overlays) · **Target:** Forgejo 17.0.1 on a LAN host · **OS:** Windows 10 · **Date:** 2026-11-13
**Full write-up (Chinese):** [`write-up.md`](write-up.md) · **Reusable method:** [playbook 0010](../../playbooks/0010-verify-a-plugin-we-can-call-its-tool.md)

## Symptom

After installing the plugin bundle, **every** `gitea_*` tool fails immediately:

```
Configure the Gitea instance URL in Settings.
```

Then, after writing what looked like a correct config, **all** `gitea_*` tools vanish
(`unknown tool`) — a whole plugin silently gone, not just an error.

Both symptoms are the same root cause at different stages: the plugin is **installed** but never
**loaded with a working configuration**.

## Root cause

Three independent requirements, each of which failed once:

1. **The bundle installs an entry with an empty config.**
   The plugin's own patch inserts `id: dsh-gitea` with `config: {}`. There is no default instance,
   so `baseUrl` / `tokenEnv` / `defaultOwner` / `defaultRepo` must be supplied from outside.
   The "Configure the … in Settings" error is what an empty-config plugin returns.

2. **Cordis config validation is strict about YAML types.**
   `defaultOwner: 829522` (an unquoted YAML number) is rejected:

   ```
   ValidationError: invalid config: $.defaultOwner expected string but got 829522 (at defaultOwner)
   ```

   A rejected entry is not loaded at all — which is why the tools *disappear* instead of erroring.

3. **A failed load is not fixed by a live patch reload.**
   The overlay supports hot reload, but it does **not** re-run the activation of a plugin whose
   config failed validation at load. The harness restart is what re-loads the plugin graph.

## Fix — the order that works

```text
1. store the API token as a DSH credential  (one line in .credentials.yaml, value never inline)
2. add a profile overlay for dsh-gitea       (baseUrl, tokenEnv, quoted defaultOwner, defaultRepo)
3. restart the harness                        (patch reload alone does not re-arm a failed activation)
4. verify by CALLING one registered tool      (gitea_whoami), not by looking at lists or panels
```

The YAML that finally loaded (values scrubbed):

```yaml
- id: dsh-gitea
  config:
    baseUrl: http://<LAN-IP>:3000/
    tokenEnv: <TOKEN-ENV>
    defaultOwner: "829522"
    defaultRepo: comfyui-gfx1151-rocm
```

**Verified** after restart: `gitea_whoami` → owner 829522 (admin); `gitea_flavor` → Forgejo
17.0.1 OK; `gitea_repo_search` → target repo found; `gitea_issue_list` / `gitea_branches` → OK.
Raw API check against `/api/v1/user` with `Authorization: token $env:<TOKEN-ENV>` returns the same
owner — the credential env reference works end to end.

## What made this hard

1. **"Installed" and "usable" feel like one step.** The marketplace list stays green either way;
   only a tool call distinguishes them. See [playbook 0010](../../playbooks/0010-verify-a-plugin-we-can-call-its-tool.md).
2. **The failure mode changed between the two edits.** Empty config produced a *visible* error on
   every call; a type-strict rejection produced *total silence* (tools gone). The same mental model —
   "entry must be loaded with valid config, then verified by a call" — covers both.
3. **The type error names the field but not the fix.** "expected string but got 829522" sounds
   like "the value is wrong"; the actual fix is YAML quoting (`"829522"`).

## Open

- The plugin-update caveat from the console-flash case also applies here: an upgrade replaces
  `node_modules` files but the overlay `config:` lives in the profile, so config survives upgrades
  that wipe file patches — but re-verify with `gitea_whoami` after any `dsh-gitea` update.
- The LAN Forgejo host is now reachable and proven; the empty public repo
  `comfyui-gfx1151-rocm` is confirmed to exist (clone / recipe work is a separate step, by request).
