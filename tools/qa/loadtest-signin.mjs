// Stress test helper: fresh sign-ins for the first N load-test people (tokens last an hour), and the QA staff.
//   USERS=300 node tools/qa/loadtest-signin.mjs
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { sessionFor, SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'

const N = Number(process.env.USERS || 300)
const seed = JSON.parse(fs.readFileSync('.tmp/loadtest/seed.json', 'utf8'))
const sessions = JSON.parse(fs.readFileSync('.tmp/loadtest/sessions.json', 'utf8'))
const PASSWORD = JSON.parse(fs.readFileSync('.tmp/qa-accounts.json', 'utf8')).password
for (const who of ['root', 'planner', 'marshal']) await sessionFor(who) // refreshes the cached staff sessions
let waits = 0
let n = 0
for (const p of seed.people.slice(0, N)) {
  const sb = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  let data, error
  for (let attempt = 0; attempt < 40; attempt++) {
    ;({ data, error } = await sb.auth.signInWithPassword({ email: p.email, password: PASSWORD }))
    if (!error || error.status !== 429) break
    waits++
    await new Promise((r) => setTimeout(r, 1500))
  }
  if (error) {
    console.log(p.email, error.message)
    continue
  }
  sessions[p.id] = { access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_at: data.session.expires_at }
  if (++n % 50 === 0) console.log(n, 'signed in')
}
fs.writeFileSync('.tmp/loadtest/sessions.json', JSON.stringify(sessions))
console.log(`signed in ${n}/${N}; waited on 429 ${waits} times`)
