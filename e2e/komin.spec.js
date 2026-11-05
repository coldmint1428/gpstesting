// E2E — Owner: Komin. Key feature: the live operations dashboard.
//
// Two things a planner relies on during a run, tested against the real backend rather than a mounted component:
//   1. The counts on the event's dashboard are the event's counts, and a member's copy of that page shows neither the
//      count nor the invite code.
//   2. The live map keeps working when the basemap tiles do not arrive. At a venue the OneMap tiles are the first
//      thing to go (a thousand phones on one access point); the map is not the tiles, and losing them must not lose
//      the screen the ops team is watching.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.setTimeout(120_000)

let ev

test.beforeAll(async () => {
  ev = await makeQaEvent('Ops')
  // A session, so /live is the live map rather than its "nothing is running" state. The event runs with no plan:
  // a session may follow a plan or nothing at all (step 24).
  const { sb } = await clientFor('root')
  const started = await sb.rpc('start_event', { p_event_id: ev.eventId })
  if (started.error) throw new Error('start_event: ' + started.error.message)
})

test('the dashboard counts the event, and a member is shown neither the count nor the invite code', async ({ browser, baseURL }) => {
  // The QA event is made with five people plus its creator, in two groups (support/fixture.js).
  const planner = await (await contextAs(browser, 'planner', baseURL)).newPage()
  await planner.goto(`/events/${ev.eventId}/overview`)
  await expect(planner.getByTestId('overview')).toBeVisible({ timeout: 30_000 })
  await expect(planner.getByTestId('overview')).toContainText('6 in 2 groups')
  await expect(planner.getByTestId('join-code-display')).toHaveText(ev.joinCode)
  await shot(planner, 'ops-01-planner-dashboard')

  // The same page, as somebody in a group: their own group is named, the event-wide count is not, and the code --
  // which the database refuses them anyway -- is not on the page at all.
  const member = await (await contextAs(browser, 'member', baseURL)).newPage()
  await member.goto(`/events/${ev.eventId}/overview`)
  await expect(member.getByTestId('overview')).toBeVisible({ timeout: 30_000 })
  await expect(member.getByTestId('overview')).toContainText('Alpha')
  await expect(member.getByTestId('overview')).not.toContainText('in 2 groups')
  await expect(member.getByTestId('join-code-display')).toHaveCount(0)
  await shot(member, 'ops-02-member-dashboard')
})

test('the live map keeps working when the OneMap tiles do not load', async ({ browser, baseURL }) => {
  const context = await contextAs(browser, 'planner', baseURL, { viewport: { width: 1280, height: 860 } })
  const page = await context.newPage()
  const crashed = []
  page.on('pageerror', (e) => crashed.push(e.message))

  // Tiles from the Singapore Land Authority's OneMap. Blocking them is what the venue's wifi does.
  await page.route('**/onemap.gov.sg/maps/tiles/**', (route) => route.abort())
  await page.goto(`/events/${ev.eventId}/live`)

  // The map is still a map: Leaflet drew its own panes and its zoom control, the map still reports the size it was
  // given, and nothing threw on the way. The tiles are grey, not the screen.
  await expect(page.getByTestId('live-map')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('.leaflet-container')).toBeVisible()
  await expect(page.locator('.leaflet-control-zoom')).toBeVisible()
  const size = await page.locator('.leaflet-container').evaluate((el) => [el.clientWidth, el.clientHeight])
  expect(size[0]).toBeGreaterThan(200)
  expect(size[1]).toBeGreaterThan(200)
  expect(crashed).toEqual([])
  await shot(page, 'ops-03-no-tiles')
  await context.close()
})
