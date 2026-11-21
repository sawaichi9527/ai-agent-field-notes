# Case: RustDesk does not auto-start and the "x" closes everything — the always-on tray mode is a Windows service that was never installed

**Tool:** RustDesk (Windows build 17763) · **OS:** Windows 10 Enterprise LTSC · **Date:** 2026-11-22
**Full write-up (Chinese):** [`write-up.md`](write-up.md) · **Reusable method:** [playbook 0023](../../playbooks/0023-always-on-is-an-installed-service.md)

## Symptom

Two complaints after installing RustDesk on Windows:

1. It does not auto-start when the PC boots.
2. Pressing the "x" in the top-right corner closes the whole set of processes — it does **not**
   shrink to the bottom-right tray icon and keep running.

## Root cause

RustDesk on Windows has **two runtime modes**, and the symptom is the **normal-app mode**:

- **Normal app mode:** a main process plus a `--cm` UI process. Pressing "x" ends all of them, and
  nothing stays behind — no auto-start, no tray.
- **Service mode (what "auto-start + always-on tray" requires):** a Windows service named
  **"RustDesk Service"** (`RustDesk.exe --service`, LocalSystem, AUTO_START) plus a separate
  `--tray` process. With the service installed the app runs before/after login and survives "x".

The Windows service was simply never installed, so the app was running only as a regular
application. The two complaints are the **same** missing component (no registered service, no tray).

## Fix

```text
& "C:\Program Files\RustDesk\RustDesk.exe" --install-service -wait -Verbose
```

A GUI binary (`&`) — it gives no exit code, and service registration takes ~20 s. Do **not** trust
an early `Get-Service` check; re-check after the registration window.

## Verification

- `Get-Service RustDesk` → `Running`, display name `RustDesk Service` (appears only after the
  ~20 s registration — an early check is a false negative, not a failure).
- `sc.exe qc RustDesk` → `TYPE 10 WIN32_OWN_PROCESS`, `START_TYPE 2 AUTO_START`,
  `SERVICE_START_NAME LocalSystem`, `BINARY_PATH_NAME "C:\Program Files\RustDesk\RustDesk.exe" --service`.
- Install log `C:\Users\<you>\AppData\Roaming\RustDesk\log\install-service\RustDesk_rCURRENT.log`:
  `start --install-service` → `Installing service...` → `Spawn new window`.
- After the install, a main process (no args) and a `--tray` process both exist — the tray
  component is present and keeps running when the UI closes (the "x no longer kills everything"
  proof).
- Prior evidence: on 2026-11-13 the update log already had `"No tray process found. Try to restore
  the main window process..."` — the tray was never installed, not crashed.
