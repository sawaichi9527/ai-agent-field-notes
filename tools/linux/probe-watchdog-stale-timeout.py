#!/usr/bin/env python3
"""Layer-1 probe for the coordinator hung-worker local-decode-backend stall.

Verifies the *mechanism* behind `agent.local_stream_stale_timeout` (the fix that
lowered the local stale ceiling from 900s to 300s). It does NOT reproduce a real
stall — it proves two things about the watchdog resolver:

  1. test_local_endpoint_ttfb_default_uses_local_stale_ceiling
     -> a LOCAL endpoint takes the configured HERMES_LOCAL_STREAM_STALE_TIMEOUT as
        its implicit no-event TTFB cutoff; hosted endpoints keep the 120s default.
  2. test_ttfb_does_not_kill_when_events_flow
     -> once a stream event has arrived, a generation that runs PAST the TTFB
        cutoff is NOT killed (no false-positive kill).

Run against the live hermes-agent checkout (DUT). Requires the venv python that
has the runtime deps (ruamel.yaml etc.). If invoked under an interpreter without
those deps, prepend the venv site-packages so the hermes import chain resolves.

Usage:
  venv/bin/python tools/linux/probe-watchdog-stale-timeout.py \
      --hermes-agent /home/eye/.hermes/hermes-agent

Exit 0 = both checks PASS; exit 1 = at least one FAIL.
"""
import argparse
import os
import sys
import tempfile
import time
from types import SimpleNamespace


def _ensure_runtime_deps(hermes_agent: str):
    """Make `agent.*` and its deps importable regardless of which interpreter ran us.

    The running interpreter may differ from the venv's (the terminal wrapper relaunches
    under Python 3.14 while the hermes venv is 3.11). So scan for the real site-packages
    instead of trusting sys.version_info.
    """
    import glob
    venv_lib = os.path.join(hermes_agent, "venv", "lib")
    found = False
    for candidate in sorted(glob.glob(os.path.join(venv_lib, "python*", "site-packages"))):
        if os.path.isdir(candidate) and candidate not in sys.path:
            sys.path.insert(0, candidate)
            found = True
    for p in (hermes_agent, os.path.join(hermes_agent, "tests", "agent")):
        if p not in sys.path:
            sys.path.insert(0, p)
    return found


def _make_codex_agent(tmp_path, monkeypatch, provider="custom", base_url=None):
    """Self-contained replica of the test module's fixture (no pytest import)."""
    import pathlib
    tmp_path = pathlib.Path(tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("", encoding="utf-8")
    (tmp_path / "config.yaml").write_text("{}\n", encoding="utf-8")
    for name in ("HERMES_CODEX_TTFB_TIMEOUT_SECONDS", "HERMES_CODEX_TTFB_MAX_SECONDS",
                 "HERMES_CODEX_TTFB_DISABLE_ABOVE_TOKENS", "HERMES_CODEX_TTFB_STRICT"):
        monkeypatch.delenv(name, raising=False)
    from run_agent import AIAgent
    agent = AIAgent(
        model="gpt-5.5", provider=provider, api_key="sk-dummy",
        base_url=base_url or "https://chatgpt.com/backend-api/codex",
        quiet_mode=True, skip_context_files=True, skip_memory=True, platform="cli",
    )
    agent.api_mode = "codex_responses"
    monkeypatch.setattr(agent, "_emit_status", lambda *a, **k: None)
    monkeypatch.setattr(agent, "_compute_non_stream_stale_timeout", lambda *a, **k: 60.0)
    return agent


class FakeMP:
    """Minimal stand-in for pytest's monkeypatch fixture."""
    def __init__(self):
        self._env = []
        self._attr = []
    def setenv(self, k, v, raising=True):
        self._env.append((k, os.environ.get(k)))
        os.environ[k] = str(v)
    def delenv(self, k, raising=False):
        self._env.append((k, os.environ.get(k)))
        os.environ.pop(k, None)
    def setattr(self, target, name, value):
        if isinstance(target, str):
            mod = __import__(target)
            for part in target.split(".")[1:]:
                mod = getattr(mod, part)
            name, target = name, mod
        self._attr.append((target, name, getattr(target, name, None)))
        setattr(target, name, value)


def check_local_stale_ceiling():
    """Test 1: local endpoint honors the configured stale ceiling."""
    from agent import chat_completion_helpers as h
    mp = FakeMP()
    mp.setenv("HERMES_LOCAL_STREAM_STALE_TIMEOUT", "600")
    local = _make_codex_agent(tempfile.mkdtemp(), mp, provider="custom",
                              base_url="http://127.0.0.1:11434/v1")
    hosted = _make_codex_agent(tempfile.mkdtemp(), mp, provider="custom",
                               base_url="https://api.example.com/v1")
    kwargs = {"model": "qwen3-27b", "input": "hi"}
    local_ttfb = h._resolve_nonstream_watchdogs(local, kwargs).ttfb_timeout
    hosted_ttfb = h._resolve_nonstream_watchdogs(hosted, kwargs).ttfb_timeout
    ok_local = abs(local_ttfb - 600.0) < 1e-9
    ok_hosted = abs(hosted_ttfb - 120.0) < 1e-9
    print(f"  local endpoint   ttfb_timeout = {local_ttfb}  (expect 600.0) -> {'PASS' if ok_local else 'FAIL'}")
    print(f"  hosted endpoint  ttfb_timeout = {hosted_ttfb}  (expect 120.0) -> {'PASS' if ok_hosted else 'FAIL'}")
    return ok_local and ok_hosted


def check_events_flow_not_killed():
    """Test 2: a stream that emits events is not killed past the TTFB cutoff."""
    from agent import chat_completion_helpers as h
    mp = FakeMP()
    agent = _make_codex_agent(tempfile.mkdtemp(), mp)
    mp.setenv("HERMES_CODEX_TTFB_TIMEOUT_SECONDS", "0.4")
    closes = []
    dummy_client = SimpleNamespace()
    mp.setattr(agent, "_create_request_openai_client", lambda **k: dummy_client)
    mp.setattr(agent, "_abort_request_openai_client", lambda c, reason=None: closes.append(reason))
    mp.setattr(agent, "_close_request_openai_client", lambda c, reason=None: closes.append(reason))
    sentinel = SimpleNamespace(ok=True)

    def fake_stream(api_kwargs, client=None, on_first_delta=None):
        from agent.codex_runtime import _codex_watchdog_state_var
        now = time.time()
        state = _codex_watchdog_state_var.get()
        with state.lock:
            state.last_event_ts = now
        if on_first_delta:
            on_first_delta()
        time.sleep(0.9)  # run PAST the 0.4s cutoff after an event already arrived
        return sentinel

    mp.setattr(agent, "_run_codex_stream", fake_stream)
    resp = h.interruptible_api_call(agent, {"model": "gpt-5.5", "input": "hi"})
    ok_resp = resp is sentinel
    ok_no_kill = "codex_ttfb_kill" not in closes
    print(f"  return value is sentinel           -> {'PASS' if ok_resp else 'FAIL'}")
    print(f"  no codex_ttfb_kill close           -> {'PASS' if ok_no_kill else 'FAIL'} (closes={closes})")
    return ok_resp and ok_no_kill


def main():
    p = argparse.ArgumentParser(description="Layer-1 watchdog stale-ceiling probe")
    p.add_argument("--hermes-agent", default=os.environ.get("HERMES_AGENT_REPO", "/home/eye/.hermes/hermes-agent"))
    args = p.parse_args()

    _ensure_runtime_deps(args.hermes_agent)

    print("=== Test 1: local endpoint uses the local stale ceiling ===")
    r1 = check_local_stale_ceiling()
    print("=== Test 2: ttfb watchdog does NOT kill when events flow ===")
    r2 = check_events_flow_not_killed()
    print()
    result = "ALL PASS" if (r1 and r2) else "SOME FAILED"
    print(f"RESULT: {result}")
    return 0 if (r1 and r2) else 1


if __name__ == "__main__":
    sys.exit(main())
