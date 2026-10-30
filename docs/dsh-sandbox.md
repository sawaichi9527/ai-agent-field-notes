# What the agent sandbox actually blocks (measured)

Every row below was observed on Windows 10 with DSH 0.2.1-rc.5. "Denied" means the command
failed for permission reasons, not that it produced wrong output.

This matters because the sandbox looks like an ordinary shell until a probe quietly returns a
false negative. See [playbook 0002](../playbooks/0002-sandbox-measurements-lie.md) for what that
costs.

## Denied

| Operation | Observed failure |
|---|---|
| Writing anywhere outside the session workspace | `EPERM: operation not permitted, open '<path>\cordis.yml'` at `prepareProfile` |
| `--dump-config` on a real profile | same `EPERM` - it rewrites `cordis.yml`, so it is **not** a read-only escape hatch |
| Capturing a spawned child's output through a pipe | `Program 'pwsh.exe' failed to run: 存取被拒` / `EINVAL` for `RedirectStandardOutput` |
| `tasklist` | `ERROR: Access denied` |
| `Get-CimInstance Win32_OperatingSystem` / `Win32_Processor` | `拒絕存取` (access denied) |
| Creating a junction / symlink (even inside the workspace, pointing outside) | `New-Item -ItemType Junction` → `存取被拒` |
| TLS from a child process | `curl`: `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`; `Invoke-WebRequest`: `AuthenticationException: 安全性封裝沒有可供使用的認證` |
| `git` over HTTPS | `error: cannot create standard input pipe for remote-https: Permission denied` (git needs a pipe for its helper) |

## Available

| Operation | Notes |
|---|---|
| Reading files anywhere (including `~/.dsh`) | reads are not restricted; only writes |
| `Get-Process -Id <pid>` | works, including `MainWindowHandle` and `TotalProcessorTime` |
| `Get-Process -Name <list>` | works, but name-only wildcard queries were sometimes partial |
| `Get-CimInstance Win32_Process -Filter "ProcessId = N"` | works for **live** PIDs; a short-lived process is already gone (timing, not permission) |
| `New-Item -ItemType Directory` inside the workspace | works |
| `cmd /c ... > file` (redirect to a file) | works - this is the way around the pipe restriction |

Note the asymmetry: **`Get-Process` mostly works, `tasklist` and several WMI system classes do not.**
Do not generalise from one denial.

## Workarounds that worked

| Goal | Technique |
|---|---|
| Measure a real startup without touching the real profile | point `DSH_HOME` at a directory **inside** the workspace, then the writes land somewhere permitted |
| Read a child's stdout | redirect to a file (`> out.txt`) and read the file afterwards - never a pipe |
| Get CPU time of a child you cannot enumerate | inject a preload: `NODE_OPTIONS=--import ./preload.mjs`, and report `process.cpuUsage()` from inside the child |
| Find who owns a transient console window | enumerate windows, map back to a PID (see [playbook 0003](../playbooks/0003-catch-short-lived-windows.md)) |

## What the mirror approach cannot reproduce

A mirror `DSH_HOME` inside the workspace has no `node_modules` for the profile, so the runtime
resolves plugins through a different path than a real profile. Measured consequence: the same
2-bundle configuration read **37-48 s / 55-70 % CPU** in the mirror versus **21.6 s / 106-109 %**
on the real profile. The wall time is inflated and the ratio lands in the wrong band.

**Therefore: the mirror is fine for "did it start", never for "how fast is it in relative terms".**

## Rule of thumb

If a probe's answer is "nothing happens" or "every configuration is identical", first prove the
environment *can* produce the effect:

```powershell
# can this shell create a console at all?
Start-Process $env:ComSpec -ArgumentList '/c timeout 5' -WindowStyle Normal

# can it write outside the workspace?
try { [IO.File]::WriteAllText("$env:USERPROFILE\.dsh\probe.txt","x"); 'writable' } catch { "denied: $($_.Exception.Message)" }
```

If either fails, every measurement taken in that shell is unusable - move to a normal terminal.
