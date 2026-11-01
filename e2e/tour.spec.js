// E2E: every page of the app, as every role that can open it (IS216 Week 10c, a full feature tour).
// One live event is set up the way a real night looks -- a published 20-moment plan, the event started, an IC sharing
// GPS -- and each page is opened as the people who use it. A page passes when it renders its own heading and the
// content that proves it read the event, with no uncaught script error and no failed call to the database.
import { test, expect } from '@playwright/test'
import fs from 'node:fs'
import { contextAs, clientFor, SUPABASE_URL, ANON_KEY } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(240_000) // the root visits ten pages in one test; page transitions (968009b, e1c0ba1) add to each

const A = { lat: 1.290315, lng: 103.851806 }
const B = { lat: 1.291476, lng: 103.85232 }
const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
const DESK = { viewport: { width: 1440, height: 900 } }

let ev
let planId
let base
const contexts = []
const problems = [] // every page error or failed database call seen anywhere in the tour

test.beforeAll(async ({ baseURL }) => {
  base = baseURL
  ev = await makeQaEvent('Tour')
  const { sb } = await clientFor('root')
  const sg = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date())
  const part = (t) => sg.find((x) => x.type === t).value
  const { data: plan } = await sb.rpc('plan_save', {
    p_event: ev.eventId,
    p_plan: { name: 'Tour walk', for_date: `${part('year')}-${part('month')}-${part('day')}`, t0_time: `${part('hour')}:${part('minute')}:00` },
  })
  planId = plan.id
  const frames = []
  for (let i = 0; i < 20; i++) {
    const f = Math.min(1, i / 7)
    frames.push({ t_s: i * 60, note: i === 0 ? 'Gates open' : i === 7 ? 'In position' : '', positions: {
      [ev.groups.Alpha]: { lat: A.lat + (B.lat - A.lat) * f, lng: A.lng + (B.lng - A.lng) * f, state: 'on_site', verify: 'auto' },
      [ev.groups.Bravo]: { ...B, state: 'on_site', verify: 'auto' },
    } })
  }
  for (const [fn, args] of [
    ['plan_import', { p_plan: planId, p_frames: frames }],
    ['plan_publish', { p_plan: planId, p_plan_rev: (await sb.from('plans').select('rev').eq('id', planId).single()).data.rev + 1 }],
  ]) {
    let r = await sb.rpc(fn, args)
    if (r.error && fn === 'plan_publish') {
      const rev = (await sb.from('plans').select('rev').eq('id', planId).single()).data.rev
      r = await sb.rpc(fn, { p_plan: planId, p_plan_rev: rev })
    }
    if (r.error) throw new Error(fn + ': ' + r.error.message)
  }
  const started = await sb.rpc('start_event', { p_event_id: ev.eventId, p_plan: planId })
  if (started.error) throw started.error
  // The IC's phone: a tracking pass and three readings along the walk, as the app sends them.
  const ic = (await clientFor('ic1')).sb
  const { data: pass } = await ic.rpc('start_tracking_pass', { p_event_id: ev.eventId, p_group_id: ev.groups.Alpha })
  for (let i = 0; i < 3; i++) {
    await fetch(SUPABASE_URL + '/rest/v1/rpc/report_location', {
      method: 'POST',
      headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_token: pass, p_lat: A.lat + i * 0.00005, p_lng: A.lng + i * 0.00002, p_accuracy: 6, p_recorded_at: new Date().toISOString() }),
    })
  }
  await sb.rpc('plan_broadcast', { p_plan: planId, p_body: 'Tour: gates open in five minutes', p_audience: 'all', p_group: null })
  fs.mkdirSync('.tmp/e2e', { recursive: true })
  fs.writeFileSync('.tmp/e2e/tour-event.json', JSON.stringify({ ...ev, planId }))
})

test.afterAll(async () => {
  for (const c of contexts) await c.close()
  fs.writeFileSync('.tmp/e2e/tour-problems.json', JSON.stringify(problems, null, 2))
})

/** A page for a role, watched for script errors and failed database calls. */
async function pageAs(browser, role, device = DESK) {
  const context = await contextAs(browser, role, base, device)
  contexts.push(context)
  const page = await context.newPage()
  page.on('pageerror', (e) => problems.push({ role, url: page.url(), kind: 'script error', text: e.message }))
  page.on('response', (r) => {
    // A 4xx/5xx from the database is a failed feature; tiles and fonts are not the app's.
    if (r.url().startsWith(SUPABASE_URL) && r.status() >= 400) {
      problems.push({ role, url: page.url(), kind: 'db ' + r.status(), text: r.url().replace(SUPABASE_URL, '').slice(0, 120) })
    }
  })
  return page
}

/** Open a page and check it rendered: its heading, the text that proves it read the event, and no new problems. */
async function visit(page, path, { heading, shows = [], name, full = true }) {
  const before = problems.length
  await page.goto(path)
  if (heading) await expect(page.getByRole('heading', { name: heading }).first()).toBeVisible({ timeout: 30_000 })
  // Visible matches only: the Live page stays in the page (hidden) once opened, with group names of its own
  for (const text of shows) await expect(page.getByText(text).filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText('Loading...', { exact: true })).toHaveCount(0, { timeout: 30_000 })
  await page.waitForTimeout(1200) // let the map tiles and the realtime first read land before the picture
  await shot(page, 'tour-' + name, { fullPage: full })
  const fresh = problems.slice(before).filter((p) => p.kind === 'script error' || p.kind.startsWith('db 5'))
  expect(fresh, 'script errors or server errors on ' + path).toEqual([])
}

test('a visitor: home, sign in, create an account, and an invite link that asks them to sign in', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: base, ...DESK })
  contexts.push(context)
  const page = await context.newPage()
  page.on('pageerror', (e) => problems.push({ role: 'visitor', url: page.url(), kind: 'script error', text: e.message }))
  await page.goto('/')
  await expect(page.getByRole('link', { name: /log in/i }).first()).toBeVisible()
  await shot(page, 'tour-visitor-home', { fullPage: true })
  await page.goto('/login')
  await expect(page.getByRole('heading', { name: 'Log in' })).toBeVisible()
  await shot(page, 'tour-visitor-login')
  await page.goto('/signup')
  await expect(page.getByRole('heading', { name: /create|sign up/i }).first()).toBeVisible()
  await shot(page, 'tour-visitor-signup')
  await page.goto('/join/' + ev.joinCode)
  await expect(page).toHaveURL(/\/login/)
  await page.goto('/no-such-page')
  await expect(page).toHaveURL(base.replace(/\/$/, '') + '/')
  expect(problems.filter((p) => p.role === 'visitor')).toEqual([])
  await context.close()
  contexts.splice(contexts.indexOf(context), 1)
})

test('the root: every page of a live event, on a laptop', async ({ browser }) => {
  const page = await pageAs(browser, 'root')
  const e = `/events/${ev.eventId}`
  await visit(page, '/events', { heading: /^Good (morning|afternoon|evening)/, shows: [/QA-Tour/], name: 'root-events' })
  await visit(page, `${e}/overview`, { shows: [/QA-Tour/, 'Live'], name: 'root-overview' })
  await visit(page, `${e}/timeline`, { heading: 'Timeline', shows: ['Tour walk'], name: 'root-timeline' })
  await expect(page.locator('.pv-frame')).toHaveCount(20)
  await visit(page, `${e}/map`, { heading: 'Map', name: 'root-map' })
  await visit(page, `${e}/people`, { heading: 'People', shows: ['QA Member'], name: 'root-people' })
  await visit(page, `${e}/groups`, { heading: 'Groups', shows: ['Alpha', 'Bravo'], name: 'root-groups' })
  await visit(page, `${e}/live`, { heading: 'Live', shows: ['QA Ic1'], name: 'root-live' })
  await visit(page, `${e}/playback`, { heading: 'Playback', name: 'root-playback' })
  await visit(page, '/events/new', { name: 'root-wizard', shows: [/name/i] })
  await visit(page, '/profile', { name: 'root-profile', shows: [/qa_root/] })
})

test('the planner and the marshal: the plan and the ops board', async ({ browser }) => {
  const planner = await pageAs(browser, 'planner')
  await visit(planner, `/events/${ev.eventId}/timeline`, { heading: 'Timeline', shows: ['Tour walk'], name: 'planner-timeline' })
  await expect(planner.getByTestId('frame-add')).toBeVisible() // a planner can edit
  const marshal = await pageAs(browser, 'marshal')
  await visit(marshal, `/events/${ev.eventId}/live`, { heading: 'Live', shows: ['Alpha'], name: 'marshal-live' })
})

test('the IC on a phone: Now, sharing and the set-up check', async ({ browser }) => {
  const page = await pageAs(browser, 'ic1', PHONE)
  await visit(page, '/events', { name: 'ic-events', shows: [/QA-Tour/] })
  await visit(page, `/events/${ev.eventId}/live`, { name: 'ic-live', shows: [/Alpha/] })
  await visit(page, `/events/${ev.eventId}/share`, { name: 'ic-share', shows: [/shar/i] })
  await visit(page, '/check-phone', { name: 'ic-check-phone', shows: [/phone|location/i] })
})

test('the member on a phone: own group only, the timetable and the message', async ({ browser }) => {
  const page = await pageAs(browser, 'member', PHONE)
  await visit(page, `/events/${ev.eventId}/timeline`, { name: 'member-timeline', shows: [/Alpha/] })
  await expect(page.getByText('Bravo', { exact: true })).toHaveCount(0) // another group's plan is not theirs to read
  await visit(page, `/events/${ev.eventId}/live`, { name: 'member-live', shows: [/your group/i] })
  await expect(page.getByTestId('share-btn')).toHaveCount(0) // a member does not share
  await visit(page, '/me', { name: 'member-me', shows: [/QA Member/] })
})

test('someone outside the event cannot open it', async ({ browser }) => {
  const page = await pageAs(browser, 'outsider')
  await page.goto(`/events/${ev.eventId}/timeline`)
  await expect(page).not.toHaveURL(new RegExp(`/events/${ev.eventId}/timeline`), { timeout: 20_000 })
  await shot(page, 'tour-outsider-refused')
})

test('the root ends the event, and the night is in playback', async ({ browser }) => {
  const { sb } = await clientFor('root')
  const ended = await sb.rpc('end_event', { p_event_id: ev.eventId })
  expect(ended.error).toBeNull()
  const page = await pageAs(browser, 'root')
  await visit(page, `/events/${ev.eventId}/playback`, { heading: 'Playback', name: 'root-playback-ended' })
  await expect(page.getByTestId('play-recording-btn').first()).toBeVisible()
})
