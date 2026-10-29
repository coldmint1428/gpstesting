#!/usr/bin/env node
// Run one SQL script against the Supabase project through the Management API.
//
// The REST API cannot do DDL, and the service_role key is data-only, so anything that changes the shape of the
// database has to go through this endpoint with a personal access token. That token can do anything, so it is
// read from the environment and never written to a file:
//
//   $env:SUPABASE_PAT = 'sbp_...'
//   Get-Content -Raw .\some.sql | node tools/sql.mjs
//   node tools/sql.mjs --file supabase/migrations/038_plan_frames.sql
//
// Also used to impersonate a role when checking the security-definer functions:
//   set local request.jwt.claims = '{"sub":"<user id>","role":"authenticated"}';
//
// Node's TLS stack, not the shell's: PowerShell's Schannel path fails in this sandbox with
// SEC_E_NO_CREDENTIALS, while fetch() goes through OpenSSL and works.

import fs from 'node:fs'

const REF = process.env.SUPABASE_REF || 'ikvzxmygjhpxrqiiyzqe'
const PAT = process.env.SUPABASE_PAT

if (!PAT) {
  console.error('Set SUPABASE_PAT (a personal access token from supabase.com/dashboard/account/tokens).')
  process.exit(2)
}

let query
if (process.argv[2] === '--file') {
  query = fs.readFileSync(process.argv[3], 'utf8')
} else if (process.argv[2]) {
  query = process.argv.slice(2).join(' ')
} else {
  query = fs.readFileSync(0, 'utf8')
}

const res = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query }),
})

const text = await res.text()
if (!res.ok) {
  console.error(`HTTP ${res.status}`)
  console.error(text)
  // A code, not process.exit(): exiting while the response is still winding down aborts on Windows with a libuv
  // assertion, which then prints after the real error and reads as a second, worse failure.
  process.exitCode = 1
} else {
  // The endpoint answers with an array of rows for anything that returns rows, and [] otherwise.
  let rows
  try {
    rows = JSON.parse(text)
  } catch {
    console.log(text)
    rows = undefined
  }
  if (rows !== undefined) {
    if (Array.isArray(rows) && rows.length) console.log(JSON.stringify(rows, null, 2))
    else if (!Array.isArray(rows)) console.log(JSON.stringify(rows, null, 2))
    else console.log('ok (no rows)')
  }
}
