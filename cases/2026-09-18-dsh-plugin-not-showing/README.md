# Case: a plugin is installed but never appears in the marketplace UI

**Tool:** `@deepseek-ai/dsh` 0.1.5-rc.2 + `@maxhsu/dsh-forge` 0.3.3 · **OS:** Windows · **Date:** 2026-09-18
**Full write-up:** [`write-up.md`](write-up.md) (original notes, with a 0.2.1-rc.5 version caveat)

## Symptom

A plugin was installed, but the marketplace's "installed" section does not list it. Everything
looks like a failed install.

## Root cause

**Nothing was broken.** Two unrelated facts were being conflated:

1. The plugin is a **host-side tool plugin** - it registers 11 `forge_*` tools and has *no client
   UI*. So "no panel appears" is the correct behaviour, not a symptom.
2. The marketplace panel is its own UI judgement, and it labels a plugin by **entry id**
   (`forge-tools`), not by package name (`@maxhsu/dsh-forge`). Looking for the wrong string also
   reads as "missing".

The real failure to look for is one step later: after a profile rebuild the `baseUrl`/`token`
config is empty, and every tool call fails with
`Set dsh-forge baseUrl or the DSH_FORGE_URL environment variable`.

## Verification that actually works

**Call a tool the plugin registers.** That is the only reliable test:

| Response | Meaning |
|---|---|
| `{"version": "16.0.4+gitea-1.22.0"}` | working |
| `Set dsh-forge baseUrl ...` | loaded, but config is empty |
| `unknown tool` | not loaded at all → check `dsh.profile.bundles`, then restart |

`dsh --dump-config` is a useful second signal: a correctly applied patch adds
`# == <plugin>, patched by ...cordis.patch.yml` to the composed tree.

> Caveat: `--dump-config` rewrites `cordis.yml` before printing, so it fails with `EPERM` inside
> an agent sandbox. See [`docs/dsh-sandbox.md`](../../docs/dsh-sandbox.md).

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **"No UI" is not "not installed"** | any host-side / tool-only plugin behaves this way; verify by capability, not by panel |
| **The panel names entries, not packages** | entry id and package name differ on purpose; search both |
| **`dsh plugin` only updates `bundles` when pnpm exits 0** | a postinstall-blocked package (`ERR_PNPM_IGNORED_BUILDS`) installs fine and stays inactive; add `allowBuilds` and re-run |
| **Patch-layer `config` replaces the whole object** | omit one key and it becomes `undefined` - copy all defaults, do not write a partial object |
| **`id` must be the entry id and `name` must match exactly** | a wrong `name` is silently skipped with a warning, so the config looks applied but is not |
| **Marketplace rule: OBSERVED beats INFERRED** | `verify.js` trusts the loader's live inventory over `package.json` reasoning |
| **Never delete `profiles/<name>/` to "start clean"** | it holds bundles, load order, `node_modules` and all your settings; `dsh plugin remove` is the right tool |

## What is now out of date

The write-up says a patch edit takes effect live, because of `patchReload: live` + Cordis HMR.
On **0.2.1-rc.5** the string `patchReload` does not exist anywhere in the shipped code, so treat
live patch reload as unverified and restart instead.

This is the reason the caveat sits at the top of the write-up rather than in a changelog: a
"no restart needed" claim is exactly the kind of statement that silently stops being true.
