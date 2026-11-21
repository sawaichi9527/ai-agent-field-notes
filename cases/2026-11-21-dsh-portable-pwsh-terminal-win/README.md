# Case: the sidebar terminal still spawns the built-in Windows PowerShell — the terminal is owned by a host service, not the sidebar plugin

**Tool:** DSH CLI 0.2.2-rc.5, profile `web`, third-party `dsh-better-sidebar` 0.32.1 · **OS:** Windows 10 · **Date:** 2026-11-21
**Full write-up (Chinese):** [`write-up.md`](write-up.md) · **Reusable method:** [playbook 0020](../../playbooks/0020-the-terminal-is-owned-by-the-host-service.md)

## Symptom

DSH's own `pwsh` tool already ran portable PowerShell **7.6.10** (via `dsh-power-xc` `pwshPath`),
but a terminal opened from the `dsh-better-sidebar` workbench was still the **built-in Windows
PowerShell 5.1** — as if the 7.6.10 install had never happened.

## Root cause

The sidebar plugin has **no PTY of its own** in 0.32.1. It drives the host `webTerminals` service
(`@deepseek-ai/dsh-api-terminal-controller` client half) and its open-terminal call
(`service.view(sessionId, contentId, contentId)`) carries **no shellPath**. The shell is then
decided entirely by the host service:

```text
Config.shell  of the terminal-controller entry      ← highest
 (absent) → subprocess environment default          (Windows → built-in PowerShell 5.1)
new terminal (no shellPath) → remote.shells()       (discoverShells: configured / default first)
   → localStorage dsh.terminal.shell matches by exact path, else shells[0] = configured shell
```

So editing the plugin changes nothing — the place to patch is the **host service overlay**, which
`@deepseek-ai/dsh-web-app` mounted without a config.

## Fix

Append a profile overlay row for the host service entry with a self-contained portable shell:

```yaml
- id: terminal-controller
  name: "@deepseek-ai/dsh-api-terminal-controller"
  config:
    shell:
      path: C:/workspace/bin/pwsh7-7.6.10/pwsh.exe
      name: PowerShell 7.6.10 (portable, pwsh7 pack)
      args: ["-NoLogo"]
```

On this CLI the profile carries `patchReload: "live"` (0.2.2-rc.5), so the valid config change
**hot-applies without a restart** (in contrast to a config that fails validation — that still needs
a restart; see the 2026-11-13 dsh-gitea case). The composed tree was independently verified with
`dsh --profile web --dump-config` (run outside the agent sandbox).

## Verification (in a NEW terminal)

```powershell
$PSVersionTable.PSVersion.ToString(); (Get-Process -Id $PID).Path
```
→ `7.6.10` and `C:\workspace\bin\pwsh7-7.6.10\pwsh.exe` (user-confirmed).

Already-open terminals keep their old process; always open a new terminal.
