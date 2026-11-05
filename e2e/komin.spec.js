// E2E: the live operations dashboard (Komin's part). The Overview counts the event for the people who run it, and the
// live map stays a working map even when the OneMap basemap does not answer.
import { test, expect } from '@playwright/test'
import { contextAs } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

let ev
const contexts = []
async function as(browser, baseURL, role, options = { viewport: { width: 1360, height: 900 } }) {
  const context = await contextAs(browser, role, baseURL, options)
  contexts.push(context)
  return context.newPage()
}

test.beforeAll(async () => {
  ev = await makeQaEvent('Ops') // root, a planner, and Alpha's four: 6 people in 2 groups
})
test.afterAll(async () => {
  for (const c of contexts) await c.close()
})

test('the dashboard counts the event, and a member is shown neither the count nor the invite code', async ({ browser, baseURL }) => {
  const planner = await as(browser, baseURL, 'planner')
  await planner.goto(`/events/${ev.eventId}/overview`)
  await expect(planner.getByTestId('overview')).toBeVisible({ timeout: 30_000 })
  await expect(planner.getByTestId('overview')).toContainText('6 in 2 groups')
  await expect(planner.getByTestId('join-code-display')).toHaveText(ev.joinCode)
  await shot(planner, 'ops-01-planner-dashboard')

  const member = await as(browser, baseURL, 'member')
  await member.goto(`/events/${ev.eventId}/overview`)
  await expect(member.getByTestId('overview')).toBeVisible({ timeout: 30_000 })
  await expect(member.getByTestId('overview')).toContainText('Alpha') // their own group
  await expect(member.getByTestId('overview')).not.toContainText('in 2 groups')
  await expect(member.getByTestId('join-code-display')).toHaveCount(0)
  await expect(member.getByTestId('leave-event')).toBeVisible()
  await shot(member, 'ops-02-member-overview')
})

test('the live map keeps working when the OneMap tiles do not load', async ({ browser, baseURL }) => {
  const page = await as(browser, baseURL, 'planner')
  let refused = 0
  await page.route(/onemap\.gov\.sg\/maps\/tiles\//, (route) => {
    refused++
    return route.abort('failed')
  })
  await page.goto(`/events/${ev.eventId}/live`)
  await expect(page.getByTestId('live-map')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('.leaflet-container')).toBeVisible()
  await expect(page.locator('.leaflet-control-zoom')).toBeVisible()
  const size = await page.locator('.leaflet-container').evaluate((el) => [el.clientWidth, el.clientHeight])
  expect(size[0]).toBeGreaterThan(200) // laid out as a map, not collapsed to nothing without its tiles
  expect(size[1]).toBeGreaterThan(200)
  await expect.poll(() => refused).toBeGreaterThan(0) // the tiles really were asked for, and refused

  // Still a map: zooming in works without a single tile
  const zoomIn = page.locator('.leaflet-control-zoom-in')
  await zoomIn.click()
  await expect(page.getByTestId('live-map')).toBeVisible()
  await shot(page, 'ops-03-live-map-no-tiles')
})
