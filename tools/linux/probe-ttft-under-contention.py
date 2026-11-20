#!/usr/bin/env python3
"""probe-ttft-under-contention.py — measure time-to-first-token, alone and behind a queue.

Question: "this request stalled with zero output for N seconds — is the model slow, or was the
request waiting for a slot?" The probe answers with numbers instead of a guess.

It sends OpenAI-compatible /chat/completions requests that stream, and reports, per request:
    ttfb         — time until response headers (the connection was accepted)
    first_token  — time until the first content/reasoning delta (the real TTFT)
    prompt_tokens — from the response `usage`, not estimated from characters

Three modes, designed to be run in this order:

    1. cold, alone        -> baseline TTFT
    2. --warm             -> same payload again; sub-second means you measured prompt-cache reuse
    3. --concurrency 2    -> two *distinct* cold payloads at once; 2x TTFT = strictly one slot

Deliberately dependency-free (stdlib only) and cache-hostile: each cold payload starts with random
salt words, so a prefix cache cannot answer it.

Usage:
    TTFT_BASE_URL=http://<LAN-IP>:1234/v1 TTFT_API_KEY=… \\
      probe-ttft-under-contention.py --model ornith-1.5-35b-a3b --tokens 117000
    … --warm
    … --concurrency 2

Exit codes:
    0  every request produced a first token
    2  at least one request failed (error/timeout) — numbers for the others are still printed
"""

from __future__ import annotations

import argparse
import json
import os
import random
import string
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

WORDS = ("the maintenance ledger records how each scheduled job behaved which provider answered "
         "how long the first byte took and whether the retry budget survived the night").split()


def _salt(n: int, rng: random.Random) -> str:
    return " ".join("".join(rng.choice(string.ascii_lowercase) for _ in range(rng.randint(5, 9)))
                    for _ in range(n))


def build_payload(model: str, target_tokens: int, seed: int | None) -> dict:
    """~target_tokens of prompt, starting with random salt so the prefix is never cached."""
    rng = random.Random(seed)
    body = [_salt(600, rng)]
    # ~4.1 chars/token for this corpus; the real count is read back from `usage` afterwards.
    target_chars = int(target_tokens * 4.1)
    while sum(len(x) for x in body) < target_chars:
        body.append(" ".join(rng.choice(WORDS) for _ in range(120)) + ".")
    text = "\n".join(body) + "\n\nReply with exactly: OK"
    return {
        "model": model,
        "messages": [{"role": "user", "content": text}],
        "max_tokens": 16,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }


def run_one(label: str, base_url: str, api_key: str, payload: dict, timeout: float) -> dict:
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                 "Accept": "text/event-stream"},
    )
    t0 = time.time()
    ttfb = first_token = None
    usage, chunks = None, 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ttfb = time.time() - t0
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                body = line[5:].strip()
                if body == "[DONE]":
                    break
                try:
                    obj = json.loads(body)
                except json.JSONDecodeError:
                    continue
                if obj.get("usage"):
                    usage = obj["usage"]
                delta = (obj.get("choices") or [{}])[0].get("delta") or {}
                if first_token is None and (delta.get("content") or delta.get("reasoning_content")
                                            or delta.get("reasoning")):
                    first_token = time.time() - t0
                chunks += 1
    except Exception as exc:  # noqa: BLE001 — a probe reports the failure, it does not hide it
        return {"label": label, "error": f"{type(exc).__name__}: {exc}", "ttfb_s": ttfb,
                "first_token_s": first_token, "sse_chunks": chunks}
    total = time.time() - t0
    pt = (usage or {}).get("prompt_tokens")
    ct = (usage or {}).get("completion_tokens")
    return {
        "label": label,
        "ttfb_s": round(ttfb, 2),
        "first_token_s": round(first_token, 2) if first_token else None,
        "total_s": round(total, 2),
        "prompt_tokens": pt,
        "completion_tokens": ct,
        "prefill_tok_s": round(pt / first_token, 1) if pt and first_token else None,
        "decode_tok_s": round(ct / (total - first_token), 1)
        if ct and first_token and total > first_token else None,
        "sse_chunks": chunks,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default=os.environ.get("TTFT_BASE_URL", "http://localhost:1234/v1"))
    ap.add_argument("--model", required=True)
    ap.add_argument("--tokens", type=int, default=100_000, help="approx prompt tokens (real count is read back)")
    ap.add_argument("--concurrency", type=int, default=1, help="distinct cold requests sent at once")
    ap.add_argument("--warm", action="store_true", help="resend the same payload (expect prompt-cache hit)")
    ap.add_argument("--seed", type=int, default=None, help="fixed salt seed, for reproducible payloads")
    ap.add_argument("--timeout", type=float, default=1800.0)
    args = ap.parse_args()

    api_key = os.environ.get("TTFT_API_KEY", "")
    if not api_key:
        print("probe: set TTFT_API_KEY (the endpoint's bearer token)", file=sys.stderr)
        return 2

    base_seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    payloads = [build_payload(args.model, args.tokens, None if args.warm else base_seed + i)
                for i in range(args.concurrency)]
    labels = ["single" if args.concurrency == 1 else f"par_{i + 1}" for i in range(args.concurrency)]
    if args.warm:
        labels = ["warm"]

    started = time.time()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(run_one, label, args.base_url, api_key, payload, args.timeout)
                   for label, payload in zip(labels, payloads)]
        results = [f.result() for f in futures]

    print("label\tttfb_s\tfirst_token_s\ttotal_s\tprompt_tokens\tcompletion_tokens\t"
          "prefill_tok_s\tdecode_tok_s\tsse_chunks\terror")
    for r in results:
        print("\t".join(str(r.get(k, "")) for k in (
            "label", "ttfb_s", "first_token_s", "total_s", "prompt_tokens", "completion_tokens",
            "prefill_tok_s", "decode_tok_s", "sse_chunks", "error")))
    if args.concurrency > 1:
        ok = [r["first_token_s"] for r in results if r.get("first_token_s")]
        print(f"\n# wall={time.time() - started:.1f}s  "
              f"max_overlap_ratio={max(ok) / min(ok):.2f}x (2x => one request slot)"
              if len(ok) > 1 else f"\n# wall={time.time() - started:.1f}s")
    return 0 if all(r.get("first_token_s") for r in results) else 2


if __name__ == "__main__":
    sys.exit(main())
