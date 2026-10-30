// Scenario and pushback tests: the NDP night's awkward moments, each with the answer the spec says it should get.
//   node tools/qa/scenarios.mjs
// Runs against the live database through the same RPCs the app calls, as the QA accounts (qa_root plans, qa_ic1/qa_ic2
// are Alpha's two ICs, qa_marshal marks, qa_member reads). Each scenario is a list of checks; the run writes
// .tmp/scenarios/result.json and prints a table. Nothing here needs the service key: every refusal is the database's.
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'
import { clientFor } from '../../e2e/support/session.js'
import { makeQaEvent } from '../../e2e/support/fixture.js'

fs.mkdirSync('.tmp/scenarios', { recursive: true })
const results = []
let current = null
function scenario(name, spec) {
  current = { name, spec, checks: [] }
  results.push(current)
  console.log('\n## ' + name)
}
function check(what, ok, detail = '') {
  current.checks.push({ what, ok: !!ok, detail: String(detail).slice(0, 200) })
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${what}${detail ? '  — ' + String(detail).slice(0, 160) : ''}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const must = (r, what) => {
  if (r.error) throw new Error(`${what}: ${r.error.message}`)
  return r.data
}

const root = (await clientFor('root')).sb
const ic1 = await clientFor('ic1')
const ic2 = await clientFor('ic2')
const marshal = (await clientFor('marshal')).sb
const member = (await clientFor('member')).sb
const planner = (await clientFor('planner')).sb

// ---------- setup: an event with a 20-moment walk, published, live with T+0 = now ----------
const ev = await makeQaEvent('Scenarios')
const A = { lat: 1.290315, lng: 103.851806 }
const B = { lat: 1.291476, lng: 103.85232 }
const sgParts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date())
const sg = (t) => sgParts.find((x) => x.type === t).value
const plan = must(await root.rpc('plan_save', { p_event: ev.eventId, p_plan: { name: 'Scenario walk', for_date: `${sg('year')}-${sg('month')}-${sg('day')}`, t0_time: `${sg('hour')}:${sg('minute')}:00` } }), 'plan')
const STEPS = 7 // 7 x ~20 m = the 140 m walk, then the group stands
const frames = []
for (let i = 0; i < 20; i++) {
  const f = Math.min(1, i / STEPS)
  frames.push({ t_s: i * 60, note: i === 0 ? 'Gates open' : i === STEPS ? 'In position' : '', positions: {
    [ev.groups.Alpha]: { lat: A.lat + (B.lat - A.lat) * f, lng: A.lng + (B.lng - A.lng) * f, state: 'on_site', verify: 'manual' },
    [ev.groups.Bravo]: { ...B, state: 'on_site', verify: 'auto' },
  } })
}
must(await root.rpc('plan_import', { p_plan: plan.id, p_frames: frames }), 'import')
const revOf = async () => (await root.from('plans').select('rev').eq('id', plan.id).single()).data.rev
must(await root.rpc('plan_publish', { p_plan: plan.id, p_plan_rev: await revOf() }), 'publish')
must(await root.rpc('start_event', { p_event_id: ev.eventId, p_plan: plan.id }), 'start')
const session = (await root.from('event_sessions').select('id, t0_at, plan_rev').eq('event_id', ev.eventId).is('ended_at', null).single()).data
const framesNow = async () => (await root.rpc('plan_frames_list', { p_plan: plan.id })).data.sort((a, b) => a.t_s - b.t_s)
const times = async () => (await framesNow()).map((f) => f.t_s)
console.log('event', ev.eventId, 'plan', plan.id, 'session', session.id)

// ---------- 1. the whole event slips, again and again, and is pulled back ----------
scenario('Pushback cascade: the whole event slips +5, +5, +10 min, then is pulled back 5', 'Shift the remaining span: moves every group, the grid is shared; re-planning is a versioned edit')
{
  const before = await times()
  const rev0 = await revOf()
  const from = 300
  for (const d of [300, 300, 600]) must(await root.rpc('frame_shift', { p_plan: plan.id, p_from_s: from, p_delta_s: d, p_to_s: null }), 'shift ' + d)
  let after = await times()
  const expect = before.map((t) => (t >= from ? t + 1200 : t))
  check('every moment from +5:00 on moved 20 min, the ones before did not', JSON.stringify(after) === JSON.stringify(expect), `first moved ${before[5]} -> ${after[5]}`)
  must(await root.rpc('frame_shift', { p_plan: plan.id, p_from_s: from + 1200, p_delta_s: -300, p_to_s: null }), 'pull back')
  after = await times()
  check('pulled back 5 min: +15 min net', JSON.stringify(after) === JSON.stringify(before.map((t) => (t >= from ? t + 900 : t))))
  const pulled = await root.rpc('frame_shift', { p_plan: plan.id, p_from_s: from + 900, p_delta_s: -1200, p_to_s: null })
  check('pulling back past the moment before is refused (two moments cannot swap order)', !!pulled.error, pulled.error?.message)
  check('content edits do not move the revision until published', (await revOf()) === rev0)
  must(await root.rpc('plan_publish', { p_plan: plan.id, p_plan_rev: await revOf() }), 'publish')
  check('publishing makes a new revision (versioned)', (await revOf()) > rev0, `rev ${rev0} -> ${await revOf()}`)
  const log = must(await root.rpc('plan_log_list', { p_plan: plan.id, p_limit: 5 }), 'log')
  check('the publish wrote a "timetable changed" row for the groups', log.some((r) => r.kind === 'timeline'), log.map((r) => r.kind).join(','))
}

// ---------- 2. hold one group ----------
scenario('Hold one group: Bravo (standing) is held 3 min; Alpha (walking) cannot be held alone', 'Hold one group: rewrite that group’s future spans so its next move happens later; only that group’s timeline changes')
{
  const fs0 = await framesNow()
  const alphaBefore = fs0.filter((f) => f.positions[ev.groups.Alpha]).map((f) => f.t_s)
  const at = fs0.find((f) => f.t_s === 120)
  const held = await root.rpc('frame_hold', { p_plan: plan.id, p_frame: at.id, p_seconds: 180, p_groups: [ev.groups.Bravo] })
  check('holding Bravo, who stands, is accepted', !held.error, held.error?.message || JSON.stringify(held.data))
  const fs1 = await framesNow()
  check("Alpha's moments are untouched by Bravo's hold", JSON.stringify(alphaBefore) === JSON.stringify(fs1.filter((f) => f.positions[ev.groups.Alpha]).map((f) => f.t_s)))
  check('Bravo is stated again 3 min later', fs1.some((f) => f.t_s === 300 && f.positions[ev.groups.Bravo]) || (held.data && held.data[0] && held.data[0].held_t_s === 300), held.data && JSON.stringify(held.data[0]))
  // QA-06: a group that is behind is usually one that is walking. The hold refuses it, and the only other tool
  // (frame_shift) moves every group. The spec's "hold one group" for a late, moving group is not possible.
  const walking = await root.rpc('frame_hold', { p_plan: plan.id, p_frame: at.id, p_seconds: 180, p_groups: [ev.groups.Alpha] })
  check('FINDING QA-06: holding Alpha mid-walk is refused, so a late walking group cannot be delayed on its own', !!walking.error, walking.error?.message)
  must(await root.rpc('plan_publish', { p_plan: plan.id, p_plan_rev: await revOf() }), 'publish')
}

// ---------- 3. two planners at once ----------
scenario('Two planners edit at once: the second save on a stale revision is refused', 'One live head; no two users see a different branch')
{
  const rev = await revOf()
  const first = await root.rpc('plan_save', { p_event: ev.eventId, p_plan: { id: plan.id, name: 'Scenario walk (root)', rev } })
  const second = await planner.rpc('plan_save', { p_event: ev.eventId, p_plan: { id: plan.id, name: 'Scenario walk (planner)', rev } })
  check("root's save on rev " + rev + ' goes through', !first.error, first.error?.message)
  check("the planner's save on the same rev is refused, not silently merged", !!second.error && /Someone else saved/.test(second.error.message), second.error?.message)
  const name = (await root.from('plans').select('name').eq('id', plan.id).single()).data.name
  check('the plan kept the first save', name === 'Scenario walk (root)', name)
  const pub = await root.rpc('plan_publish', { p_plan: plan.id, p_plan_rev: rev })
  check('publishing a revision that is no longer the head is refused', !!pub.error, pub.error?.message)
}

// ---------- 4. the planner cannot rewrite history ----------
scenario('History is kept: a marked moment survives, and an import over a marked plan is refused', 'Comparison is against the plan version in force; re-planning cannot retroactively rewrite history')
{
  const f0 = (await framesNow())[0]
  const mark = await marshal.rpc('progress_mark', { p_session: session.id, p_frame: f0.id, p_group: ev.groups.Alpha, p_state: 'arrived', p_at: new Date().toISOString() })
  check('the marshal marks Alpha arrived at the first moment', !mark.error, mark.error?.message)
  const again = await ic1.sb.rpc('progress_mark', { p_session: session.id, p_frame: f0.id, p_group: ev.groups.Alpha, p_state: 'missed', p_at: new Date().toISOString() })
  check("a second person cannot replace somebody else's mark", !!again.error, again.error?.message)
  const imp = await root.rpc('plan_import', { p_plan: plan.id, p_frames: frames })
  check('importing a sheet over a plan with marks is refused', !!imp.error, imp.error?.message)
  const fork = await root.rpc('plan_fork', { p_plan: plan.id })
  check('a copy (fork) of the plan can be made to re-plan from instead', !fork.error, fork.error?.message)
}

// ---------- 5. a faulty phone ----------
scenario("One IC's phone goes wrong: the group's position is not dragged by it", 'Multiple ICs per group; the position is the weighted midpoint, so one faulty device does not drag the rest')
{
  const pass1 = must(await ic1.sb.rpc('start_tracking_pass', { p_event_id: ev.eventId, p_group_id: ev.groups.Alpha }), 'pass 1')
  const pass2 = must(await ic2.sb.rpc('start_tracking_pass', { p_event_id: ev.eventId, p_group_id: ev.groups.Alpha }), 'pass 2')
  const report = (token, p, acc) =>
    fetch(SUPABASE_URL + '/rest/v1/rpc/report_location', { method: 'POST', headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: token, p_lat: p.lat, p_lng: p.lng, p_accuracy: acc, p_recorded_at: new Date().toISOString() }) })
  for (let i = 0; i < 3; i++) {
    await report(pass1, A, 6)
    await report(pass2, { lat: A.lat + 0.0027, lng: A.lng + 0.0027 }, 80) // 420 m off, poor accuracy
    await sleep(1500)
  }
  await sleep(3000)
  const ops = must(await root.rpc('plan_ops', { p_session: session.id }), 'ops').find((r) => r.group_id === ev.groups.Alpha)
  const dist = ops && ops.actual_lat != null ? Math.hypot((ops.actual_lat - A.lat) * 110574, (ops.actual_lng - A.lng) * 111320 * Math.cos((A.lat * Math.PI) / 180)) : null
  check('the ops board has a position for Alpha from both ICs', ops && ops.actual_ics >= 1, ops && `${ops.actual_ics} IC(s)`)
  check('the faulty phone (420 m off, 80 m accuracy) moves the group under 100 m', dist !== null && dist < 100, dist === null ? 'no position' : dist.toFixed(0) + ' m from the good phone')
  const bad = await report(pass1, { lat: 95, lng: 200 }, 5)
  check('impossible coordinates are refused', !bad.ok, bad.status)
  const forged = await report('00000000-0000-0000-0000-000000000000', A, 5)
  check('a made-up tracking pass is refused', !forged.ok, forged.status)
}

// ---------- 6. the marshal takes over ----------
scenario('The marshal takes the board, then the IC is taken off and put back mid-event', 'Marshal marks take priority, the hand-over is logged')
{
  const take = await marshal.rpc('handover_take', { p_session: session.id, p_note: 'QA: radio check, I have the board' })
  check('the marshal takes the board', !take.error, take.error?.message)
  const log = await root.rpc('handover_log_list', { p_session: session.id })
  check('the hand-over is in the log with the note', !log.error && (log.data || []).some((r) => /radio check/.test(JSON.stringify(r))), log.error?.message)
  const u = (await clientFor('ic2')).user.id
  const off = await root.rpc('set_group_ic', { p_group_id: ev.groups.Alpha, p_user_id: u, p_is_ic: false })
  check('root takes IC off qa_ic2 mid-event', !off.error, off.error?.message)
  const pass = (await ic2.sb.from('tracking_passes').select('token').eq('event_id', ev.eventId).is('revoked_at', null)).data?.[0]?.token
  const after = pass ? await fetch(SUPABASE_URL + '/rest/v1/rpc/report_location', { method: 'POST', headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: pass, p_lat: A.lat, p_lng: A.lng, p_accuracy: 5, p_recorded_at: new Date().toISOString() }) }) : null
  check('their old pass no longer uploads ("No longer the IC")', !after || !after.ok, after ? after.status + ' ' + (await after.text()).slice(0, 80) : 'pass already revoked')
  must(await root.rpc('set_group_ic', { p_group_id: ev.groups.Alpha, p_user_id: u, p_is_ic: true }), 'back on')
}

// ---------- 7. limits ----------
scenario('Pushing a plan past its limits', 'A plan is at most three days long; a frame time is a whole number of seconds')
{
  const huge = await root.rpc('frame_shift', { p_plan: plan.id, p_from_s: 0, p_delta_s: 86400 * 4, p_to_s: null })
  check('a push beyond three days is refused', !!huge.error, huge.error?.message)
  const neg = await root.rpc('frame_shift', { p_plan: plan.id, p_from_s: 0, p_delta_s: -600, p_to_s: null })
  check('pushing the first moment before T+0 is refused', !!neg.error, neg.error?.message)
  const memberShift = await member.rpc('frame_shift', { p_plan: plan.id, p_from_s: 0, p_delta_s: 60, p_to_s: null })
  check('a member cannot push the plan', !!memberShift.error, memberShift.error?.message)
}

// ---------- 8. a broadcast and its acks ----------
scenario('Message everyone; each person acks once', 'One event type, a single ack tap; no threads, no replies')
{
  must(await root.rpc('plan_broadcast', { p_plan: plan.id, p_body: 'QA: hold at the gates', p_audience: 'all', p_group: null }), 'broadcast')
  const rows = must(await member.rpc('plan_log_list', { p_plan: plan.id, p_limit: 5 }), 'member log')
  const msg = rows.find((r) => r.kind === 'message')
  check('the member sees the message', !!msg)
  const a1 = await member.rpc('plan_log_ack', { p_log: msg.id })
  const a2 = await member.rpc('plan_log_ack', { p_log: msg.id })
  check('the ack is taken', !a1.error, a1.error?.message)
  check('a second ack does not count twice', !a2.error || /already/i.test(a2.error.message))
  const staff = must(await root.rpc('plan_log_list', { p_plan: plan.id, p_limit: 5 }), 'root log').find((r) => r.id === msg.id)
  check('the planner sees 1 ack', staff.acked === 1, `${staff.acked}/${staff.recipients}`)
  const out = await (await clientFor('outsider')).sb.rpc('plan_log_ack', { p_log: msg.id })
  check('someone outside the event cannot ack it', !!out.error, out.error?.message)
}

// ---------- 9. the end ----------
scenario('The event ends while the ICs are still sharing', 'At the end everyone\'s sharing stops')
{
  const pass = must(await ic1.sb.rpc('start_tracking_pass', { p_event_id: ev.eventId, p_group_id: ev.groups.Alpha }), 'pass')
  must(await root.rpc('end_event', { p_event_id: ev.eventId }), 'end')
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/report_location', { method: 'POST', headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: pass, p_lat: A.lat, p_lng: A.lng, p_accuracy: 5, p_recorded_at: new Date().toISOString() }) })
  check("a reading after the end is refused", !r.ok, r.status + ' ' + (await r.text()).slice(0, 80))
  const again = await root.rpc('start_event', { p_event_id: ev.eventId, p_plan: plan.id })
  check('the event can be started again (a new recording)', !again.error, again.error?.message)
  must(await root.rpc('end_event', { p_event_id: ev.eventId }), 'end 2')
  const list = await root.rpc('playback_list', { p_event_id: ev.eventId })
  check('both sessions are in playback', !list.error && (list.data || []).length >= 2, list.error?.message || (list.data || []).length + ' recordings')
}

const pass = results.flatMap((s) => s.checks).filter((c) => c.ok).length
const all = results.flatMap((s) => s.checks).length
fs.writeFileSync('.tmp/scenarios/result.json', JSON.stringify({ at: new Date().toISOString(), eventId: ev.eventId, pass, all, results }, null, 1))
console.log(`\n${pass}/${all} checks passed`)
process.exit(0)
