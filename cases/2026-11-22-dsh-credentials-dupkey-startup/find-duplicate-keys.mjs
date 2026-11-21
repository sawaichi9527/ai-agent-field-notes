#!/usr/bin/env node
/*
 * find-duplicate-keys.mjs — locate repeated keys in a DSH credential store.
 *
 * Why this exists: DSH parses `.credentials.yaml` with `uniqueKeys: true` and reports a
 * duplicate as `DUPLICATE_KEY at line L, column C` only. The parser's own message would
 * quote the offending line, and in this file that line *is* the secret, so the product
 * deliberately strips it. The key name therefore has to be recovered from the document.
 *
 * What it prints: key names and positions. Never a value.
 * What it uses:  the `yaml` package from the installed dsh, with the same options DSH
 *                parses with, so the verdict matches the boot-time one.
 *
 * Usage:
 *   node find-duplicate-keys.mjs [path]
 *   default path: %USERPROFILE%\.dsh\.credentials.yaml (Windows) / ~/.dsh/.credentials.yaml
 *
 * Exit codes: 0 no duplicates and parsable, 1 duplicates found, 2 file/loader missing, 3 other YAML error.
 *
 * Read-only: it opens the file, never writes.
 */

import { readFileSync, existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const target =
  process.argv[2] ??
  join(process.env.USERPROFILE ?? process.env.HOME ?? '.', '.dsh', '.credentials.yaml')

/** Locate the global dsh package so we can borrow its bundled `yaml`. */
function findDshPackageJson() {
  const candidates = []
  try {
    const root = execSync('npm root -g', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    if (root) candidates.push(join(root, '@deepseek-ai', 'dsh', 'package.json'))
  } catch {
    // no npm on PATH — fall through to the fixed locations
  }
  if (process.env.APPDATA) {
    candidates.push(join(process.env.APPDATA, 'npm', 'node_modules', '@deepseek-ai', 'dsh', 'package.json'))
  }
  candidates.push(
    '/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json',
    '/usr/lib/node_modules/@deepseek-ai/dsh/package.json',
  )
  return candidates.find((p) => existsSync(p))
}

function loadYaml() {
  const pkg = findDshPackageJson()
  if (pkg) {
    try {
      return createRequire(pathToFileURL(pkg))('yaml')
    } catch {
      // fall through
    }
  }
  try {
    return createRequire(import.meta.url)('yaml')
  } catch {
    console.error('cannot load `yaml`: run this on a machine with dsh installed, or pass the file and install yaml')
    process.exit(2)
  }
}

const YAML = loadYaml()

if (!existsSync(target)) {
  console.error(`no such file: ${target}`)
  process.exit(2)
}

const text = readFileSync(target, 'utf8')
const doc = YAML.parseDocument(text, { uniqueKeys: true })

/** 1-based line/column for a byte offset. */
function positionOf(offset) {
  if (typeof offset !== 'number') return null
  const before = text.slice(0, offset)
  return { line: before.split('\n').length, column: offset - (before.lastIndexOf('\n') + 1) + 1 }
}

const duplicates = []

/** Walk the AST; report every key that repeats inside the same mapping, with all its positions. */
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
      walk(pair.value, where === '' ? name : `${where}/${name}`)
    }
    for (const [name, positions] of seen) {
      if (positions.length > 1) duplicates.push({ where: where || '(root)', name, positions })
    }
  } else if (YAML.isSeq(node)) {
    for (const item of node.items) walk(item, where)
  }
}

walk(doc.contents, '')

const parserErrors = (doc.errors ?? []).map((e) => ({
  code: e.code,
  positions: (e.linePos ?? []).map((p) => ({ line: p.line, column: p.col })),
}))

if (duplicates.length === 0 && parserErrors.length === 0) {
  console.log(`OK: ${target} has no duplicate keys and parses.`)
  process.exit(0)
}

if (duplicates.length > 0) {
  console.log(`duplicate keys in ${target}:\n`)
  for (const d of duplicates) {
    const at = d.positions
      .map((p, i) => `    ${i === 0 ? 'first  ' : 'again  '} line ${p.line}, column ${p.column}`)
      .join('\n')
    console.log(`  "${d.name}"  (in ${d.where})\n${at}\n`)
  }
  console.log('Fix: keep one occurrence per key in each mapping; delete the repeated line')
  console.log('     (and its indented block, for a multi-line record). Do not blank the value —')
  console.log('     an empty string is rejected too; remove the key instead.')
} else {
  console.log(`YAML parse errors in ${target}:`)
  for (const e of parserErrors) {
    const at = e.positions.map((p) => `line ${p.line}, column ${p.column}`).join(' / ')
    console.log(`  ${e.code}${at ? ` at ${at}` : ''}`)
  }
  console.log('\n(no duplicate keys — this is a different parse error)')
}

process.exit(duplicates.length > 0 ? 1 : 3)
