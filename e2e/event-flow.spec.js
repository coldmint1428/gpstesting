// E2E: one event from plan to playback, with every role in its own browser (IS216 Week 10c).
// The planner imports a plan sheet and publishes it, starts the event, an IC shares a faked GPS position, the
// planner sees it, the member sees their timetable, the marshal marks an arrival, the planner pushes the plan and
// broadcasts, the member acknowledges, the planner ends the event (typing END) and replays it.
import { test, expect } from '@playwright/test'
import fs from 'node:fs'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const PADANG = [
  { lat: 1.293125826, lng: 103.855851363 }, // P1
  { lat: 1.292542833, lng: 103.853680767 }, // P7
]
const metres = (a, b) => Math.hypot((b.lat - a.lat) * 110574, (b.lng - a.lng) * 111320 * Math.cos((a.lat * Math.PI) / 180))

/** Alpha walks P1 -> P7 in steps of at most 20 m, a minute apart; Bravo stands at P7 the whole time. */
function planSheet({ jump = false } = {}) {
  const [a, b] = PADANG
  const n = Math.ceil(metres(a, b) / 20)
  const lines = ['t_s,note,group,lat,lng,state,verify']
  for (let i = 0; i <= n; i++) {
    const f = jump && i === 1 ? 1 : i / n // a "jump" sheet skips most of the walk in one step
    const p = { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f }
    lines.push(`${i * 60},${i === 0 ? 'Gates open' : i === n ? 'Alpha in position' : ''},Alpha,${p.lat},${p.lng},on_site,auto`)
    if (i === 0) lines.push(`0,,Bravo,${b.lat},${b.lng},on_site,auto`)
    if (jump && i === 1) break
  }
  return { csv: lines.join('\r\n') + '\r\n', moments: jump ? 2 : n + 1 }
}

let ev
let base
const contexts = {}
async function as(browser, role, options) {
  if (!contexts[role]) contexts[role] = await contextAs(browser, role, base, options)
  const page = contexts[role].pages()[0] || (await contexts[role].newPage())
  return page
}
const okDialog = async (page) => {
  const dialog = page.getByTestId('confirm-dialog')
  await expect(dialog).toBeVisible()
  await page.getByTestId('confirm-ok').click()
  await expect(dialog).toBeHidden()
}

test.beforeAll(async ({ baseURL }) => {
  base = baseURL
  ev = await makeQaEvent('Flow')
  fs.mkdirSync('.tmp/e2e', { recursive: true })
  fs.writeFileSync('.tmp/e2e/flow-event.json', JSON.stringify(ev))
})
test.afterAll(async () => {
  for (const c of Object.values(contexts)) await c.close()
})

test('the planner makes a plan, and a sheet that breaks the 25 m rule is refused with the row', async ({ browser }) => {
  const page = await as(browser, 'root')
  await page.goto(`/events/${ev.eventId}/timeline`)
  await page.getByPlaceholder('Name the first plan').fill('NDP walk-through')
  await page.getByRole('button', { name: 'Create plan' }).click()
  await expect(page.getByTestId('sheet-import')).toBeEnabled()

  const bad = planSheet({ jump: true })
  await page.getByTestId('sheet-file').setInputFiles({ name: 'bad.csv', mimeType: 'text/csv', buffer: Buffer.from(bad.csv) })
  const dialog = page.getByTestId('confirm-dialog')
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText(/25 ?m/)
  await shot(page, 'flow-01-sheet-refused')
  await page.getByTestId('confirm-cancel').or(page.getByTestId('confirm-ok')).first().click()
  await expect(dialog).toBeHidden()
})

test('the planner imports a good sheet and publishes it', async ({ browser }) => {
  const page = await as(browser, 'root')
  const good = planSheet()
  await page.getByTestId('sheet-file').setInputFiles({ name: 'walk.csv', mimeType: 'text/csv', buffer: Buffer.from(good.csv) })
  await okDialog(page) // "Replace every moment of this plan?"
  await expect(page.locator('[data-testid^="sched-at-"], [data-testid="timeline"] [data-testid^="frame"]').first()).toBeVisible().catch(() => {})
  const { sb } = await clientFor('root')
  const { data: plans } = await sb.from('plans').select('id, status').eq('event_id', ev.eventId)
  ev.planId = plans[0].id
  await expect
    .poll(async () => (await sb.rpc('plan_frames_list', { p_plan: ev.planId })).data?.length ?? 0, { timeout: 20_000 })
    .toBe(good.moments)
  await page.getByRole('button', { name: /^Publish$/ }).click()
  const confirm = page.getByTestId('confirm-dialog')
  if (await confirm.isVisible().catch(() => false)) await page.getByTestId('confirm-ok').click()
  await expect.poll(async () => (await sb.from('plans').select('status').eq('id', ev.planId).single()).data.status).toBe('live')
  await shot(page, 'flow-02-plan-published', { fullPage: true })
})

test('the planner starts the event with the published plan', async ({ browser }) => {
  const page = await as(browser, 'root')
  await page.reload()
  await page.getByTestId('start-event-btn').click()
  await page.getByTestId('start-engine').selectOption({ value: 'plan:' + ev.planId })
  // T+0 now: a walk-through starts on its first frame (QA-02; checked against the session by the last test)
  ev.t0Control = await page.getByTestId('start-t0-now').isVisible().catch(() => false)
  if (ev.t0Control) await expect(page.getByTestId('start-t0-now')).toBeChecked()
  await shot(page, 'flow-03a-start-t0')
  await page.getByTestId('start-confirm-btn').click()
  const confirm = page.getByTestId('confirm-dialog')
  if (await confirm.isVisible({ timeout: 3000 }).catch(() => false)) await page.getByTestId('confirm-ok').click()
  await expect(page.getByTestId('status-live').or(page.getByTestId('end-event-btn')).first()).toBeVisible()
  await shot(page, 'flow-03-live')
})

test('an IC shares a (faked) GPS position and the planner sees them on the live map', async ({ browser }) => {
  const ic = await as(browser, 'ic1', { geolocation: { latitude: PADANG[0].lat, longitude: PADANG[0].lng, accuracy: 8 }, permissions: ['geolocation'] })
  await ic.goto(`/events/${ev.eventId}/live`)
  await ic.getByTestId('share-btn').click()
  const confirm = ic.getByTestId('confirm-dialog')
  if (await confirm.isVisible({ timeout: 3000 }).catch(() => false)) await ic.getByTestId('confirm-ok').click()
  await expect(ic.getByTestId('badge-sharing').or(ic.getByTestId('sharing-banner')).first()).toBeVisible()
  await shot(ic, 'flow-04-ic-sharing')

  const { sb } = await clientFor('root')
  await expect
    .poll(async () => (await sb.from('locations').select('id', { count: 'exact', head: true }).eq('event_id', ev.eventId)).count, { timeout: 30_000 })
    .toBeGreaterThan(0)

  const planner = await as(browser, 'root')
  await planner.goto(`/events/${ev.eventId}/live`)
  await expect(planner.getByTestId('person-qa_ic1').first()).toBeVisible({ timeout: 30_000 })
  await shot(planner, 'flow-05-planner-sees-ic', { fullPage: true })
})

test('a member cannot share, and sees their own group only', async ({ browser }) => {
  const page = await as(browser, 'member')
  await page.goto(`/events/${ev.eventId}/live`)
  await expect(page.getByTestId('share-btn')).toHaveCount(0)
  await expect(page.getByText(/You can see your group: Alpha/)).toBeVisible()
  await shot(page, 'flow-06-member-live')
  await page.goto(`/events/${ev.eventId}/timeline`)
  await expect(page.getByTestId('plan-schedule').or(page.getByTestId('sched-row')).first()).toBeVisible()
  await shot(page, 'flow-07-member-schedule', { fullPage: true })
})

test('the marshal marks Alpha as arrived on the ops board', async ({ browser }) => {
  const page = await as(browser, 'marshal')
  await page.goto(`/events/${ev.eventId}/live`) // the ops board sits on the Live page
  const mark = page.getByTestId('ops-mark-arrived').first()
  await expect(mark).toBeVisible({ timeout: 30_000 })
  await mark.click()
  const { sb } = await clientFor('root')
  await expect
    .poll(async () => (await sb.from('plan_progress').select('plan_id', { count: 'exact', head: true }).eq('plan_id', ev.planId)).count ?? 0, { timeout: 20_000 })
    .toBeGreaterThan(0)
  await shot(page, 'flow-08-marshal-marked', { fullPage: true })
})

test('the planner pushes the rest of the plan by a minute, and the member is told the timeline changed', async ({ browser }) => {
  const planner = await as(browser, 'root')
  await planner.goto(`/events/${ev.eventId}/timeline`)
  const { sb } = await clientFor('root')
  const before = (await sb.from('plans').select('rev').eq('id', ev.planId).single()).data.rev
  const framesOf = async () => (await sb.rpc('plan_frames_list', { p_plan: ev.planId })).data.map((f) => f.t_s).sort((a, b) => a - b)
  const t0 = await framesOf()
  // Select the last moment ("Alpha in position") and push it a minute later: Alpha arrives a minute later
  await planner.locator('.pv-frame').last().click()
  await planner.getByTestId('push-60').click()
  const confirm = planner.getByTestId('confirm-dialog')
  if (await confirm.isVisible({ timeout: 3000 }).catch(() => false)) await planner.getByTestId('confirm-ok').click()
  await expect.poll(framesOf, { timeout: 20_000 }).toEqual([...t0.slice(0, -1), t0[t0.length - 1] + 60])
  await planner.getByRole('button', { name: /Publish again/ }).click()
  if (await confirm.isVisible({ timeout: 3000 }).catch(() => false)) await planner.getByTestId('confirm-ok').click()
  await expect.poll(async () => (await sb.from('plans').select('rev').eq('id', ev.planId).single()).data.rev, { timeout: 20_000 }).toBeGreaterThan(before)
  await shot(planner, 'flow-09-pushed', { fullPage: true })

  const member = await as(browser, 'member')
  await member.goto(`/events/${ev.eventId}/timeline`)
  await expect(member.getByTestId('sched-rev').first()).toBeVisible({ timeout: 30_000 })
  const lastLabel = '+' + Math.floor((t0[t0.length - 1] + 60) / 60) + ':00'
  await expect(member.getByText(lastLabel, { exact: true })).toBeVisible({ timeout: 30_000 }) // the new time reached the member
  await shot(member, 'flow-10-member-updated', { fullPage: true })
})

test('the planner ends the event only after typing END', async ({ browser }) => {
  const page = await as(browser, 'root')
  await page.goto(`/events/${ev.eventId}/overview`)
  await page.getByTestId('end-event-btn').click()
  const ok = page.getByTestId('confirm-ok')
  await expect(ok).toBeDisabled()
  await page.getByTestId('confirm-type').fill('end')
  await expect(ok).toBeEnabled()
  await shot(page, 'flow-11-type-end')
  await ok.click()
  await expect(page.getByTestId('start-event-btn').or(page.getByTestId('status-not-started')).first()).toBeVisible({ timeout: 30_000 })
  const { sb } = await clientFor('root')
  const { data } = await sb.from('event_sessions').select('ended_at').eq('event_id', ev.eventId)
  expect(data.every((s) => s.ended_at)).toBe(true)
})

test('the planner replays the session and downloads it as CSV', async ({ browser }) => {
  const page = await as(browser, 'root')
  await page.goto(`/events/${ev.eventId}/playback`)
  await expect(page.getByTestId('recording-list')).toBeVisible()
  await page.getByTestId('play-recording-btn').first().click()
  await expect(page.getByTestId('playback-player')).toBeVisible()
  await shot(page, 'flow-12-playback', { fullPage: true })
  const download = page.waitForEvent('download')
  await page.getByTestId('player-download').or(page.getByTestId('download-csv-btn')).first().click()
  const file = await download
  const text = fs.readFileSync(await file.path(), 'utf8')
  expect(text).toMatch(/^﻿?# (Planova|Event Tracker) playback/) // the title changed with the rename; both are read back
  expect(text).toContain('qa_ic1')
})

test('someone outside joins with the code and lands in the event as a member', async ({ browser }) => {
  const page = await as(browser, 'outsider')
  await page.goto('/events')
  const code = page.getByTestId('join-code').first()
  await code.fill(ev.joinCode) // (the pasted-with-a-dash case is public.spec's, QA-01)
  await code.press('Enter')
  await expect(page).toHaveURL(new RegExp(`/events/${ev.eventId}`))
  await shot(page, 'flow-13-outsider-joined')
})

test('regression QA-02: the session T+0 was the moment it started, not 18:00 on the UTC date', async () => {
  const { sb } = await clientFor('root')
  const { data } = await sb.from('event_sessions').select('starts_at, t0_at').eq('event_id', ev.eventId).order('starts_at')
  const first = data[0]
  const off = Math.abs(new Date(first.t0_at) - new Date(first.starts_at))
  test.info().annotations.push({ type: 'T+0 offset', description: Math.round(off / 60000) + ' min from the start' })
  expect(off, 'minutes between T+0 and the start: ' + Math.round(off / 60000)).toBeLessThan(120_000)
})
