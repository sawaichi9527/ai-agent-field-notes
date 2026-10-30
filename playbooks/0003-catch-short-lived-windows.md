# Playbook 0003 — Catch short-lived windows when process polling fails

**Applies to:** Windows (the technique is Windows-specific; the idea is not).
**Answers:** *who* is creating the console window that keeps flashing?

## Why process polling fails

A console window that appears for 100 ms is owned by a process that may live **less than 50 ms**.
Meanwhile on an old CPU a single `Get-Process` call costs ~100 ms, so a loop configured for
`-IntervalMs 40` actually iterates far slower.

Result: you see the *console host* (`conhost.exe`) but never the process that owns it, and the
parent-PID lookup returns nothing because the process is already gone. The output looks like
"owner: (empty)" — which is easy to misread as "no owner".

Three approaches were tried before the one below worked. Each produced a confident-looking empty
result, which is the worst failure mode for a probe:

| Attempt | Why it failed | How it looked |
|---|---|---|
| `Get-Process -Name …` every 40 ms | one call costs ~100 ms on this CPU, so the effective period was ~200-400 ms; a sub-50 ms process never appears in a snapshot | `conhost` births show up with **empty** `Owner` / `ParentName` |
| Resolve the parent PID through CIM right after detection | the parent had already exited, so `Win32_Process -Filter "ProcessId = N"` returns nothing | `parent=5152` with no name and no command line |
| Raise the polling rate only | diminishing returns — the loop can never be faster than its own measurement cost | same empty fields, more CPU burned |
| **Enumerate windows, map back to a PID** | a window that exists proves its owner exists | `owner=git.exe parent=node.exe`, command line included |

Untested alternative: WMI `Win32_ProcessStartTrace` (event-driven, no polling) — needs elevation
and was not tried here. If you have admin rights, it is likely the cleanest option on Windows.

## The fix: observe the window, not the process

A window that exists proves its owning process exists. Enumerating top-level windows is fast
(milliseconds) and gives you a PID you can immediately resolve.

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinEnum
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static List<string> Snapshot()
    {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            var cls = new StringBuilder(256); GetClassName(h, cls, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            var title = new StringBuilder(512); GetWindowText(h, title, 512);
            list.Add(h.ToInt64() + "|" + cls + "|" + (IsWindowVisible(h) ? "1" : "0") + "|" + pid + "|" + title);
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

$known = @{}
foreach ($line in [WinEnum]::Snapshot()) { $known[($line -split '\|')[0]] = $true }

while ($true) {
  foreach ($line in [WinEnum]::Snapshot()) {
    $f = $line -split '\|', 5
    if ($known.ContainsKey($f[0])) { continue }
    $known[$f[0]] = $true
    if ($f[1] -notin @('ConsoleWindowClass','PseudoConsoleWindow','CASCADIA_HOSTING_WINDOW_CLASS')) { continue }

    # resolve immediately, while the owner is guaranteed alive
    $pid_ = [uint32]$f[3]
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId = $pid_" -EA SilentlyContinue
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($ci.ParentProcessId)" -EA SilentlyContinue
    "{0} visible={1} pid={2} {3}  parent={4}({5})" -f (Get-Date -Format 'HH:mm:ss.fff'), $f[2], $pid_, $ci.Name, $parent.Name, $ci.ParentProcessId
    if ($ci.CommandLine) { "    " + $ci.CommandLine }
  }
  Start-Sleep -Milliseconds 30
}
```

Full working version: [`tools/win/watch-console-windows.ps1`](../tools/win/watch-console-windows.ps1).

## What to read from the output

| Field | Meaning |
|---|---|
| `Owner` = `git.exe`, `parent` = `node.exe` | the agent process spawned a git command → look in the plugin that runs `git` |
| `Visible=True` | this window is actually on screen — a candidate for the flash **and** for focus theft |
| `Visible=False` | the console exists but is hidden — not your visual symptom, ignore it |
| cadence | the interval is a fingerprint; match it against `setInterval(…, N)` in the source |

## Caveat observed here

Some of the *visible* windows had an empty `CommandLine` (the CIM query lost the race). Do not
conclude "unknown command means unknown cause" — treat visibility and cadence as the primary
evidence, and confirm the attribution by applying the fix and re-observing.

## Linux equivalent

There is no window to enumerate; use the fact that a short-lived child still leaves a trace:

- `execsnoop` / `bpftrace` if available
- `auditd` with `-a always,exit -S execve` (records the parent PID)
- otherwise: `strace -f -e trace=execve -p <agent pid>` for a bounded window

See [`tools/linux/`](../tools/linux/) for status.
