# Case: importing a PPTX deck into a ppt-master pack — "the template" is two artifacts, and each consumer has its own slot

**Tool:** DSH 0.2.2-rc.5 + `dsh-ppt-master-wrapper` + ppt-master (external skill, pin **v6.10.0**, source `hugohe3/ppt-master`, tier optional) ·
**OS:** Windows 10 Enterprise LTSC (the pack's consumer templates are cross-OS; sync touches a LAN forgejo/Gitea mirror) · **Date:** 2026-11-23

**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)
**Where the decisions landed:** `opencode-extension-packs/packs/ppt-master/decks/` — SVG slots, shared index, per-consumer registries, CHANGELOG `2.3.2-docs-6/7/8`

## Symptom

- Importing the FII 2026 PPTX template (en / zh-CN / zh-TW): the SVG template slots are **4**
  (cover / toc / content / ending) but the native PPTX is **5 pages** (cover / toc / content ×2 /
  ending) — "what is the page count" has two answers depending on who you ask;
- the same template must be delivered to two consumers that load and register it differently:
  opencode reads `templates/*.svg` + `images/*.png` + `decks_index.json`, while the DSH wrapper needs
  the native PPTX copied into its own `templates/` and a per-deck `dsh/<deck_id>.registry.md`;
- a bare-URL push to the LAN forgejo mirror fails with
  `TLS connect error: error:0A00010B:SSL routines::wrong version number` even though GitHub's API and
  `raw.githubusercontent.com` are fine.

## Root cause

"Template" in a multi-consumer pack is **two artifacts with two counts**:

- the **SVG slots** are the render carrier — `page_count: 4` is ppt-master's deck-page semantics
  (cover/toc/content/ending), not a page count of the PPTX;
- the **native PPTX** is the contract body — 5 pages as PowerPoint counts them, but PowerPoint has no
  total-page field (only slidenum), so `/N` must be maintained by an export patch + a runtime add-in
  (rewrites `3/4 → 4/5` on a new slide) + a sync CLI.

Treating the two counts as one number, or treating the index as the contract, is what breaks.
Consumers also disagree on **where the artifact lands**: opencode ships from the pack's `templates/`,
while the DSH wrapper round-trips the PPTX into its own `SKILL_DIR` copy. And the LAN forgejo mirror
only answers **http with a token embedded in the URL** — a bare URL is guessed as https and dies at the
TLS layer.

## Evidence

| Observation | Meaning |
|---|---|
| `decks_index.json` `page_count: 4` (SVG slots) vs PPTX 5 pages in `dsh/*.pptx` | two independent counts; neither is "the wrong one" |
| `decks_index.json` byte-identical across the pack and the opencode deck folder | the index is a discovery artifact, not the contract |
| PPTX copies paired by name/size (SHA-256) before a consumer slot is registered | a slot without its contract is a dead registration |
| add-in `FII_PageTotals.ppam` wired to `Auto_Open/PresentationOpen/PresentationNewSlide/PresentationBeforeSave/SlideShowBegin/WindowActivate`; page-total shape at `1120 689.9 117 20.53` tagged `data-pptx-page-total="true"` | `3/4 → 4/5` is computed at runtime, not stored by PowerPoint |
| bare LAN URL: `TLS connect error … wrong version number`; token-embedded http: `main -> main` | the mirror is http, and auth lives in the URL |
| 4 branches (main + `feature/ppt-master-template` + `feature/pack-manifest-token-usage` + `agent/grill-me-test-triage`) head SHA equal on GitHub and the forgejo mirror | sync is only "done" when both remotes answer with the same heads |

## Fix

1. **Keep contract and index separate.** Round-trip the PPTX to SVG
   (`python "<skill_dir>/scripts/pptx_to_svg.py" "<deck>.pptx" -o "projects/fii_tpl_<lang>_<YYYYMMDD>" --roundtrip --inheritance-mode both`),
   leave the contract in the round-trip workspace, and register by discovery only.
2. **Give each consumer its own slot.** opencode `templates/*.svg` + `decks_index.json`;
   DSH wrapper PPTX copy + `dsh/<deck_id>.registry.md`; a reserved `hermes/` slot documented
   (`HERMES_SLOT_GUIDE.md`, contexts A/B) but not created until a consumer needs it.
3. **Keep `/N` honest.** Export patch that writes the real total + `tools/sync_page_totals.py`
   (`--total --dry-run`) + `addins/FII_PageTotals.ppam`; re-apply the patch after each upstream
   `ppt-master` update (v6.10.0 has no total-page field either).
4. **Retire by de-registering.** Move a retired template to `decks/_Archive/` and stop registering it
   (keep its `template_execution_manifest.json` and compressed `native_payloads.json.gz`).
5. **Mirror with the right URL.** Push to the LAN mirror with a token-embedded **http** URL, then verify
   head SHAs on both remotes.

## Verification

| Check | Before | After |
|---|---|---|
| page total on a new slide | `/3` (or stale/unwritten) | add-in and export patch agree (`4/5`), COM-verified |
| `decks_index.json` vs opencode deck folder | divergent | byte-identical |
| DSH wrapper loads the deck | no registry entry | `dsh/<deck_id>.registry.md` present; PPTX in wrapper `templates/`; round-trip output opens |
| forgejo push | `TLS connect error: … wrong version number` | `main -> main` accepted via http token URL |
| GitHub raw content | — | `raw.githubusercontent.com` 200, head SHA equals local |

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A "template" is two artifacts — don't reconcile their counts** | `page_count` is SVG-slot semantics; PPTX page count is PowerPoint's. Any deck import hits the mismatch |
| **Contract lives in the working tree; the index only discovers** | making the index authoritative couples every consumer to one serialisation; keeping it discovery lets each consumer load its own copy |
| **Each consumer owns its slot** | opencode and the DSH wrapper load the same "template" from different places and registers; a new consumer (hermes) needs a documented slot, not a shared one |
| **`/N` is computed, not stored** | PowerPoint has no total-page field; any `/N`-style export needs a patch + runtime add-in to stay honest |
| **Retiring a template means stop registering it** | the archive keeps the payload; the index is the only thing that "registers" |
| **LAN mirrors are not https by default** | a bare forgejo URL gets http/TLS-guessed wrong; token-in-URL http is the working auth |

## Open

- The `hermes/` slot is documented but not created (contexts A/B in `HERMES_SLOT_GUIDE.md`); the first
  real hermes consumer triggers it.
- The export patch must be re-applied after each upstream `ppt-master` update.
- The contract body lives in the round-trip workspace, so a future importer who only reads the indexes
  will not find the PPTX — the workspace must be the entry point.
