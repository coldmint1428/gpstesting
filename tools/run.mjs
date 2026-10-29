#!/usr/bin/env node
// Run a scripted browser check:
//
//     node tools/run.mjs dev/checks/board-smoke.mjs
//     node tools/run.mjs dev/checks/board-smoke.mjs --session .tmp/session.json
//
// The check module default-exports { name, run } (or exports run) and receives:
//
//     { browser, newTab, base, session, flag }
//
// A check fails by throwing -- tools/browser.mjs throws on the first assertion that is not true, with what the
// page actually said. Exit code is 0 only when the whole check passed AND every tab was free of console errors.
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import fs from 'node:fs'
import { openBrowser, CheckFailure } from './browser.mjs'

const argv = process.argv.slice(2)
const file = argv.find((a) => !a.startsWith('--') && !a.startsWith('-') && a !== '')
const args = {}
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === '--session') args.session = argv[++i]
  else if (argv[i] === '--base') args.base = argv[++i]
  else if (argv[i] === '--port') args.port = argv[++i]
}

if (!file) {
  console.error('usage: node tools/run.mjs <check.mjs> [--session <file>] [--base <url>] [--port 9222]')
  process.exit(2)
}

const base = args.base || process.env.PREVIEW_BASE || 'http://localhost:5178'

let session = null
if (args.session) {
  if (!fs.existsSync(args.session)) {
    console.error(`no session file at ${args.session} (mint one with tools/authlink.mjs)`)
    process.exit(2)
  }
  session = JSON.parse(fs.readFileSync(args.session, 'utf8'))
}

const browser = await openBrowser({ port: args.port || process.env.CDP_PORT || 9222 })
const tabs = []
const newTab = async (options = {}) => {
  const tab = await browser.newTab({ session, ...options })
  tabs.push(tab)
  return tab
}

const module = await import(pathToFileURL(path.resolve(file)).href)
const check = module.default || module
const name = check.name || path.basename(file, '.mjs')

console.log(`▶ ${name}`)
let failure = null
try {
  await check.run({ browser, newTab, base, session, arg: (key, fallback) => process.env[key] ?? fallback })
} catch (error) {
  failure = error
}

// Every assertion, in order, including the one that threw: record() keeps its own failure.
let passed = 0
for (const tab of tabs) {
  for (const item of tab.checks) {
    if (item.ok) {
      passed += 1
      console.log(`  ok    ${tab.label}  ${item.what}`)
    } else {
      console.log(`  FAIL  ${tab.label}  ${item.what}${item.detail ? '\n        ' + item.detail : ''}`)
    }
  }
}

// A page may have been expected to log a failure (a refusal the UI shows in words): those are excused by the check
// itself, in the same place, so the verdict here and assertNoErrors() cannot disagree.
const errors = tabs.flatMap((tab) => {
  const { problems, missing } = tab.unexplained()
  return [
    ...problems.map((p) => `${tab.label}  ${p}`),
    ...missing.map((entry) => `${tab.label}  the expected HTTP ${entry.status} from ${entry.urlPart} never happened`),
  ]
})
for (const line of errors) console.log(`  page  ${line}`)

await browser.close()

if (failure) {
  console.log('')
  console.log(`FAIL ${name}: ${failure instanceof CheckFailure ? failure.message : failure.stack || failure.message}`)
  process.exit(1)
}
if (errors.length) {
  console.log('')
  console.log(`FAIL ${name}: ${errors.length} console error(s) or exception(s)`)
  process.exit(1)
}

console.log('')
console.log(`PASS ${name} (${passed} assertion${passed === 1 ? '' : 's'}, ${tabs.length} tab${tabs.length === 1 ? '' : 's'})`)
process.exit(0)
