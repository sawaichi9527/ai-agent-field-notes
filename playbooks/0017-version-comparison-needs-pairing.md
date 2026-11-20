# 0017 — Never compare two versions with one measurement each

**Claim.** Two single-shot numbers from two versions are not a comparison, they are two anecdotes.
The measurement apparatus (warmup, clock state, ordering, compiler vs runtime) moves the number by
1–30 %, which is the same range people use to declare a regression.

This case produced **two** false regressions in one afternoon:

| Apparent result | Actual cause | Correct result |
|---|---|---|
| 10.2 is 34 % slower (0.801 vs 0.532 ms) | one kernel launch, no warmup; module load + clock ramp included | both 237–242 GB/s steady state |
| 10.2 is 2.2 % slower | the second measurement in a pair is always slower | reversed order flipped the sign; paired runs → **+0.05 %** |

## The protocol

1. **Warm up, then sample.** ≥10 warmup iterations, then N measured iterations; report median
   (and min) rather than a single value. A single launch measures the driver's first-run cost.
2. **Interleave, don't sequence.** A/B/B/A — the same version measured twice at different positions.
   If position explains the difference, you will see it immediately.
3. **Cool down between blocks** (here: 20 s idle). Sustained load raises the baseline: the median
   drifted 0.8317 → 0.8508 ms over four blocks with no cooldown.
4. **Compare the same thing.** Two modes matter and answer different questions:
   - *compile-each*: each version compiles its own binary → compiler + runtime differences
   - *runtime-only*: one binary, swap the runtime → runtime differences only
   On ROCm both runtimes shared `libamdhip64.so.7`, so the second mode was executable with no relink.
5. **Know the resolution before declaring a winner.** Here run-to-run spread was ~0.5–0.9 %, so any
   delta below ~1 % is invisible. State the resolution next to the result.

## Reading the result

```sh
# paired, cooled, per-version averaged
bash bench-ab.sh --series "10.1 10.2 10.2 10.1" --iters 50 --cooldown 20
```

The tool prints a per-version mean. Compare **same-position** numbers (1↔3, 2↔4) as the strictest
test, then look at the means. In this case: 0.8414 vs 0.8418 ms → **+0.05 %**, i.e. equal.

## Corollaries

- **A smoke test is not a benchmark.** The program that proves "the GPU works" should be fast and
  single-shot; the program that compares versions must warm up and repeat. Keep them separate files.
- **Report the apparatus with the number.** "0.84 ms" means nothing; "median of 50 after 10 warmup,
  20 s cool between blocks, 192 MiB per iteration" can be checked by someone else.
- **When a regression disappears after you fix the method, write that down.** The false 34 % is more
  instructive than the final 0.05 %, because the next person will run the same smoke test and reach
  the same wrong conclusion.

## Evidence

- [`cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/bench-ab.tsv`](../cases/2026-11-20-rocm-10.2-coexist-upgrade/evidence/bench-ab.tsv)
  — all four runs, including the two that lied
- [`tools/linux/rocm/bench-ab.sh`](../tools/linux/rocm/bench-ab.sh) — `--series`, `--iters`,
  `--cooldown`, `--runtime-only`

## Limits

- Cooldown reduces thermal bias but does not eliminate it; with an APU the fan curve is the real
  clock governor. If a decision hinges on <1 %, run the blocks on separate occasions.
- Pairing cannot rescue a benchmark whose kernel is too short: at 0.8 ms, launch overhead is a
  meaningful fraction. Prefer a load that runs for tens of milliseconds.
