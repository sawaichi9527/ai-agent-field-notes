#!/usr/bin/env python3
# STATUS : proven
# PLATFORM: linux
# NEEDS  : python3 (stdlib only); a server log that records the SSE packets verbatim
#          (LM Studio: ~/.lmstudio/server-logs/<yyyy-mm>/*.log, "Generated packet: {json}")
# ANSWERS: when a UI says "N tokens" and the number stops moving, what did the engine actually
#          stream - and which part of that stream was the UI not counting?
# SIDE EFFECTS: none, read-only (opens the log read-only)
# USED BY: playbooks/0014-frozen-counter-is-a-claim-about-the-ui.md,
#          cases/2026-11-18-lmstudio-token-counter-frozen/
"""Reconstruct one streamed response from a server log and split it by delta type.

The point is arithmetic, not parsing: a counter that reads 125 while the engine logged
159k tokens is only explainable if the counter counts a *subset* of the deltas. This
probe prints that subset (text chunks) next to the rest (tool-call chunks), so the
subset can be matched against the number on screen.

Usage:
    probe-sse-delta-mix.py --log ~/.lmstudio/server-logs/2026-11/2026-11-18.30.log
    probe-sse-delta-mix.py --log a.log --log b.log --id chatcmpl-abc123
    probe-sse-delta-mix.py --log a.log --show-args 400

Exit code: 0 if at least one packet was parsed, 1 otherwise (a log with no packets is a
negative result, not a clean run).
"""

import argparse
import json
import sys

MARKER = "Generated packet: "


def packets(text):
    """Yield each JSON object that follows MARKER, tolerating pretty-printed bodies."""
    pos = 0
    while True:
        i = text.find(MARKER, pos)
        if i < 0:
            return
        start = i + len(MARKER)
        # The record ends at the next timestamped log line ("\n[YYYY-...").
        end = text.find("\n[", start)
        chunk = text[start:end] if end != -1 else text[start:]
        pos = end if end != -1 else len(text)
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            yield json.loads(chunk)
        except json.JSONDecodeError:
            continue


def repeated_tail(s, window=4000, max_period=80):
    """Return (period, unit) if the tail of s is a repetition, else None."""
    tail = s[-window:]
    for p in range(6, max_period):
        if len(tail) < p * 2:
            break
        # every char matches the one p back -> tail is p-periodic
        if all(tail[i] == tail[i - p] for i in range(p, len(tail))):
            return p, tail[-p:]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", action="append", required=True, help="log file(s), in stream order")
    ap.add_argument("--id", help="only packets whose top-level id matches")
    ap.add_argument("--show-args", type=int, default=300,
                    help="chars of each tool_call's arguments to print (0 = hide)")
    args = ap.parse_args()

    keys = {}
    text = {"reasoning_content": [], "content": []}
    calls = {}
    models, ids, finishes = set(), set(), set()
    n = 0

    for path in args.log:
        with open(path, errors="replace") as fh:
            data = fh.read()
        for pkt in packets(data):
            if args.id and pkt.get("id") != args.id:
                continue
            if not pkt.get("choices"):
                continue
            n += 1
            ids.add(pkt.get("id"))
            models.add(pkt.get("model"))
            ch = pkt["choices"][0]
            if ch.get("finish_reason"):
                finishes.add(ch["finish_reason"])
            d = ch.get("delta") or {}
            for k in d:
                keys[k] = keys.get(k, 0) + 1
            for k in text:
                if d.get(k):
                    text[k].append(d[k])
            for tc in d.get("tool_calls") or []:
                idx = tc.get("index", 0)
                fn = tc.get("function") or {}
                slot = calls.setdefault(idx, {"name": fn.get("name"), "parts": []})
                if fn.get("name"):
                    slot["name"] = fn["name"]
                slot["parts"].append(fn.get("arguments") or "")

    if n == 0:
        print("no packets parsed - check --log path and the marker", file=sys.stderr)
        return 1

    text_chunks = sum(len(v) for v in text.values())
    tool_chunks = keys.get("tool_calls", 0)
    print(f"packets           {n}")
    print(f"ids               {', '.join(sorted(i for i in ids if i))}")
    print(f"models            {', '.join(sorted(m for m in models if m))}")
    print(f"delta keys        {keys}")
    print(f"text chunks       reasoning={len(text['reasoning_content'])} "
          f"content={len(text['content'])} -> {text_chunks}")
    print(f"tool-call chunks  {tool_chunks}")
    print(f"finish_reasons    {finishes or 'none'}")
    print()
    for k in ("reasoning_content", "content"):
        body = "".join(text[k])
        if body:
            print(f"{k} ({len(body)} chars): {body[:300]!r}...")
    for idx, slot in sorted(calls.items()):
        s = "".join(slot["parts"])
        print()
        print(f"tool_call[{idx}] name={slot['name']} args={len(s)} chars")
        if args.show_args:
            print(f"  head: {s[:args.show_args]!r}")
            print(f"  tail: {s[-args.show_args:]!r}")
        rep = repeated_tail(s)
        if rep:
            print(f"  REPEAT: period {rep[0]} -> {rep[1]!r} repeated to the end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
