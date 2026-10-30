# Case: startup takes 21.6 s and the window stays blank

**Tool:** `@deepseek-ai/dsh` 0.2.1-rc.5 · **OS:** Windows 10 LTSC 2019 (17763.9376) · **Date:** 2026-10-30
**Full write-up:** [`handoff.html`](handoff.html) (single-file HTML, includes the source-machine baseline it was compared against)

## Symptom

`dsh web` from a console window: nothing is printed for the entire wait, then the URL appears.
Feels much worse than the previous minor version. Same 10-bundle profile throughout.

## Measurement

| # | time to URL | CPU | CPU/wall |
|---|---|---|---|
| 1 | 21,645 ms | 23,375 ms | 108 % |
| 2 | 21,357 ms | 23,312 ms | 109 % |
| 3 | 22,453 ms | 23,750 ms | 106 % |

**Classification: CPU-bound.** CPU time *exceeds* wall time, so the process spent the whole wait
computing across threads — it was not waiting on I/O, network, or antivirus.

## Conclusion

- The cost is module loading at startup, and it scales with the number of plugin bundles.
- Reference point from a faster machine (i7-4900MQ, 9 bundles): 16.1 s. Two official bundles alone:
  11.9 s. That gives **≈ 0.6 s per third-party bundle**.
- This machine's CPU (Core 2 Quad Q9500, 2008) is roughly 1.8–2× slower per core than that
  reference, which accounts for the 16.1 → 21.6 s difference. **No upgrade regression is needed to
  explain it** — and none was demonstrated (see "open" below).
- Realistic lever: cut 10 bundles down to the 2 official ones → expect **5–6 s**, i.e. back to ~16 s.
  That is not the same as "back to the previous version's speed".

## Ruled out by measurement

| Hypothesis | Evidence against |
|---|---|
| Antivirus real-time scanning | `WinDefend` service **Stopped**, `StartType=Manual`, no third-party AV |
| Slow disk | `C:` is an `INTEL SSDSC2KB480G8`; the two HDDs in the box are not system disks |
| Network / DNS / proxy | no `HTTP_PROXY`/`HTTPS_PROXY`/`NODE_PATH`; ratio > 100 % means no waiting |
| Port contention | a busy port fails immediately, it does not slow startup |
| `NODE_COMPILE_CACHE` | compile is only ~17 % of busy CPU; measured effect was inside the noise |
| Power-plan throttling | reported 100 % of nominal clock under load |

## Investigation notes

- `--dump-config` also rewrites the profile's `cordis.yml`, so it fails with `EPERM` inside an
  agent sandbox exactly like a real boot. It is **not** a read-only escape hatch.
- The startup log (`dsh-web.log`) has **no timestamps** — good for "was a plugin skipped", useless
  for "how long did it take".
- The restart helper's log (`restart-helper-<pid>.log`) *does* have timestamps and is a usable
  upper bound on startup: spawn → `restart confirmed` measured 22.86 s and 27.19 s.
- A sandboxed attempt to measure a stock profile produced 37–48 s / 55–70 % CPU, which is wrong in
  both numbers — see [playbook 0002](../../playbooks/0002-sandbox-measurements-lie.md).

## Open

- **No A/B between the previous minor version and 0.2.1 was ever performed.** The complaint was
  "the upgrade made it slower", but only the absolute value of the new version was measured. The
  npm cache still contains the older tarball, so installing it to a separate prefix and measuring
  both against one isolated `DSH_HOME` would settle it.
- Reducing bundle count was never applied (the 10-bundle profile is still in use).
