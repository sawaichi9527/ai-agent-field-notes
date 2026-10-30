# Playbook 0001 — Measure CPU-vs-wall before anything else

**Applies to:** any CLI, any OS.
**Answers:** is it busy, or is it waiting?

## The one number

```
ratio = process CPU time / wall clock time
```

| ratio | meaning | look at |
|---|---|---|
| **≥ 90 %** | computing — module loading, compilation, parsing, metadata traversal | plugin/bundle count, CPU generation, what is being imported |
| **50–90 %** | mixed — some real waiting | profile the CPU first, then find the waits |
| **< 50 %** | waiting — I/O, network timeout, filter driver | disk, AV, unreachable endpoints, DNS |

Values **above 100 %** are normal for a JS runtime: background threads accumulate CPU time in
parallel with the wall clock.

## Windows

```powershell
# CPU time must be read after Refresh() and before the process is killed
$p = Start-Process -FilePath node -ArgumentList @($bin, '--port','3099','--no-open') -PassThru
# … wait for the "ready" marker …
$p.Refresh()
$cpu = $p.TotalProcessorTime.TotalMilliseconds
```

Inside a Node child (useful when the parent cannot enumerate processes):

```js
// NODE_OPTIONS=--import ./preload.mjs
const t0 = process.hrtime.bigint();
const before = process.cpuUsage();
// … on the ready marker …
const wallMs = Number((process.hrtime.bigint() - t0) / 1000000n);
const u = process.cpuUsage(before);           // user + system, all threads
```

## Linux

```bash
# wall
start=$(date +%s%N); ./cli --harness web --port 3099 --no-open &>/tmp/out & pid=$!
until grep -q 'http://127.0.0.1' /tmp/out; do sleep 0.05; done
end=$(date +%s%N)
# cpu (utime+stime in clock ticks)
awk '{print ($14+$15)}' /proc/$pid/stat
```

## Rules

- **at least 3 runs, take the median** — the spread on an old machine is easily 20 %
- never compare a cold run against a warm one
- the ratio, not the duration, decides where you look next
- if the ratio is > 100 %, adding an antivirus exclusion or moving the install to another disk
  **cannot** help — do not spend time there

## Failure mode this prevents

"Startup is slow → let's optimize the file loading" when the process was actually waiting on a
network call the whole time. The ratio costs one extra measurement and settles it.
