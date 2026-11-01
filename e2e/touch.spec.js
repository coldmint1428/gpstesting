// E2E: the Timeline on a phone, with real touch input (1 Nov, found on an iPhone and an Android phone).
//   1. A tap a little off a frame dot (a finger, not a cursor) must open that frame, not clear the selection.
//   2. Swiping the strip to scroll it must not stack "No frame in that stretch" toasts.
//   3. A plan with no frames says what to do first, instead of "Pick a frame on the time bar below".
// Touches go through Chrome's DevTools protocol (Input.dispatchTouchEvent), so the browser itself decides between a
// tap and a scroll, the way a phone does.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }
let ev
let planId
let page
let context
let cdp

test.beforeAll(async ({ browser, baseURL }) => {
  ev = await makeQaEvent('Touch')
  const { sb } = await clientFor('root')
  const { data: plan } = await sb.rpc('plan_save', { p_event: ev.eventId, p_plan: { name: 'Empty plan' } })
  planId = plan.id
  context = await contextAs(browser, 'root', baseURL, PHONE)
  page = await context.newPage()
  cdp = await context.newCDPSession(page)
})
test.afterAll(async () => {
  await context?.close()
})

/** One finger: down at a point, along a path, up. */
async function touch(points) {
  const [first, ...rest] = points
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [first] })
  for (const p of rest) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [p] })
    await page.waitForTimeout(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
}

test('a plan with no frames says to add the first one', async () => {
  await page.goto(`/events/${ev.eventId}/timeline`)
  await expect(page.getByTestId('plan-no-frames')).toBeVisible()
  await expect(page.getByTestId('board-hint')).toContainText('This plan has no moments yet')
  await expect(page.getByTestId('board-hint')).not.toContainText('Pick a frame')
  await shot(page, 'touch-01-empty-plan', { fullPage: true })
  await page.getByTestId('frame-add-first').click()
  await expect(page.locator('.pv-frame')).toHaveCount(1)
})

test('a finger a little off a frame dot still opens that frame', async () => {
  const { sb } = await clientFor('root')
  for (const t_s of [60, 120]) await sb.rpc('frame_save', { p_plan: planId, p_frame: { t_s } })
  await page.reload()
  await expect(page.locator('.pv-frame')).toHaveCount(3)
  const dot = page.locator('.pv-frame').nth(2)
  await dot.scrollIntoViewIfNeeded()
  const box = await dot.boundingBox()
  // 14 px below the 12 px dot and 10 px to its side: where a thumb lands, not where a cursor would
  await touch([{ x: box.x + box.width / 2 + 10, y: box.y + 12 + 14 }])
  await expect(page.locator('.pv-frame').nth(2)).toHaveClass(/is-selected/)
  await expect(page.locator('#pv-frame-time')).toHaveValue('+2:00')
  await shot(page, 'touch-02-tapped')
})

test('swiping the strip scrolls it and says nothing', async () => {
  const strip = page.locator('.pv-track')
  const box = await strip.boundingBox()
  const y = box.y + box.height - 20
  for (let i = 0; i < 6; i++) {
    const path = []
    for (let s = 0; s <= 10; s++) path.push({ x: box.x + box.width - 30 - s * 20, y })
    await touch(path)
  }
  await page.waitForTimeout(500)
  await expect(page.getByText('No frame in that stretch')).toHaveCount(0)
  await expect(page.locator('.pv-sweep')).toHaveCount(0) // no grey sweep band left on the strip
  // The open frame is still open: a scroll is not a click on empty bar
  await expect(page.locator('#pv-frame-time')).toHaveValue('+2:00')
  await shot(page, 'touch-03-swiped')
})

test('a tap on empty strip far from any frame lets the selection go', async () => {
  const strip = page.locator('.pv-track-inner')
  await page.locator('.pv-track').evaluate((el) => (el.scrollLeft = 0))
  const box = await strip.boundingBox()
  const last = await page.locator('.pv-frame').nth(2).boundingBox()
  await touch([{ x: Math.min(last.x + 160, box.x + 360), y: last.y + 30 }])
  await expect(page.locator('.pv-frame.is-selected')).toHaveCount(0)
})
