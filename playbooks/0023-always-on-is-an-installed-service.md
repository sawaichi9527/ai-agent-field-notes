# Playbook 0023 — The always-on mode is an installed service, not a checkbox

**Applies to:** Windows remote-access / background-app products that ship **two runtime modes under
one binary** (RustDesk, TeamViewer-style helpers, …): a normal-app mode and a registered Windows
service run mode. Also to any "it should auto-start and never die with the UI" complaint.
**Answers:** how to recognise the normal-app mode from the process list, install the service mode,
and prove it from the Windows service registration rather than the app window.

This is the method behind
[`cases/2026-11-22-rustdesk-service-mode-win/`](../cases/2026-11-22-rustdesk-service-mode-win/).

## Recognise the mode from the process list first

1. The complaint "I press the x and everything closes" means **no long-running component is left
   after the UI**. Two sub-questions:
   - Does anything stay behind? (`Get-Process` after closing the UI)
   - Does anything auto-start at boot? (whether the tray appears without a manual open)
2. `"No tray process found"` lines in the product's logs are a tell that the tray/long-running
   component was simply **never installed** — not that it crashed.
3. Name the two modes from the CLI / `sc.exe`:
   - normal app mode: main process + UI (`--cm`) process; "x" ends all of them
   - service mode: registered Windows service (`--service`, LocalSystem, AUTO_START) + a separate
     tray process; "x" only closes the UI

## Install the service mode (RustDesk example)

```powershell
& "C:\Program Files\RustDesk\RustDesk.exe" --install-service -wait -Verbose
```

- A GUI binary launched with `&` gives **no exit code**; wait for the registration (~20 s) before
  trusting a `Get-Service` query — an early query returning nothing is a timing artifact, not a
  failure.
- Verify from the Windows service, not the app window:
  `Get-Service RustDesk` → `Running`, display name `RustDesk Service`;
  `sc.exe qc RustDesk` → `START_TYPE 2 AUTO_START`, `SERVICE_START_NAME LocalSystem`,
  `BINARY_PATH_NAME "…RustDesk.exe" --service`.

## Verify from the service registration, not the window

- Re-check `Get-Service` after the registration window, then prove with `sc.exe qc` — the
  authoritative view (start type, service account, binary path). The window tells you nothing about
  auto-start.
- After the install, a main process (no args) and a separate `--tray` process **coexist**; that
  coexistence is the "x no longer kills everything" proof.
- Wording counts: "the close button killed the service too" and "it does not auto-start at boot"
  are the **same missing component** (no registered service, no tray), not two bugs.

## Deliver

`sc.exe qc` rows (start type / service account / binary), `Get-Service` state after the
registration window, and the tray process present in the process list. If a later session reports
the same two symptoms, check the Windows service registration before touching the app.
