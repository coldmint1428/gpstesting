// E2E: an IC shares their location, the phone's coarse fixes are left out, and Stop stops (2 Nov).
// Bug report: "I have stopped sharing but my icon is still moving. Even when I share, my icon keeps moving back and
// forth." The data showed a GPS fix and a ±100 m Wi-Fi fix 120 m apart in turn, and sharing that started again two
// seconds after Stop (the Share button takes Stop's place). The browser stands in for the phone here: its position is
// set by the test, and it uploads through the same table the app's readings land in.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const GOOD = { latitude: 1.297435, longitude: 103.849695, accuracy: 15 }
const COARSE = { latitude: 1.298275, longitude: 103.84898, accuracy: 100 }
let ev
let ic
let context
let base

async function rows(sb, where = {}) {
  let q = sb.from('locations').select('lat, lng, accuracy, source, recorded_at').eq('event_id', ev.eventId).order('recorded_at')
  for (const [k, v] of Object.entries(where)) q = q.eq(k, v)
  const { data, error } = await q
  if (error) throw error
  return data
}

test.beforeAll(async ({ browser, baseURL }) => {
  base = baseURL
  ev = await makeQaEvent('Sharing')
  const { sb } = await clientFor('root')
  const started = await sb.rpc('start_event', { p_event_id: ev.eventId, p_plan: null })
  if (started.error) throw started.error
  context = await contextAs(browser, 'ic1', base, {
    viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, geolocation: GOOD, permissions: ['geolocation'],
  })
  ic = await context.newPage()
})
test.afterAll(async () => {
  if (context) await context.close()
  const { sb } = await clientFor('root')
  await sb.rpc('delete_event', { p_event_id: ev.eventId })
})

test('the IC shares; a ±100 m fix between good ones is not stored', async () => {
  await ic.goto(`/events/${ev.eventId}/live`)
  await ic.getByTestId('share-btn').click()
  await expect(ic.getByTestId('sharing-banner')).toBeVisible({ timeout: 20_000 })
  const { sb } = await clientFor('ic1')
  await expect.poll(async () => (await rows(sb)).length, { timeout: 20_000 }).toBeGreaterThan(0)

  // The phone indoors: Wi-Fi fix, GPS fix, Wi-Fi fix ... (the browser saves at most one reading every 5 s)
  for (const place of [COARSE, GOOD, COARSE, GOOD]) {
    await context.setGeolocation(place)
    await ic.waitForTimeout(5600)
  }
  const stored = await rows(sb, { source: 'gps' })
  expect(stored.length).toBeGreaterThanOrEqual(2)
  expect(stored.filter((r) => r.accuracy >= 50)).toEqual([]) // 075: dropped by the database
  await shot(ic, 'share-01-sharing')
})

test('Stop asks first; Cancel keeps sharing on', async () => {
  await ic.getByTestId('stop-share-btn').click()
  await expect(ic.getByTestId('confirm-dialog')).toBeVisible()
  await shot(ic, 'share-02-stop-asks')
  await ic.getByTestId('confirm-cancel').click()
  await expect(ic.getByTestId('sharing-banner')).toBeVisible()
})

test('after Stop nothing more is uploaded, and the map shows one Stop', async () => {
  const { sb } = await clientFor('ic1')
  await ic.getByTestId('stop-share-btn').click()
  await ic.getByTestId('confirm-ok').click()
  await expect(ic.getByTestId('share-btn')).toBeVisible({ timeout: 20_000 })
  await expect.poll(async () => (await rows(sb, { source: 'stop' })).length, { timeout: 15_000 }).toBe(1)
  const stoppedAt = Date.parse((await rows(sb, { source: 'stop' }))[0].recorded_at)

  // The position keeps changing; a stopped share must not send any of it
  for (const place of [COARSE, GOOD, COARSE]) {
    await context.setGeolocation(place)
    await ic.waitForTimeout(4000)
  }
  const after = (await rows(sb)).filter((r) => Date.parse(r.recorded_at) > stoppedAt)
  expect(after).toEqual([])
  expect(await rows(sb, { source: 'stop' })).toHaveLength(1)
  await shot(ic, 'share-03-stopped')

  // The planner's map: the IC is "Stopped sharing"
  const planner = await (await contextAs(ic.context().browser(), 'root', base)).newPage()
  await planner.goto(`/events/${ev.eventId}/live`)
  await expect(planner.getByTestId('person-qa_ic1').first()).toContainText(/stopped/i, { timeout: 30_000 })
  await shot(planner, 'share-04-planner-sees-stopped', { fullPage: true })
  await planner.context().close()
})
