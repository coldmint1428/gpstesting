// E2E: SOS and attendance (Ern's event_creation_ern work, merged into komin-merge on 1 Nov), role by role.
// The rules are the database's own (072_sos.sql, 071_attendance.sql):
//   SOS:        anyone in the event raises one; everyone in the event is alerted and can say "I'm on my way";
//               the sender ("I'm safe"), root / planners / marshals and the sender's group IC or admin end it.
//   Attendance: root / planners run roll calls for any group, a group's IC or admin for their own; by hand, or (QR mode,
//               set by root / planners) everyone scans the QR on the IC's screen, which changes every 5 seconds.
// The member and the IC use a 390 px phone; the root uses a laptop.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
const PADANG = { latitude: 1.2931, longitude: 103.8558, accuracy: 12 }
let ev
let base
const pages = {}
const contexts = []

async function as(browser, role, device = { viewport: { width: 1360, height: 900 } }) {
  if (pages[role]) return pages[role]
  const context = await contextAs(browser, role, base, { ...device, geolocation: PADANG, permissions: ['geolocation'] })
  contexts.push(context)
  pages[role] = await context.newPage()
  return pages[role]
}
const okDialog = async (page) => {
  await expect(page.getByTestId('confirm-dialog')).toBeVisible()
  await page.getByTestId('confirm-ok').click()
  await expect(page.getByTestId('confirm-dialog')).toBeHidden()
}
const openSos = async (eventId) => {
  const { sb } = await clientFor('root')
  const { data } = await sb.from('sos_alerts').select('*').eq('event_id', eventId).order('id', { ascending: false })
  return data || []
}

test.beforeAll(async ({ baseURL }) => {
  base = baseURL
  ev = await makeQaEvent('SOS')
  const { sb } = await clientFor('root')
  const started = await sb.rpc('start_event', { p_event_id: ev.eventId, p_plan: null })
  if (started.error) throw started.error
})
test.afterAll(async () => {
  for (const c of contexts) await c.close()
})

// ---------- SOS ----------

test('a member on a phone sends an SOS with a note and their location', async ({ browser }) => {
  const member = await as(browser, 'member', PHONE)
  await member.goto(`/events/${ev.eventId}/live`)
  await member.getByTestId('sos-btn').first().click()
  await expect(member.getByTestId('sos-dialog')).toBeVisible()
  await shot(member, 'sos-01-dialog')
  await member.getByTestId('sos-note').fill('Twisted ankle near the stage')
  await member.getByTestId('sos-send').click()
  await expect(member.getByTestId('sos-mine')).toBeVisible({ timeout: 20_000 })
  await expect(member.getByTestId('sos-mine')).toContainText('No one has said they are on the way yet')
  await shot(member, 'sos-02-sent')

  const [row] = await openSos(ev.eventId)
  expect(row.note).toBe('Twisted ankle near the stage')
  expect(row.resolved_at).toBeNull()
  expect(Math.abs(row.lat - PADANG.latitude)).toBeLessThan(0.001) // the phone's position went with it
})

test('the root sees it on every page and on the map, and says they are on the way', async ({ browser }) => {
  const root = await as(browser, 'root')
  const [row] = await openSos(ev.eventId)
  await root.goto(`/events/${ev.eventId}/overview`)
  const banner = root.getByTestId('sos-' + row.id)
  await expect(banner).toBeVisible({ timeout: 20_000 })
  await expect(banner).toContainText('QA Member needs help')
  await expect(banner).toContainText('Twisted ankle near the stage')
  await expect(banner.getByTestId('sos-resolve')).toBeVisible() // root may end it
  await banner.getByTestId('sos-show').click() // "Show on map": the live map, zoomed to it
  await expect(root.locator('.sos-pin')).toBeVisible({ timeout: 15_000 })
  await shot(root, 'sos-03-root-map', { fullPage: true })
  await root.getByTestId('sos-' + row.id).getByTestId('sos-help').click()
  await expect(root.getByTestId('sos-' + row.id)).toContainText('You are on the way')

  const member = pages.member
  await expect(member.getByTestId('sos-mine')).toContainText('On the way: QA Root', { timeout: 20_000 })
  await shot(member, 'sos-04-help-coming')
})

test('the sender\'s group IC can end it ("handled"); it leaves everyone\'s screen', async ({ browser }) => {
  const ic = await as(browser, 'ic1', PHONE)
  const [row] = await openSos(ev.eventId)
  await ic.goto(`/events/${ev.eventId}/live`)
  const banner = ic.getByTestId('sos-' + row.id)
  await expect(banner).toBeVisible({ timeout: 20_000 })
  await banner.getByTestId('sos-resolve').click()
  await okDialog(ic)
  await expect(ic.getByTestId('sos-' + row.id)).toHaveCount(0, { timeout: 20_000 })
  await expect(pages.member.getByTestId('sos-mine')).toHaveCount(0, { timeout: 20_000 })
  await expect(pages.root.getByTestId('sos-' + row.id)).toHaveCount(0, { timeout: 20_000 })
  const [done] = await openSos(ev.eventId)
  expect(done.resolution).toBe('handled')
})

test('the sender can end their own SOS with "I\'m safe"', async () => {
  const member = pages.member
  await member.getByTestId('sos-btn').first().click()
  await member.getByTestId('sos-send').click() // no note: still sends
  await expect(member.getByTestId('sos-mine')).toBeVisible({ timeout: 20_000 })
  await member.getByTestId('sos-safe').click()
  await okDialog(member)
  await expect(member.getByTestId('sos-mine')).toHaveCount(0, { timeout: 20_000 })
  const [row] = await openSos(ev.eventId)
  expect(row.resolution).toBe('safe')
})

test('the database refuses the people who may not end an SOS, and outsiders see none', async () => {
  const { sb: memberSb } = await clientFor('member')
  const { data: id } = await memberSb.rpc('raise_sos', { p_event: ev.eventId, p_lat: null, p_lng: null, p_accuracy: null, p_note: 'db check' })
  const { sb: plannerSb } = await clientFor('planner')
  const { sb: outsiderSb } = await clientFor('outsider')
  const refused = await outsiderSb.rpc('resolve_sos', { p_id: id })
  expect(refused.error).not.toBeNull()
  const seen = await outsiderSb.from('sos_alerts').select('id').eq('event_id', ev.eventId)
  expect(seen.data).toEqual([]) // not in the event: no rows at all
  const ok = await plannerSb.rpc('resolve_sos', { p_id: id }) // a planner may
  expect(ok.error).toBeNull()
})

// ---------- Attendance ----------

test('the IC takes a roll call by hand; the member sees they are marked present', async ({ browser }) => {
  const ic = pages.ic1
  const member = pages.member
  await ic.goto(`/events/${ev.eventId}/attendance`)
  await expect(ic.getByTestId('attendance-run')).toBeVisible({ timeout: 20_000 })
  await ic.getByTestId('attendance-title').fill('Morning muster')
  await ic.getByTestId('attendance-start').click()
  await expect(ic.getByTestId('att-mark-qa_member')).toBeVisible({ timeout: 20_000 })

  await member.goto(`/events/${ev.eventId}/attendance`)
  await expect(member.getByTestId('attendance-wait')).toContainText('Morning muster', { timeout: 20_000 })
  await expect(member.getByTestId('attendance-run')).toHaveCount(0) // a member does not run roll calls
  await shot(member, 'att-01-member-waiting')

  await ic.getByTestId('att-mark-qa_member').click()
  await expect(member.getByTestId('attendance-done')).toContainText('You are marked present', { timeout: 20_000 })
  await shot(ic, 'att-02-ic-marked', { fullPage: true })
  await shot(member, 'att-03-member-present')
  await ic.getByTestId('attendance-close').first().click()
  await okDialog(ic)
})

test('in QR mode the member checks in with the code on the IC\'s screen, and an old code is refused', async ({ browser }) => {
  const root = pages.root
  await root.goto(`/events/${ev.eventId}/attendance`)
  await root.getByTestId('attendance-mode-qr').check()
  await expect.poll(async () => (await (await clientFor('root')).sb.from('events').select('attendance_mode').eq('id', ev.eventId).single()).data.attendance_mode, { timeout: 15_000 }).toBe('qr')

  const ic = pages.ic1
  await ic.goto(`/events/${ev.eventId}/attendance`)
  await ic.getByTestId('attendance-title').fill('Gate check')
  await ic.getByTestId('attendance-start').click()
  await expect(ic.getByTestId('attendance-qr')).toBeVisible({ timeout: 20_000 })
  await shot(ic, 'att-04-ic-qr', { fullPage: true })

  const member = pages.member
  await member.goto(`/events/${ev.eventId}/attendance`)
  await expect(member.getByTestId('attendance-scan')).toBeVisible({ timeout: 20_000 })
  await shot(member, 'att-05-member-scan')

  // A camera cannot be pointed at a screen in a test browser, so the member's scan is the same call the scanner makes,
  // with the code the IC's screen is showing right now (and, first, a made-up one).
  const { sb: icSb } = await clientFor('ic1')
  const { sb: memberSb } = await clientFor('member')
  const { data: open } = await icSb.from('attendance_rollcalls').select('id').eq('event_id', ev.eventId).is('closed_at', null).single()
  const bad = await memberSb.rpc('scan_rollcall', { p_rollcall: open.id, p_token: '000000' })
  expect(bad.data.ok).toBe(false)
  const { data: qr } = await icSb.rpc('rollcall_qr', { p_rollcall: open.id })
  const good = await memberSb.rpc('scan_rollcall', { p_rollcall: open.id, p_token: qr.token })
  expect(good.data).toEqual({ ok: true, title: 'Gate check' })
  await expect(member.getByTestId('attendance-done')).toContainText('You are marked present', { timeout: 20_000 })
  await shot(member, 'att-06-member-scanned')

  // In QR mode an IC may not mark people by hand; only root and planners may
  const { data: ic2 } = await (await clientFor('ic2')).sb.auth.getUser()
  const byHand = await icSb.rpc('mark_attendance', { p_rollcall: open.id, p_user: ic2.user.id, p_status: 'present' })
  expect(byHand.error && byHand.error.message).toMatch(/only a planner or the root/i)
  await ic.getByTestId('attendance-close').first().click()
  await okDialog(ic)
  await root.getByLabel(/By hand/).check() // put the event back to manual
})
