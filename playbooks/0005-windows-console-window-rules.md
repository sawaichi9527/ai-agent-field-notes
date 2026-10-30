# Playbook 0005 — On Windows, stdio decides whether a console appears

**Applies to:** Windows, any Node/CLI agent that spawns helpers.
**Answers:** will this child process pop a console window, and does `windowsHide` matter?

## The rule that is usually quoted

> A console program started by a process with no console gets a new console window, unless
> `CREATE_NO_WINDOW` (`windowsHide: true`) is passed.

**This is wrong in the form that matters.** Measured here, from a parent with **no console**:

| child stdio | console created? |
|---|---|
| `stdio: 'ignore'` (NUL) | **no** |
| `stdio: ['ignore','inherit','pipe']` (files/pipes inherited) | **no** |
| stdio not specified (must attach to a console that does not exist) | yes |

So the deciding factor is **whether the child receives valid stdio handles**, not `windowsHide`.
`windowsHide` is an extra safety belt, not the switch.

## Practical consequences

- A spawn already using `stdio: 'ignore'` or redirected handles will **not** flash, with or without
  `windowsHide`. Adding it is harmless but changes nothing — do not claim it as a fix.
- Two spawns in the same chain can differ: if the first one creates a console, the second inherits
  it and never creates one. Fix only one of them and the flash can survive.
- When a console *is* created, it **takes foreground focus** — that is the real damage. Users report
  "typing loses characters", not "a rectangle appeared".

## How to test it in ten seconds

Set up the parent so it has no console (this is the normal state of an agent restarted by a helper):
`CreateNoWindow = $true` plus redirected output. Then spawn a child and have the child report:

```powershell
# child probe
Add-Type -Name K -Namespace N -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetConsoleProcessList(uint[] list, uint count);
"@
$h = [N.K]::GetConsoleWindow()
"{0}|{1}" -f ($h -ne [IntPtr]::Zero), (if ($h -ne [IntPtr]::Zero) { [N.K]::GetConsoleProcessList((New-Object uint32[] 32), 32) } else { 0 })
```

Always include a **control**: the same probe started from a parent that *does* have a console must
report `True` with 2 or more attached PIDs. Without that control, a run where everything reports
`False` cannot be distinguished from "this environment cannot create consoles at all".

## Two adjacent facts worth knowing

- **`detached: true` is not the same as `windowsHide: true`.** In Node on Windows, `detached` gives
  the child its own process group; combined with a console-less parent the behaviour is easy to
  misread. One Windows-only observation here: from a console-less parent, `detached: true` +
  `PowerShell` **silently did nothing** (`exit code 0`, empty stdout/stderr, command never ran),
  while `cmd.exe` was fine. Do not use detached PowerShell as a launcher.
- **`conhost.exe` existing does not mean a window is visible.** Reading `IsWindowVisible` and
  `MainWindowHandle` is the only reliable answer.

## Reading a child's own state

`MainWindowHandle` on the *agent* process:

- `0` → no console. This is the **expected** state for anything started by a detached helper; it is
  not a defect and not evidence of a bug.
- The presence of a `restart-helper-<pid>.log` line saying only `loaded` tells you **nothing** about
  consoles — it only means the helper module was imported.
