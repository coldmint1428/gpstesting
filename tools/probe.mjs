// tools/probe.mjs -- ask a page that is already open one question.
//
//   node tools/probe.mjs 9222 "return JSON.stringify($$('[data-testid^=\"area-row-\"]').length)"
//   node tools/probe.mjs 9222 @question.js       (the snippet in a file: no shell quoting at all)
//
// Connects to the Firefox already listening on that port (see tools/bidi.mjs for why it is a BiDi
// socket and not an HTTP session), evaluates the snippet in the page's scope with the harness
// helpers available, and prints the answer. Not part of the harness: this is the tool for looking at
// a live page while working out why something is the way it is.

import { readFileSync } from 'node:fs'
import { Driver } from './bidi.mjs'

const port = Number(process.argv[2] || 9222)
const given = process.argv[3] || 'return JSON.stringify({ url: location.pathname, ready: document.readyState })'
const snippet = given.startsWith('@') ? readFileSync(given.slice(1), 'utf8') : given

const driver = await new Driver('probe', port).open()
try {
  const answer = await driver.js(snippet)
  console.log(typeof answer === 'string' ? answer : JSON.stringify(answer))
} catch (error) {
  console.log('probe failed: ' + error.message)
} finally {
  await driver.end()
}
