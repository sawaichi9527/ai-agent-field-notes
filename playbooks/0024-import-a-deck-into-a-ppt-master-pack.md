# Playbook 0024 — Import a deck into a ppt-master pack: the template is two artifacts, and each consumer has its own slot

**Applies to:** importing a PPTX-based template into a multi-consumer ppt-master pack (an opencode
consumer via `templates/*.svg` + `images/*.png` + a shared `decks_index.json`; a DSH wrapper /
`dsh-ppt-master-wrapper` consumer via its `SKILL_DIR` `templates/` copy + a per-deck registry; a
documented-but-uncreated future slot). Also to mirroring such a pack to a LAN Gitea/forgejo without
leaking secrets.
**Answers:** how to name the two artifacts (SVG-slot semantics vs PPTX page count), where each
consumer's artifact lands, how to register and how to retire, how to keep `/N` honest in PowerPoint,
and how to sync and verify two remotes.

This is the method behind
[`cases/2026-11-23-ppt-master-pack-import/`](../cases/2026-11-23-ppt-master-pack-import/).

## Name the two artifacts before importing anything

1. List the SVG template slots and read `page_count` from the shared index (cover/toc/content/ending =
   4 for a standard deck). Then count the native PPTX pages separately. They differ by design; never
   feed the PPTX page count into `page_count`, and never let render semantics rewrite the native
   template.
2. Map each consumer to its slot:
   - opencode: `templates/*.svg` + `images/*.png` + `decks_index.json` — one shared index, byte-identical
   - DSH wrapper: the native PPTX copied into the wrapper's own `templates/` (pair by name/size, SHA-256)
     + `dsh/<deck_id>.registry.md`
   - future consumers: a documented reserved slot (e.g. `hermes/`) with naming and registration rules —
     do not create it until there is a real consumer
3. Establish the contract in the working tree and register by discovery:

   ```
   python "<skill_dir>/scripts/pptx_to_svg.py" "<deck>.pptx" -o "projects/<deck_id>_<YYYYMMDD>" --roundtrip --inheritance-mode both
   ```

   The contract body lives in the round-trip workspace; the indexes only point at it. A deck id is
   `<project>_<YYYY>_<lang>`, with the language column spelled zh-Hant / zh-Hans / en-US.

## Keep `/N` honest

- PowerPoint has no total-page field (only slidenum), and neither does ppt-master up to v6.10.0.
- Tag the page-total shape `data-pptx-page-total="true"` and keep its slot aligned with `/N`
  (`1120 689.9 117 20.53`).
- Patch the export to write the real total; re-apply the patch after every upstream `ppt-master` update.
- Runtime changes (a new slide) need an add-in wired to the presentation events
  (`Auto_Open/PresentationOpen/PresentationNewSlide/PresentationBeforeSave/SlideShowBegin/WindowActivate`),
  verified via COM; a CLI sync (`sync_page_totals.py --total --dry-run`) keeps batches aligned.

## Register, then retire

- A registered deck has: SVG slots + images + an index row (opencode), and/or a PPTX copy + registry
  (DSH wrapper). Registering without the contract is worse than not registering.
- Retiring = move the deck to `_Archive/` AND stop registering it; keep the execution manifest and the
  compressed native payload. The index is the only thing that "registers" — deleting the index row is
  what actually retires the deck.

## Sync two remotes and verify

- A LAN Gitea/forgejo mirror speaks **http with a token embedded in the URL**. A bare URL is guessed as
  https and dies with
  `TLS connect error: error:0A00010B:SSL routines::wrong version number`.
- Push that way, then verify both remotes: head SHA equals your local commit on every branch you care
  about, and the raw content answers (HTTP 200) on the public side.
- Sanitise before publishing: no LAN IP, no `<you>` paths, no token values — only public filenames,
  deck ids and version numbers.

## Deliver

A deck directory with its SVG slots + images, a byte-identical shared index, the PPTX + registry in the
DSH wrapper's copy, a working `/N` (export patch + add-in + sync tool), archived retired decks minus
their index rows, and both remotes answering with matching head SHAs.
