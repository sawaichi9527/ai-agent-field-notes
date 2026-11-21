<#
.SYNOPSIS
Locate duplicate keys in a YAML document that is parsed with duplicate-key rejection.

.DESCRIPTION
A store parsed with `uniqueKeys` fails on a repeated key, and a strict loader may report only
`CODE at line L, column C` -- because the parser's own message quotes the offending line, and in a
credential store that line is the secret. This probe recovers the key name: it parses with the
same `yaml` package and options the CLI uses, walks the AST, and prints **key names and positions
only, never a value**.

Read-only for the target. Side effects: writes one temporary `.mjs` and one output file under
%TEMP%, both removed on exit (rule 3 of tools/README.md: redirect the child, do not pipe it).

.PARAMETER Path
The YAML document to check. Example (DSH credential store):
`"$env:USERPROFILE\.dsh\.credentials.yaml"`.

.PARAMETER DshRoot
Directory containing the `package.json` of an installed CLI that ships `yaml`
(e.g. `...\npm\node_modules\@deepseek-ai\dsh`). Auto-detected with `npm root -g`, then
`%APPDATA%\npm\node_modules` when omitted.

.EXAMPLE
pwsh -File tools\win\probe-store-duplicate-keys.ps1 -Path "$env:USERPROFILE\.dsh\.credentials.yaml"

.OUTPUTS
duplicate keys in <path>:

  "GITEA_TOKEN"  (in refs)
    first   line 19, column 3
    again   line 21, column 3

.NOTES
Exit codes: 0 clean, 1 duplicates found, 2 file/loader problem, 3 another YAML error.
Status: template -- the Node core is verified (four inputs: duplicate, clean, tab indent, missing
file); the PowerShell wrapper has not been run to completion on Windows yet. Mark it proven after
one real run.

This file is ASCII-only on purpose. Windows PowerShell 5.1 decodes a BOM-less script with the system
ANSI code page, so a non-ASCII character (an em dash was enough) inside the embedded JavaScript
corrupts a string literal and fails at the temp file, not here. Keep it ASCII.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$DshRoot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Error -Message "no such file: $Path" -ErrorAction Continue
    exit 2
}
$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath

# Find an installed CLI that ships `yaml`, so the parse options match the product's.
if (-not $DshRoot) {
    $candidates = @()
    try {
        $globalRoot = (& npm root -g 2>$null)
        if ($globalRoot) { $candidates += (Join-Path $globalRoot '@deepseek-ai/dsh') }
    } catch {
        # npm not on PATH -- fall through
    }
    if ($env:APPDATA) {
        $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { $DshRoot = $candidate; break }
    }
}

$env:PROBE_YAML_PATH = $resolved
if ($DshRoot) {
    $env:PROBE_YAML_FROM = Join-Path $DshRoot 'package.json'
} else {
    $env:PROBE_YAML_FROM = ''
}

$core = @'
import { readFileSync, existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const file = process.env.PROBE_YAML_PATH
const from = process.env.PROBE_YAML_FROM || ''

if (!file || !existsSync(file)) {
  console.error('no such file: ' + file)
  process.exit(2)
}

function loadYaml() {
  if (from) {
    try { return createRequire(pathToFileURL(from))('yaml') } catch {}
  }
  try { return createRequire(import.meta.url)('yaml') } catch {}
  console.error('cannot load the `yaml` package; pass -DshRoot <dir with package.json of a CLI that ships yaml>')
  process.exit(2)
}

const YAML = loadYaml()
const text = readFileSync(file, 'utf8')
const doc = YAML.parseDocument(text, { uniqueKeys: true })

function positionOf(offset) {
  if (typeof offset !== 'number') return null
  const before = text.slice(0, offset)
  return { line: before.split('\n').length, column: offset - (before.lastIndexOf('\n') + 1) + 1 }
}

const duplicates = []

function walk(node, where) {
  if (YAML.isMap(node)) {
    const seen = new Map()
    for (const pair of node.items) {
      const key = pair.key
      if (!YAML.isScalar(key)) continue
      const name = String(key.value)
      const pos = positionOf(key.range?.[0])
      if (!seen.has(name)) seen.set(name, [])
      seen.get(name).push(pos)
      walk(pair.value, where === '' ? name : where + '/' + name)
    }
    for (const [name, positions] of seen) {
      if (positions.length > 1) duplicates.push({ where: where || '(root)', name, positions })
    }
  } else if (YAML.isSeq(node)) {
    for (const item of node.items) walk(item, where)
  }
}

walk(doc.contents, '')

const parserErrors = (doc.errors || []).map((e) => ({
  code: e.code,
  positions: (e.linePos || []).map((p) => ({ line: p.line, column: p.col })),
}))

if (duplicates.length === 0 && parserErrors.length === 0) {
  console.log('OK: ' + file + ' has no duplicate keys and parses.')
  process.exit(0)
}

if (duplicates.length > 0) {
  console.log('duplicate keys in ' + file + ':')
  console.log('')
  for (const d of duplicates) {
    console.log('  "' + d.name + '"  (in ' + d.where + ')')
    d.positions.forEach((p, i) => {
      console.log('    ' + (i === 0 ? 'first  ' : 'again  ') + ' line ' + p.line + ', column ' + p.column)
    })
    console.log('')
  }
  console.log('Fix: keep one occurrence per key in each mapping; delete the repeated line')
  console.log('     (and its indented block, for a multi-line record). Do not blank the value --')
  console.log('     an empty string is rejected too; remove the key instead.')
} else {
  console.log('YAML parse errors in ' + file + ':')
  for (const e of parserErrors) {
    const at = e.positions.map((p) => 'line ' + p.line + ', column ' + p.column).join(' / ')
    console.log('  ' + e.code + (at ? ' at ' + at : ''))
  }
  console.log('')
  console.log('(no duplicate keys -- this is a different parse error)')
}

process.exit(duplicates.length > 0 ? 1 : 3)
'@

$node = $null
try {
    $node = (Get-Command node -ErrorAction Stop).Source
} catch {
    Write-Error -Message 'node is not on PATH; the yaml parse needs it' -ErrorAction Continue
    exit 2
}

$tempJs = Join-Path ([IO.Path]::GetTempPath()) ("probe-dupkey-{0}.mjs" -f $PID)
$tempOut = Join-Path ([IO.Path]::GetTempPath()) ("probe-dupkey-{0}.out" -f $PID)
$tempErr = Join-Path ([IO.Path]::GetTempPath()) ("probe-dupkey-{0}.err" -f $PID)

try {
    # ASCII encoding: the core is ASCII on purpose, so no code page can corrupt it.
    Set-Content -LiteralPath $tempJs -Value $core -Encoding ascii
    # Start-Process keeps stdout and stderr off PowerShell's error stream: with
    # $ErrorActionPreference = 'Stop', a native command's stderr becomes a terminating
    # error and would abort before the exit code is read.
    try {
        $process = Start-Process -FilePath $node -ArgumentList @(('"{0}"' -f $tempJs)) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
    } catch {
        Write-Error -Message "cannot run node: $($_.Exception.Message)" -ErrorAction Continue
        exit 2
    }
    $exitCode = $process.ExitCode
    if (Test-Path -LiteralPath $tempOut) { Get-Content -LiteralPath $tempOut | Write-Output }
    if (Test-Path -LiteralPath $tempErr) { Get-Content -LiteralPath $tempErr | Write-Output }
    exit $exitCode
} finally {
    Remove-Item -LiteralPath $tempJs, $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
}
