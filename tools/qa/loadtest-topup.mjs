// Stress test, part 1b: sign in and join whoever the seed could not (the auth server throttles one address).
//   node tools/qa/loadtest-topup.mjs
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { clientFor, SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'

const seed = JSON.parse(fs.readFileSync('.tmp/loadtest/seed.json', 'utf8'))
const sessions = JSON.parse(fs.readFileSync('.tmp/loadtest/sessions.json', 'utf8'))
const plan = JSON.parse(fs.readFileSync('.tmp/ndp/plan.json', 'utf8'))
const PASSWORD = JSON.parse(fs.readFileSync('.tmp/qa-accounts.json', 'utf8')).password
const { sb: root } = await clientFor('root')
const have = new Set(seed.people.map((p) => p.email))
const missing = Array.from({ length: 1000 }, (_, i) => `loadtest-${String(i + 1).padStart(4, '0')}@planova.test`).filter((e) => !have.has(e))
console.log('missing', missing.length)
// Fill the groups that are furthest under their share of the 1,000
const total = plan.groups.reduce((s, g) => s + g.headcount, 0)
const count = (g) => seed.people.filter((p) => p.group === g).length
const nextGroup = () => plan.groups.map((g) => ({ g: g.name, gap: (g.headcount / total) * 1000 - count(g.name) })).sort((a, b) => b.gap - a.gap)[0].g
let retries = 0
let ok = 0
for (const email of missing) {
  const sb = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  let data, error
  for (let attempt = 0; attempt < 30; attempt++) {
    ;({ data, error } = await sb.auth.signInWithPassword({ email, password: PASSWORD }))
    if (!error || error.status !== 429) break
    retries++
    await new Promise((r) => setTimeout(r, 1500))
  }
  if (error) {
    console.log(email, error.message)
    continue
  }
  const j = await sb.rpc('join_event', { p_code: seed.joinCode })
  if (j.error) console.log(email, 'join', j.error.message)
  const group = nextGroup()
  const a = await root.rpc('add_event_member', { p_event_id: seed.eventId, p_user_id: data.user.id, p_group_id: seed.groups[group] })
  if (a.error) console.log(email, 'assign', a.error.message)
  seed.people.push({ email, id: data.user.id, group, isIC: false })
  sessions[data.user.id] = { access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_at: data.session.expires_at }
  ok++
  if (ok % 25 === 0) {
    console.log(`${ok} joined (${retries} waits on 429)`)
    fs.writeFileSync('.tmp/loadtest/seed.json', JSON.stringify(seed, null, 1))
    fs.writeFileSync('.tmp/loadtest/sessions.json', JSON.stringify(sessions))
  }
}
seed.topup = { joined: ok, waits429: retries }
fs.writeFileSync('.tmp/loadtest/seed.json', JSON.stringify(seed, null, 1))
fs.writeFileSync('.tmp/loadtest/sessions.json', JSON.stringify(sessions))
console.log('topped up', ok, 'people; total', seed.people.length, '; waits on 429:', retries)
