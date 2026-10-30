// Stress test, part 1: the NDP night as a real event, set up the way people would set it up.
//
//   node tools/qa/loadtest-seed.mjs            (after tools/qa/ndp-plan.mjs has written .tmp/ndp/plan.json)
//
// qa_root makes the event with the 46 groups (create_event_with_setup, the wizard's call), imports the 1,135-moment
// plan (plan_import) and publishes it. Then the 1,000 load-test accounts (loadtest-0001..1000@planova.test, made by the
// QA setup) sign in and join with the event code, the way a person does from the homepage -- a join storm, timed. Root
// puts each one in their group (add_event_member) and makes the first two of every group its ICs (set_group_ic).
// Writes .tmp/loadtest/seed.json (event, plan, groups, who is where) and sessions.json (their sign-ins, for part 2).
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { clientFor, SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'

const OUT = '.tmp/loadtest'
fs.mkdirSync(OUT, { recursive: true })
const N = Number(process.env.USERS || 1000)
const PASSWORD = JSON.parse(fs.readFileSync('.tmp/qa-accounts.json', 'utf8')).password
const plan = JSON.parse(fs.readFileSync('.tmp/ndp/plan.json', 'utf8'))
const must = (r, what) => {
  if (r.error) throw new Error(`${what}: ${r.error.message}`)
  return r.data
}
const timings = {}
const stopwatch = (name) => {
  const t = Date.now()
  return () => (timings[name] = Date.now() - t)
}
async function pool(items, size, fn) {
  const out = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: size }, async () => {
      while (next < items.length) {
        const i = next++
        out[i] = await fn(items[i], i)
      }
    }),
  )
  return out
}
const pct = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b)
  return s.length ? s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] : null
}

const { sb: root } = await clientFor('root')
const planner = (await clientFor('planner')).user.id
const marshal = (await clientFor('marshal')).user.id

// ---------- the event and its groups ----------
let done = stopwatch('create_event_ms')
const start = new Date()
const eventId = must(
  await root.rpc('create_event_with_setup', {
    p_event: {
      name: 'QA-LOADTEST NDP 2025 NE4',
      venue: 'The Padang, Singapore',
      description: 'Stress test: 1,000 people on the NE4 show matrix. Made by the QA suite and deleted after the run.',
      starts_at: start.toISOString(),
      ends_at: new Date(start.getTime() + 6 * 3600_000).toISOString(),
    },
    p_members: [
      { user_id: planner, role: 'planner' },
      { user_id: marshal, role: 'marshal' },
    ],
    p_groups: plan.groups.map((g) => ({ name: g.name, colour: g.colour, members: [] })),
  }),
  'create event',
)
done()
const event = must(await root.from('events').select('id, join_code').eq('id', eventId).single(), 'event')
const groupRows = must(await root.from('groups').select('id, name').eq('event_id', eventId), 'groups')
const groupId = Object.fromEntries(groupRows.map((g) => [g.name, g.id]))
console.log('event', eventId, 'code', event.join_code, groupRows.length, 'groups', timings.create_event_ms, 'ms')

// ---------- the plan: 1,135 moments, imported in one call, then published ----------
const sg = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
const planRow = must(await root.rpc('plan_save', { p_event: eventId, p_plan: { name: 'NDP 2025 NE4 (show matrix 17 Jul)', for_date: sg, t0_time: '16:00:00' } }), 'plan')
const frames = plan.frames.map((f) => ({
  t_s: f.t_s,
  note: f.note,
  positions: Object.fromEntries(Object.entries(f.positions).map(([name, p]) => [groupId[name], p])),
}))
done = stopwatch('plan_import_ms')
must(await root.rpc('plan_import', { p_plan: planRow.id, p_frames: frames }), 'plan_import')
done()
const rev = must(await root.from('plans').select('rev').eq('id', planRow.id).single(), 'rev').rev
done = stopwatch('plan_publish_ms')
const published = await root.rpc('plan_publish', { p_plan: planRow.id, p_plan_rev: rev })
done()
console.log('plan', planRow.id, frames.length, 'frames: import', timings.plan_import_ms, 'ms, publish', timings.plan_publish_ms, 'ms', published.error ? 'PUBLISH ERROR ' + published.error.message : 'ok')

// ---------- 1,000 people sign in and join with the code ----------
const emails = Array.from({ length: N }, (_, i) => `loadtest-${String(i + 1).padStart(4, '0')}@planova.test`)
const signInMs = []
const joinMs = []
const failures = []
done = stopwatch('join_storm_ms')
// Auth allows a burst of about 30 sign-ins from one address, then the configured rate (raised to 1,200 per 5 min, so
// 4 a second, for the test). Real phones sign in from their own addresses, days before; one laptop playing 1,000 of
// them has to queue, so sign-ins leave at 3.3 a second and a 429 waits and tries again (counted).
let nextSlot = Date.now()
const slot = async () => {
  const at = Math.max(Date.now(), nextSlot)
  nextSlot = at + 300
  await new Promise((r) => setTimeout(r, at - Date.now()))
}
let retries429 = 0
const people = await pool(emails, 25, async (email) => {
  const sb = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  let t, data, error
  for (let attempt = 0; attempt < 8; attempt++) {
    await slot()
    t = Date.now()
    ;({ data, error } = await sb.auth.signInWithPassword({ email, password: PASSWORD }))
    if (!error || error.status !== 429) break
    retries429++
    await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)))
  }
  signInMs.push(Date.now() - t)
  if (error) {
    failures.push({ email, step: 'sign-in', message: error.message })
    return null
  }
  t = Date.now()
  const joined = await sb.rpc('join_event', { p_code: event.join_code })
  joinMs.push(Date.now() - t)
  if (joined.error) failures.push({ email, step: 'join', message: joined.error.message })
  return { email, id: data.user.id, access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_at: data.session.expires_at }
})
done()
const joined = people.filter(Boolean)
console.log(`join storm: ${joined.length}/${N} in ${timings.join_storm_ms} ms; sign-in p50 ${pct(signInMs, 50)} p95 ${pct(signInMs, 95)} ms; join p50 ${pct(joinMs, 50)} p95 ${pct(joinMs, 95)} ms; failures ${failures.length}, 429 retries ${retries429}`)

// ---------- root puts everyone in their group; two ICs per group ----------
const total = plan.groups.reduce((s, g) => s + g.headcount, 0)
const seats = []
plan.groups.forEach((g) => {
  const n = Math.max(3, Math.round((g.headcount / total) * joined.length))
  for (let k = 0; k < n; k++) seats.push(g.name)
})
const assignment = joined.map((p, i) => ({ ...p, group: seats[i % seats.length] }))
const assignMs = []
done = stopwatch('assign_ms')
await pool(assignment, 10, async (p) => {
  const t = Date.now()
  const r = await root.rpc('add_event_member', { p_event_id: eventId, p_user_id: p.id, p_group_id: groupId[p.group] })
  assignMs.push(Date.now() - t)
  if (r.error) failures.push({ email: p.email, step: 'assign', message: r.error.message })
})
done()
const ics = new Set()
for (const g of plan.groups) for (const p of assignment.filter((x) => x.group === g.name).slice(0, 2)) ics.add(p.id)
await pool([...ics], 10, async (id) => {
  const p = assignment.find((x) => x.id === id)
  const r = await root.rpc('set_group_ic', { p_group_id: groupId[p.group], p_user_id: id, p_is_ic: true })
  if (r.error) failures.push({ email: p.email, step: 'set IC', message: r.error.message })
})
for (const p of assignment) p.isIC = ics.has(p.id)
console.log(`assigned ${assignment.length} in ${timings.assign_ms} ms (p95 ${pct(assignMs, 95)} ms), ${ics.size} ICs`)

const seed = {
  eventId,
  joinCode: event.join_code,
  planId: planRow.id,
  groups: groupId,
  timings,
  signIn: { p50: pct(signInMs, 50), p95: pct(signInMs, 95), p99: pct(signInMs, 99), max: Math.max(...signInMs) },
  join: { p50: pct(joinMs, 50), p95: pct(joinMs, 95), p99: pct(joinMs, 99), max: Math.max(...joinMs) },
  assign: { p50: pct(assignMs, 50), p95: pct(assignMs, 95) },
  retries429,
  failures,
  people: assignment.map(({ email, id, group, isIC }) => ({ email, id, group, isIC })),
}
fs.writeFileSync(`${OUT}/seed.json`, JSON.stringify(seed, null, 1))
fs.writeFileSync(`${OUT}/sessions.json`, JSON.stringify(Object.fromEntries(assignment.map((p) => [p.id, { access_token: p.access_token, refresh_token: p.refresh_token, expires_at: p.expires_at }]))))
console.log('failures by step', failures.reduce((m, f) => ((m[f.step + ': ' + f.message] = (m[f.step + ': ' + f.message] || 0) + 1), m), {}))
