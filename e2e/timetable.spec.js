// E2E (database, no browser): the schedule the phone works out equals the one the database answers (2 Nov).
// Since the load fixes the app reads the whole timetable once per published version and works out "late / pending /
// off site" itself (src/utils/timetableLocal.js), with the marks from the small session_marks read (076). This test
// holds that to the database's own answer on a real plan: a copy read now, judged a while later with the marks of
// later, must equal what session_timetable says later -- for root (every group), an IC and a member (their group).
import { test, expect } from '@playwright/test'
import { clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { baseOf, marksOf, judge } from '../src/utils/timetableLocal.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const A = { lat: 1.2931, lng: 103.8558 }
let ev
let planId
let sessionId

// Postgres interval text -> seconds
function seconds(text) {
  if (text == null) return null
  const m = String(text).match(/^\s*(-?)(?:(\d+)\s+days?\s+)?(\d+):(\d+):(\d+(?:\.\d+)?)\s*$/)
  const value = Number(m[2] || 0) * 86400 + Number(m[3]) * 3600 + Number(m[4]) * 60 + Number(m[5])
  return m[1] ? -value : value
}
// The database's clock at the moment it answered, from any late unmarked row
function nowOf(rows) {
  const late = rows.find((r) => r.state === 'late' && !r.marked_at)
  return late ? new Date(late.planned_at).getTime() + seconds(late.lateness) * 1000 : null
}

test.beforeAll(async () => {
  ev = await makeQaEvent('Timetable')
  const { sb } = await clientFor('root')
  const sg = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date())
  const part = (t) => sg.find((x) => x.type === t).value
  const { data: plan, error } = await sb.rpc('plan_save', {
    p_event: ev.eventId,
    p_plan: { name: 'Timetable check', for_date: `${part('year')}-${part('month')}-${part('day')}`, t0_time: `${part('hour')}:${part('minute')}:00` },
  })
  if (error) throw error
  planId = plan.id
  // 60 moments 5 s apart (some already past when the test runs); Alpha off site at every seventh
  const frames = []
  for (let i = 0; i < 60; i++) {
    frames.push({ t_s: i * 5, note: '', positions: {
      [ev.groups.Alpha]: { lat: A.lat + i * 0.00001, lng: A.lng, state: i % 7 === 3 ? 'off_site' : 'on_site', verify: 'auto' },
      [ev.groups.Bravo]: { lat: A.lat, lng: A.lng + 0.0003, state: 'on_site', verify: 'auto' },
    } })
  }
  const imported = await sb.rpc('plan_import', { p_plan: planId, p_frames: frames })
  if (imported.error) throw imported.error
  let rev = (await sb.from('plans').select('rev').eq('id', planId).single()).data.rev
  let published = await sb.rpc('plan_publish', { p_plan: planId, p_plan_rev: rev + 1 })
  if (published.error) published = await sb.rpc('plan_publish', { p_plan: planId, p_plan_rev: rev })
  if (published.error) throw published.error
  const started = await sb.rpc('start_event', { p_event_id: ev.eventId, p_plan: planId })
  if (started.error) throw started.error
  sessionId = (await sb.from('event_sessions').select('id').eq('event_id', ev.eventId).is('ended_at', null).single()).data.id
})
test.afterAll(async () => {
  const { sb } = await clientFor('root')
  await sb.rpc('delete_event', { p_event_id: ev.eventId })
})

for (const role of ['root', 'ic1', 'member']) {
  test(`${role}: the copy judged later equals the database's answer later`, async () => {
    const { sb } = await clientFor(role)
    const first = await sb.rpc('session_timetable', { p_session: sessionId })
    expect(first.error).toBeNull()
    const copy = baseOf(first.data)
    expect(copy.base.length).toBeGreaterThan(0)

    // Time passes, and the IC taps two moments (one of them already on the copy as late)
    const ic = (await clientFor('ic1')).sb
    const { data: rows } = await ic.rpc('session_timetable', { p_session: sessionId })
    const past = rows.filter((r) => r.state === 'late')
    for (const r of past.slice(0, 2)) {
      await ic.rpc('progress_mark', { p_session: sessionId, p_frame: r.frame_id, p_group: r.group_id, p_state: 'arrived' })
    }
    await new Promise((resolve) => setTimeout(resolve, 6000))

    const later = await sb.rpc('session_timetable', { p_session: sessionId })
    expect(later.error).toBeNull()
    // The marks as the phone gets them: from session_marks (076), or, on a database without it, from the later rows
    const fromMarks = await sb.rpc('session_marks', { p_session: sessionId })
    const marks = fromMarks.error
      ? marksOf(later.data.filter((r) => r.marked_at).map((r) => ({ group_id: r.group_id, frame_id: r.frame_id, state: r.state, marked_at: r.marked_at, marked_by: r.marked_by })))
      : marksOf(fromMarks.data.marks)
    if (fromMarks.error) test.info().annotations.push({ type: 'note', description: 'session_marks not on this database yet: marks taken from the later rows' })
    else expect(fromMarks.data.plan_rev).toBe(copy.rev)

    const judged = judge(copy.base, marks, nowOf(later.data))
    expect(judged).toHaveLength(later.data.length)
    for (let i = 0; i < judged.length; i++) {
      const mine = judged[i]
      const theirs = later.data[i]
      expect({ frame: mine.frame_id, group: mine.group_id, state: mine.state, marked_at: mine.marked_at && new Date(mine.marked_at).getTime() })
        .toEqual({ frame: theirs.frame_id, group: theirs.group_id, state: theirs.state, marked_at: theirs.marked_at && new Date(theirs.marked_at).getTime() })
      if (theirs.lateness == null) expect(mine.lateness).toBeNull()
      else expect(Math.abs(seconds(mine.lateness) - seconds(theirs.lateness))).toBeLessThan(0.01)
    }
    // The scope is the database's: a member and an IC see their own group only
    if (role !== 'root') expect(new Set(judged.map((r) => r.group_id))).toEqual(new Set([ev.groups.Alpha]))
  })
}
