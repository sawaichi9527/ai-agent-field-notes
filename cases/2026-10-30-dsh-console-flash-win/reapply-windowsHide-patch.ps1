# reapply-windowsHide-patch.ps1
#
# STATUS : remediation (not a probe - it changes installed files)
# PLATFORM: windows
# ANSWERS: re-applies the local windowsHide fix to @goodandready/dsh-gitea after an upgrade
# SIDE EFFECTS: edits <package>/lib/git-local.js in place (backup written next to it);
#               requires a `dsh web` restart to take effect
# USED BY: cases/2026-10-30-dsh-console-flash-win/
#
# The bug: the chat-header git chip polls GET /dsh-gitea/git-status every 4 s; the route
# calls isGitDir() -> readGit(), which runs `git rev-parse --show-toplevel` with
# child_process.exec() and no windowsHide.  On Windows every spawn opens a console window
# that steals foreground focus (visible flash, lost keystrokes).
#
# Upstream is still unfixed as of 0.7.41 (checked 2026-11-09: npm `latest` is 0.7.41 and
# lib/git-local.js on `main` still has no windowsHide), so this patch is expected to be
# lost on every upgrade.  Re-run this script afterwards.
#
# Usage:
#   .\reapply-windowsHide-patch.ps1            # patch
#   .\reapply-windowsHide-patch.ps1 -DryRun    # show what would change
#   .\reapply-windowsHide-patch.ps1 -PackageDir <path>
#
# A restart of `dsh web` is required after patching (modules are loaded at startup).

[CmdletBinding()]
param(
  [string]$PackageDir = "$env:USERPROFILE\.dsh\profiles\web\node_modules\@goodandready\dsh-gitea",
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $PackageDir 'package.json'))) {
  throw "not a dsh-gitea package dir: $PackageDir"
}

$version = (Get-Content (Join-Path $PackageDir 'package.json') -Raw | ConvertFrom-Json).version
$file = Join-Path $PackageDir 'lib\git-local.js'
if (-not (Test-Path $file)) { throw "missing $file" }

$raw = [System.IO.File]::ReadAllText($file)

if ($raw -match 'windowsHide') {
  Write-Host "dsh-gitea $version : git-local.js already contains windowsHide - nothing to do."
  return
}

# readGit (20 s) and writeGit (30 s).  The option objects are literal and stable
# across 0.7.x; both are anchored on `cwd, timeout: N, maxBuffer: 2 * 1024 * 1024`.
$pattern = '\{ cwd, timeout: (20_000|30_000), maxBuffer: 2 \* 1024 \* 1024 \}'
$matches = [regex]::Matches($raw, $pattern)
if ($matches.Count -ne 2) {
  throw "expected 2 exec option objects in $file, found $($matches.Count) - upstream changed; patch manually"
}

$patched = [regex]::Replace(
  $raw,
  $pattern,
  '{ cwd, timeout: $1, maxBuffer: 2 * 1024 * 1024, windowsHide: true }'
)

if ($DryRun) {
  Write-Host "dsh-gitea $version : would patch $file"
  $i = 0
  foreach ($m in $matches) {
    $i++
    $line = ($raw.Substring(0, $m.Index) -split "`n").Count
    Write-Host ("  line {0}: {1}" -f $line, $m.Value)
    Write-Host ("        -> {0}" -f ($m.Value -replace '\}$', ', windowsHide: true }'))
  }
  return
}

$backup = "$file.bak-" + $version
if (-not (Test-Path $backup)) {
  Copy-Item $file $backup
  Write-Host "backup: $backup"
}

[System.IO.File]::WriteAllText($file, $patched, [System.Text.UTF8Encoding]::new($false))
Write-Host "patched dsh-gitea $version : added windowsHide: true to readGit/writeGit"
Write-Host 'restart dsh web for the patch to take effect.'
