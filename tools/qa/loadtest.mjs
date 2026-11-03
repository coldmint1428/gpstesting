// Stress test, part 2: the night itself. 1,000 phones on the NDP NE4 plan, doing what the app does.
//
//   node tools/qa/loadtest.mjs            (after tools/qa/loadtest-seed.mjs)
//   DURATION_S=720 RAMP_S=180 MAP_SHARE=0.08 node tools/qa/loadtest.mjs
//
// Every virtual person is one supabase-js client with its own sign-in and its own realtime socket, and makes the
// calls the Vue app makes, at the app's own intervals (read from the source, not guessed):
//
//   everyone   on open: the event, its groups, roles and members, my_event_membership, the open session; then the
//              four realtime channels the event page holds (members+roles, sessions, plans, broadcasts) and the
//              schedule's refresh every 30 s: session_timetable + plan_log_list(6) (PlanSchedule / usePlanWalk).
//              A "timetable changed" push makes them read again at once, like the page does.
//   ICs (92)   start_tracking_pass, then a reading every 5 s to /rpc/report_location with the pass -- exactly the
//              request the phone's background tracker sends -- walking their group's planned route from the show
//              matrix, with GPS noise (sigma 6 m), accuracy 5-25 m, and one reading in fifty thrown 150 m off.
//   map (8%)   members who open the Map tab: latest_locations, and the locations INSERT channel.
//   staff (2)  root, planner: plan_ops every 5 s (PlanOps POLL_MS), plan_log_list, the locations channel.
//
// People arrive over RAMP_S (the gates open), and the planners push back mid-show, the way NDP does:
//   +360 s  "the whole event slips": frame_shift +5 min from now, publish        -> every phone re-reads
//   +450 s  plan_broadcast to everyone; 70% of people tap Got it within a minute   -> an ack storm
//   +560 s  one contingent held 3 min (frame_hold), publish                        -> only that group changes
// Everything is timed and written to .tmp/loadtest/result-<time>.json.
//
// Settings for the stress tests (docs/stress-testing/STRESS-TEST-PLAN.md), each off unless set, so a plain run is
// exactly the run above. `npm run stress` (tools/qa/stress.mjs) sets them:
//   END_AT_FINISH=1        end the event when the run stops: at the end, on Ctrl+C (results are still written), on a
//                          crash, or when the window is closed. Without it the session stays live after the run.
//   REPUBLISH_EVERY_S=240  ST12: every N s push the rest of the night +30 s and publish, and count how many phones
//                          heard each publish within 30 s.
//   REFRESH_TOKENS=1       renew every sign-in before it expires (they last an hour): for runs longer than that.
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'

const DURATION_S = Number(process.env.DURATION_S || 720)
const RAMP_S = Number(process.env.RAMP_S || 180)
const MAP_SHARE = Number(process.env.MAP_SHARE || 0.08)
const LIMIT = Number(process.env.USERS || 1000)
const END_AT_FINISH = process.env.END_AT_FINISH === '1'
const REPUBLISH_EVERY_S = Number(process.env.REPUBLISH_EVERY_S || 0)
const REFRESH_TOKENS = process.env.REFRESH_TOKENS === '1'
const seed = JSON.parse(fs.readFileSync('.tmp/loadtest/seed.json', 'utf8'))
if (process.env.PLAN_ID) seed.planId = process.env.PLAN_ID // the same event on another of its plans (the root-cause run)
const sessions = JSON.parse(fs.readFileSync('.tmp/loadtest/sessions.json', 'utf8'))
const plan = JSON.parse(fs.readFileSync('.tmp/ndp/plan.json', 'utf8'))
const people = seed.people.slice(0, LIMIT)
const ev = seed.eventId

// ---------- metrics ----------
const ops = new Map() // name -> { ms: [], errors: Map }
const t0 = Date.now()
const timeline = [] // every 10 s: { s, active, calls, errors }
let calls = 0
let errorsTotal = 0
const rt = { joined: 0, failed: 0, closed: 0, messages: {}, delays: {} }
function record(name, ms, error) {
  if (!ops.has(name)) ops.set(name, { ms: [], errors: new Map() })
  const o = ops.get(name)
  calls++
  if (error) {
    errorsTotal++
    const key = String(error.message || error).slice(0, 120)
    o.errors.set(key, (o.errors.get(key) || 0) + 1)
  } else o.ms.push(ms)
}
async function timed(name, fn) {
  const t = Date.now()
  try {
    const r = await fn()
    record(name, Date.now() - t, r && r.error)
    return r
  } catch (error) {
    record(name, Date.now() - t, error)
    return { error }
  }
}
const pct = (xs, p) => {
  if (!xs.length) return null
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]
}
const delay = (key, ms) => (rt.delays[key] ||= []).push(ms)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const jitter = (ms) => ms * (0.85 + Math.random() * 0.3)
const elapsed = () => (Date.now() - t0) / 1000
let stopping = false

// ---------- the plan as a walk: where is group g at plan time T ----------
const track = new Map() // group name -> [{t, lat, lng}]
for (const f of plan.frames) for (const [g, p] of Object.entries(f.positions)) (track.get(g) || track.set(g, []).get(g)).push({ t: f.t_s, lat: p.lat, lng: p.lng })
let planShift = 0 // seconds the planners have pushed the plan by; the walkers follow the plan they were given
function where(g, T) {
  const pts = track.get(g)
  if (!pts || !pts.length) return null
  if (T <= pts[0].t) return pts[0]
  for (let i = 1; i < pts.length; i++) {
    if (pts[i].t >= T) {
      const a = pts[i - 1]
      const b = pts[i]
      const f = (T - a.t) / (b.t - a.t || 1)
      return { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f }
    }
  }
  return pts[pts.length - 1]
}
const gauss = () => Math.sqrt(-2 * Math.log(Math.random() || 1e-9)) * Math.cos(2 * Math.PI * Math.random())
function noisy(p, sigma) {
  return { lat: p.lat + (gauss() * sigma) / 110574, lng: p.lng + (gauss() * sigma) / (111320 * Math.cos((p.lat * Math.PI) / 180)) }
}

// ---------- staff: root starts the event with T+0 = now ----------
// The QA staff sessions cached by the E2E suite, as tokens (no auth module: nothing on this laptop refreshes mid-run)
const staffCache = JSON.parse(fs.readFileSync('.tmp/e2e-sessions.json', 'utf8'))
// The token is read at each call, so REFRESH_TOKENS can renew it under a running client
const tokenClient = (sess) => createClient(SUPABASE_URL, ANON_KEY, { accessToken: async () => sess.access_token })
const root = tokenClient(staffCache.root)
const sgNow = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date())
const part = (t) => sgNow.find((x) => x.type === t).value
const planRow = (await root.from('plans').select('id, name, rev').eq('id', seed.planId).single()).data
await root.rpc('end_event', { p_event_id: ev }) // a previous run's session, if any
let r = await root.rpc('plan_save', { p_event: ev, p_plan: { id: planRow.id, name: planRow.name, rev: planRow.rev, for_date: `${part('year')}-${part('month')}-${part('day')}`, t0_time: `${part('hour')}:${part('minute')}:00` } })
if (r.error) throw new Error('plan_save t0: ' + r.error.message)
r = await timed('start_event', () => root.rpc('start_event', { p_event_id: ev, p_plan: seed.planId }))
if (r.error) throw new Error('start_event: ' + r.error.message)
const session = (await root.from('event_sessions').select('id, t0_at').eq('event_id', ev).is('ended_at', null).single()).data
const T0 = new Date(session.t0_at).getTime()
const planT = () => (Date.now() - T0) / 1000
console.log(`session ${session.id}; T+0 ${session.t0_at}; ${people.length} people, ${people.filter((p) => p.isIC).length} ICs; ${DURATION_S} s, ramp ${RAMP_S} s`)

// Shared clock for "the planner published at": phones measure how long the news took to reach them
const announced = { plans: null }

// ---------- END_AT_FINISH: never leave the session live ----------
// A session left live keeps the 5 s and 30 s plan jobs working on it, and a crash used to leave it that way.
let ended = false
async function endEvent(why) {
  if (!END_AT_FINISH || ended) return
  ended = true
  const r = await root.rpc('end_event', { p_event_id: ev })
  console.log(r.error ? `COULD NOT END THE EVENT (${why}): ${r.error.message}. End it on the website now.` : `event ended (${why})`)
}
let finishEarly = () => {}
if (END_AT_FINISH) {
  let presses = 0
  const stop = async (why) => {
    // First Ctrl+C: stop early but still write the results. A second one, or the window closing: end and leave.
    if (why === 'SIGINT' && ++presses === 1) {
      console.log('\nStopping early: the results are still written, and the event is ended. Ctrl+C again to leave at once.')
      return finishEarly()
    }
    stopping = true
    await endEvent(why)
    process.exit(1)
  }
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => stop(sig))
  for (const kind of ['uncaughtException', 'unhandledRejection']) {
    process.on(kind, (e) => {
      console.error(e)
      stop('crash')
    })
  }
}

// ---------- one virtual person ----------
async function person(p, index) {
  await sleep((index / people.length) * RAMP_S * 1000 * (0.7 + Math.random() * 0.6))
  if (stopping) return
  const s = sessions[p.id]
  // The sign-in is handed to the client as a token (supabase-js accessToken): a phone already holds its session, and
  // a thousand auth modules on one laptop would only queue behind each other's session lock (the first run did).
  const sb = createClient(SUPABASE_URL, ANON_KEY, { accessToken: async () => s.access_token })
  active++
  const gid = seed.groups[p.group]

  // Opening the event: the reads useEventData + memberService make
  await Promise.all([
    timed('events.select', () => sb.from('events').select('id, name, join_code, is_simulation, description, venue, starts_at, ends_at').eq('id', ev).maybeSingle()),
    timed('groups.select', () => sb.from('groups').select('id, name, colour, code, category, sector, headcount, radio').eq('event_id', ev).order('created_at')),
    timed('event_roles.select', () => sb.from('event_roles').select('user_id, role, sector, profiles (username, display_name)').eq('event_id', ev)),
    timed('group_members.select', () => sb.from('group_members').select('group_id, user_id, is_admin, is_ic, ic_tolerance_m').eq('event_id', ev)),
    timed('my_event_membership', () => sb.rpc('my_event_membership', { p_event_id: ev })),
    timed('event_sessions.select', () => sb.from('event_sessions').select('*').eq('event_id', ev).order('starts_at', { ascending: false }).limit(5)),
  ])

  const acked = new Set()
  let reading = false
  async function refresh(reason) {
    if (reading || stopping) return
    reading = true
    const [, log] = await Promise.all([
      timed('session_timetable', () => sb.rpc('session_timetable', { p_session: session.id })),
      timed('plan_log_list', () => sb.rpc('plan_log_list', { p_plan: seed.planId, p_limit: 6 })),
    ])
    reading = false
    // 70% of people tap "Got it" on a message they have not acked, 5-60 s after they see it
    for (const row of (log && log.data) || []) {
      if (acked.has(row.id) || row.i_acked || !row.i_recipient || Math.random() > 0.7) continue
      acked.add(row.id)
      setTimeout(() => !stopping && timed('plan_log_ack', () => sb.rpc('plan_log_ack', { p_log: row.id })), 5000 + Math.random() * 55000)
    }
    if (reason === 'push' && announced.plans) delay('timetable re-read after a publish', Date.now() - announced.plans)
  }

  // The four channels the event page holds (names and filters as in the composables)
  const tag = Math.random().toString(36).slice(2)
  const seen = (table) => (payload) => {
    rt.messages[table] = (rt.messages[table] || 0) + 1
    if (table === 'plans') for (const e of publishes) if (!e.reached.has(p.id) && Date.now() - e.at < 120000) e.reached.set(p.id, Date.now() - e.at)
    if (table === 'plans' && announced.plans) {
      delay('plans UPDATE reached a phone', Date.now() - announced.plans)
      refresh('push')
    }
    if (table === 'locations' && payload.new && payload.new.recorded_at) delay('location reached a map', Date.now() - new Date(payload.new.recorded_at).getTime())
  }
  const channels = [
    sb.channel(`event-members-${ev}-${tag}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'group_members', filter: 'event_id=eq.' + ev }, seen('group_members'))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'event_roles', filter: 'event_id=eq.' + ev }, seen('event_roles')),
    sb.channel(`event-sessions-${ev}-${tag}`).on('postgres_changes', { event: '*', schema: 'public', table: 'event_sessions', filter: 'event_id=eq.' + ev }, seen('event_sessions')),
    sb.channel(`event-plans-${ev}-${tag}`).on('postgres_changes', { event: '*', schema: 'public', table: 'plans', filter: 'event_id=eq.' + ev }, seen('plans')),
    sb.channel(`broadcasts-${ev}-${tag}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'broadcasts', filter: 'event_id=eq.' + ev }, seen('broadcasts'))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'broadcast_recipients', filter: 'user_id=eq.' + p.id }, seen('broadcast_recipients')),
  ]
  const mapViewer = p.staff || (!p.isIC && Math.random() < MAP_SHARE)
  if (mapViewer) {
    await timed('latest_locations', () => sb.rpc('latest_locations', { p_event_id: ev }))
    channels.push(sb.channel(`event-locations-${ev}-${tag}`).on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'locations', filter: 'event_id=eq.' + ev }, seen('locations')))
  }
  for (const ch of channels) {
    const t = Date.now()
    ch.subscribe((status) => {
      if (status === 'SUBSCRIBED') {
        rt.joined++
        delay('realtime channel join', Date.now() - t)
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        rt.failed++
        rt.failures = rt.failures || {}
        rt.failures[status] = (rt.failures[status] || 0) + 1
      } else if (status === 'CLOSED') rt.closed++
    })
  }

  await refresh('open')
  const loops = []
  // The schedule's 30-second floor
  loops.push((async () => {
    while (!stopping) {
      await sleep(jitter(30000))
      await refresh('poll')
    }
  })())

  // An IC's phone: a pass, then a reading every 5 s along the group's walk
  if (p.isIC) {
    loops.push((async () => {
      const pass = await timed('start_tracking_pass', () => sb.rpc('start_tracking_pass', { p_event_id: ev, p_group_id: gid }))
      const token = pass.data && (pass.data.token || pass.data)
      if (!token) return
      while (!stopping) {
        const here = where(p.group, planT() - planShift)
        if (here) {
          const off = Math.random() < 0.02 ? 150 : 6
          const pos = noisy(here, off)
          await timed('report_location', () =>
            fetch(SUPABASE_URL + '/rest/v1/rpc/report_location', {
              method: 'POST',
              headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
              body: JSON.stringify({ p_token: token, p_lat: pos.lat, p_lng: pos.lng, p_accuracy: 5 + Math.random() * 20, p_recorded_at: new Date().toISOString() }),
            }).then(async (res) => (res.ok ? {} : { error: new Error(res.status + ' ' + (await res.text()).slice(0, 100)) })),
          )
        }
        await sleep(jitter(5000))
      }
    })())
  }

  // Staff: the ops board's 5-second read
  if (p.staff) {
    loops.push((async () => {
      while (!stopping) {
        await Promise.all([
          timed('plan_ops', () => sb.rpc('plan_ops', { p_session: session.id })),
          timed('plan_log_list (ops)', () => sb.rpc('plan_log_list', { p_plan: seed.planId, p_limit: 20 })),
        ])
        await sleep(jitter(5000))
      }
    })())
  }

  await Promise.all(loops)
  for (const ch of channels) await sb.removeChannel(ch).catch(() => {})
  active--
}

// ---------- the planners' pushbacks ----------
async function planners() {
  const at = async (s, label, fn) => {
    while (elapsed() < s && !stopping) await sleep(500)
    if (stopping) return
    const t = Date.now()
    const out = await onePlanChange(fn)
    console.log(`[${elapsed().toFixed(0)} s] ${label}: ${out && out.error ? 'ERROR ' + out.error.message : 'ok'} (${Date.now() - t} ms)`)
  }
  const publish = async () => {
    const rev = (await root.from('plans').select('rev').eq('id', seed.planId).single()).data.rev
    announced.plans = Date.now()
    return timed('plan_publish (under load)', () => root.rpc('plan_publish', { p_plan: seed.planId, p_plan_rev: rev }))
  }
  await at(Math.round(DURATION_S * 0.55), 'push the rest of the night +5 min and publish', async () => {
    const from = Math.ceil(planT() / 5) * 5 + 60
    const shift = await timed('frame_shift (under load)', () => root.rpc('frame_shift', { p_plan: seed.planId, p_from_s: from, p_delta_s: 300, p_to_s: null }))
    if (shift.error) return shift
    planShift = 0 // the walkers keep their pace; the plan they are measured against moved (they show late, then catch up)
    return publish()
  })
  await at(Math.round(DURATION_S * 0.7), 'message everyone and wait for the acks', () =>
    timed('plan_broadcast (under load)', () => root.rpc('plan_broadcast', { p_plan: seed.planId, p_body: 'NDP: gates delayed 5 min - hold at your sector', p_audience: 'all', p_group: null })),
  )
  await at(Math.round(DURATION_S * 0.85), 'hold P&C Contingent 3 for 3 min and publish', async () => {
    const T = Math.ceil(planT() / 5) * 5
    const frames = (await root.rpc('plan_frames_list', { p_plan: seed.planId })).data || []
    const next = frames.find((f) => f.t_s > T && f.positions && f.positions[seed.groups['P&C Contingent 3']])
    if (!next) return { error: new Error('no later frame for the contingent') }
    const held = await timed('frame_hold (under load)', () => root.rpc('frame_hold', { p_plan: seed.planId, p_frame: next.id, p_seconds: 180, p_groups: [seed.groups['P&C Contingent 3']] }))
    if (held.error) return held
    return publish()
  })
}

// One plan change at a time: a publish names the revision it read, so two at once would refuse each other
let planQueue = Promise.resolve()
function onePlanChange(fn) {
  const next = planQueue.then(fn, fn)
  planQueue = next.catch(() => {})
  return next
}

// ---------- REPUBLISH_EVERY_S (ST12): many publishes during the night ----------
const publishes = [] // { n, at, active, error, reached: Map(person id -> ms) }
async function republishes() {
  if (!REPUBLISH_EVERY_S) return
  for (let n = 1; ; n++) {
    while (elapsed() < n * REPUBLISH_EVERY_S && !stopping) await sleep(500)
    if (stopping) return
    const out = await onePlanChange(async () => {
      const from = Math.ceil(planT() / 5) * 5 + 60
      const shift = await timed('frame_shift (republish)', () => root.rpc('frame_shift', { p_plan: seed.planId, p_from_s: from, p_delta_s: 30, p_to_s: null }))
      if (shift.error) return shift
      const rev = (await root.from('plans').select('rev').eq('id', seed.planId).single()).data.rev
      const entry = { n, at: Date.now(), active, error: null, reached: new Map() }
      publishes.push(entry)
      announced.plans = entry.at
      const pub = await timed('plan_publish (republish)', () => root.rpc('plan_publish', { p_plan: seed.planId, p_plan_rev: rev }))
      if (pub.error) entry.error = pub.error.message
      return pub
    }).catch((error) => ({ error }))
    console.log(`[${elapsed().toFixed(0)} s] republish ${n} (+30 s): ${out && out.error ? 'ERROR ' + (out.error.message || out.error) : 'ok'}`)
  }
}

// ---------- REFRESH_TOKENS: sign-ins last an hour ----------
async function refresher() {
  if (!REFRESH_TOKENS) return
  while (!stopping) {
    for (const s of new Set(Object.values(sessions))) {
      if (stopping) return
      if (!s.refresh_token || (s.expires_at && s.expires_at * 1000 - Date.now() > 15 * 60000)) continue
      await timed('token refresh', async () => {
        const res = await fetch(SUPABASE_URL + '/auth/v1/token?grant_type=refresh_token', {
          method: 'POST',
          headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
          body: JSON.stringify({ refresh_token: s.refresh_token }),
        })
        if (!res.ok) return { error: new Error(res.status + ' ' + (await res.text()).slice(0, 100)) }
        const j = await res.json()
        Object.assign(s, { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: j.expires_at })
        return {}
      })
      await sleep(300)
    }
    for (let i = 0; i < 60 && !stopping; i++) await sleep(1000)
  }
}

// ---------- run ----------
let active = 0
const staffIds = {}
for (const who of ['root', 'planner']) {
  const sess = staffCache[who]
  staffIds[who] = sess.user.id
  sessions[sess.user.id] = sess // the same object root's client reads its token from
}
const crowd = [
  ...Object.entries(staffIds).map(([who, id]) => ({ id, email: who, group: null, isIC: false, staff: true })),
  ...people,
]
const ticker = setInterval(() => {
  const last = timeline[timeline.length - 1] || { calls: 0, errors: 0 }
  timeline.push({ s: Math.round(elapsed()), active, calls, errors: errorsTotal, rtJoined: rt.joined, rtFailed: rt.failed })
  if (timeline.length % 3 === 0) {
    const rl = ops.get('report_location')
    const st = ops.get('session_timetable')
    console.log(`[${Math.round(elapsed())} s] active ${active}, ${((calls - last.calls) / 10).toFixed(1)} req/s, errors ${errorsTotal}, rt joined ${rt.joined} failed ${rt.failed}; report_location p95 ${rl ? pct(rl.ms.slice(-500), 95) : '-'} ms; session_timetable p95 ${st ? pct(st.ms.slice(-500), 95) : '-'} ms`)
  }
}, 10000)
const all = Promise.all(crowd.map((p, i) => person(p, p.staff ? 0 : i).catch((e) => record('person crashed', 0, e))))
const scripted = Promise.all([planners(), republishes(), refresher()]).catch((e) => record('planner script crashed', 0, e))
await new Promise((resolve) => {
  finishEarly = resolve
  setTimeout(resolve, DURATION_S * 1000)
})
stopping = true
clearInterval(ticker)
await Promise.race([Promise.all([all, scripted]), sleep(20000)])

// ---------- what the database saw ----------
const { count: readings } = await root.from('locations').select('user_id', { count: 'exact', head: true }).eq('event_id', ev)
const acks = (await root.rpc('plan_log_list', { p_plan: seed.planId, p_limit: 20 })).data || []
const result = {
  at: new Date().toISOString(),
  startedAt: new Date(t0).toISOString(),
  eventId: ev,
  config: { DURATION_S, RAMP_S, MAP_SHARE, people: people.length, ICs: people.filter((p) => p.isIC).length },
  session: session.id,
  totals: { calls, errors: errorsTotal, readingsStored: readings },
  ops: Object.fromEntries(
    [...ops].map(([k, o]) => [k, { n: o.ms.length, errors: o.ms.length + [...o.errors.values()].reduce((a, b) => a + b, 0) - o.ms.length, p50: pct(o.ms, 50), p95: pct(o.ms, 95), p99: pct(o.ms, 99), max: o.ms.length ? Math.max(...o.ms) : null, errorKinds: Object.fromEntries(o.errors) }]),
  ),
  realtime: {
    joined: rt.joined,
    failed: rt.failed,
    failures: rt.failures || {},
    messages: rt.messages,
    delays: Object.fromEntries(Object.entries(rt.delays).map(([k, xs]) => [k, { n: xs.length, p50: pct(xs, 50), p95: pct(xs, 95), p99: pct(xs, 99), max: Math.max(...xs) }])),
  },
  acks: acks.map((r) => ({ kind: r.kind, body: (r.body || '').slice(0, 60), recipients: r.recipients, acked: r.acked })),
  timeline,
  stress: {
    endAtFinish: END_AT_FINISH,
    republishes: publishes.map((e) => {
      const ms = [...e.reached.values()]
      return { n: e.n, at: new Date(e.at).toISOString(), error: e.error, activeThen: e.active, reached: ms.length, within30s: ms.filter((x) => x <= 30000).length, p95: pct(ms, 95), max: ms.length ? Math.max(...ms) : null }
    }),
  },
}
// Renewed sign-ins replace the stored ones (the old refresh tokens are spent)
if (REFRESH_TOKENS) {
  fs.writeFileSync('.tmp/loadtest/sessions.json', JSON.stringify(sessions))
  fs.writeFileSync('.tmp/e2e-sessions.json', JSON.stringify(staffCache))
}
const file = `.tmp/loadtest/result-${Date.now()}.json`
fs.writeFileSync(file, JSON.stringify(result, null, 1))
console.log(JSON.stringify({ totals: result.totals, realtime: { joined: rt.joined, failed: rt.failed, failures: rt.failures }, ops: Object.fromEntries(Object.entries(result.ops).map(([k, o]) => [k, `${o.n} ok, ${o.errors} err, p50 ${o.p50} p95 ${o.p95} p99 ${o.p99}`])), delays: result.realtime.delays }, null, 1))
console.log('wrote', file)
await endEvent('finished')
process.exit(0)
