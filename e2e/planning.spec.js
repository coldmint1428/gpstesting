// E2E: the planning fixes of 1 Nov (IS216 Week 10c), each written as the bug a planner hit.
//   1. A plan drawn by hand had no way to put a group on the map  -> "Place on map", then a tap.
//   2. A dropped badge jumped back before it settled               -> its drawn position is sampled after the drop.
//   3. The cursor could only be moved by Play                      -> drag along the ruler to any moment.
//   4. Areas on the drawing map could be dragged by accident       -> the padlock, stored on the shape.
//   5. "Banana Plan (3)" read as a third copy                      -> the picker names the frame count.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

let ev
let planId
let page
let context

test.beforeAll(async ({ browser, baseURL }) => {
  ev = await makeQaEvent('Planning')
  // A plan drawn by hand: two moments, nobody placed -- the state the bug report started from.
  const { sb } = await clientFor('root')
  const { data: plan, error } = await sb.rpc('plan_save', { p_event: ev.eventId, p_plan: { name: 'Hand plan' } })
  if (error) throw error
  planId = plan.id
  for (const t_s of [0, 60]) {
    const r = await sb.rpc('frame_save', { p_plan: planId, p_frame: { t_s } })
    if (r.error) throw r.error
  }
  context = await contextAs(browser, 'root', baseURL, { viewport: { width: 1400, height: 1100 } })
  page = await context.newPage()
})
test.afterAll(async () => {
  await context?.close()
})

/** Where a group's badge is drawn on the map right now (relative to the map, so a toolbar that wraps when a warning
 *  appears and moves the whole board down is not mistaken for the badge moving), or null. */
async function badgeAt(name) {
  const badge = page.locator('.pv-marker', { hasText: new RegExp('^' + name + '$') })
  if (!(await badge.count())) return null
  const [box, map] = await Promise.all([badge.first().boundingBox(), page.locator('.pv-map').boundingBox()])
  return box && map && { x: Math.round(box.x + box.width / 2 - map.x), y: Math.round(box.y + box.height / 2 - map.y) }
}

/** The positions a frame states, read from the database (not from the screen). */
async function positionsAt(t_s) {
  const { sb } = await clientFor('root')
  const { data } = await sb.rpc('plan_frames_list', { p_plan: planId })
  return (data || []).find((f) => f.t_s === t_s)?.positions || {}
}

test('the plan picker names the frame count, not a copy number', async () => {
  await page.goto(`/events/${ev.eventId}/timeline`)
  const picker = page.locator('select.pv-select')
  await expect(picker).toBeVisible()
  await expect(picker.locator('option:checked')).toHaveText(/Hand plan · 2 frames/)
})

test('a group with no position is placed with "Place on map" and one tap', async () => {
  const place = page.getByTestId('place-group')
  await expect(place).toHaveCount(2) // Alpha and Bravo: nobody is on the map yet
  await place.first().click()
  await expect(page.getByTestId('board-hint')).toContainText('Tap the map where')
  // Regression (found on the live site, 1 Nov): arming Place must not strip Leaflet's own classes off the map, or the
  // map is no longer clipped and spills over the toolbar and the inspector.
  await expect(page.locator('.pv-map')).toHaveClass(/leaflet-container/)
  await shot(page, 'plan-01-place-armed')

  const map = page.locator('.pv-map')
  const box = await map.boundingBox()
  await map.click({ position: { x: box.width * 0.45, y: box.height * 0.5 } })
  // The next unplaced group is armed straight away, so a new plan is one tap per group.
  await expect(page.getByTestId('place-group')).toHaveCount(1)
  await expect(page.getByTestId('place-group')).toHaveText(/Tap the map/)
  await map.click({ position: { x: box.width * 0.55, y: box.height * 0.5 } })
  await expect(page.getByTestId('place-group')).toHaveCount(0)
  await expect(page.locator('.pv-marker')).toHaveCount(2)
  await shot(page, 'plan-02-both-placed')

  const stated = await positionsAt(0)
  expect(Object.keys(stated)).toHaveLength(2) // written to the plan, not just drawn
})

test('a dropped badge stays where it was dropped (no jump back while it saves)', async () => {
  await page.locator('.pv-frame').nth(1).click() // +1:00
  await expect(page.getByTestId('board-hint')).toContainText('+1:00')
  const from = await badgeAt('A')
  expect(from).not.toBeNull()
  const to = { x: from.x + 60, y: from.y - 40 }
  const map = await page.locator('.pv-map').boundingBox() // the mouse works in page pixels
  await page.mouse.move(map.x + from.x, map.y + from.y)
  await page.mouse.down()
  for (let i = 1; i <= 10; i++) await page.mouse.move(map.x + from.x + 6 * i, map.y + from.y - 4 * i)
  await page.mouse.up()

  // Sample the badge every 50 ms for two seconds, through the write and the read-back: it must never be drawn
  // back near where it started.
  const samples = []
  for (let i = 0; i < 40; i++) {
    samples.push(await badgeAt('A'))
    await page.waitForTimeout(50)
  }
  const backHome = samples.filter((p) => p && Math.hypot(p.x - from.x, p.y - from.y) < 10)
  expect(backHome, 'samples drawn at the old place after the drop').toHaveLength(0)
  const last = samples[samples.length - 1]
  expect(Math.hypot(last.x - to.x, last.y - to.y)).toBeLessThan(6)

  const alpha = Object.values(await positionsAt(60))
  expect(alpha.length).toBeGreaterThan(0) // +1:00 now states Alpha's new place
  await shot(page, 'plan-03-dragged')
})

test('dragging along the ruler shows any moment, and Resume plays on from it', async () => {
  const ruler = page.getByTestId('scrub-ruler')
  const dots = page.locator('.pv-frame')
  // The map is framed once; letting the selection go (which a scrub does) must not resize it under the planner.
  const mapHeight = async () => Math.round((await page.locator('.pv-map').boundingBox()).height)
  const heightWithFrameOpen = await mapHeight()
  const a = await dots.nth(0).boundingBox()
  const b = await dots.nth(1).boundingBox()
  const rb = await ruler.boundingBox()
  const y = rb.y + rb.height / 2
  const x0 = a.x + a.width / 2
  const xMid = (a.x + a.width / 2 + b.x + b.width / 2) / 2
  await page.mouse.move(x0 + 2, y)
  await page.mouse.down()
  await page.mouse.move(xMid, y, { steps: 8 })
  await page.mouse.up()

  await expect(page.getByTestId('play-head')).toBeVisible()
  await expect(page.getByTestId('play-clock')).toHaveText(/^\+0:(2[5-9]|3[0-5])$/) // about half-way: +0:30
  await expect(page.getByTestId('board-hint')).toContainText('next +1:00')
  await expect(page.locator('.pv-marker.is-walking')).not.toHaveCount(0) // drawn between its two moments
  await expect(page.getByTestId('play')).toHaveText('Resume')
  expect(await mapHeight()).toBe(heightWithFrameOpen)
  await shot(page, 'plan-04-scrubbed')

  await page.getByTestId('play').click()
  await expect(page.getByTestId('play-clock')).toHaveText('+1:00', { timeout: 10_000 }) // from +0:30, not from +0:00
  await page.getByTestId('play-stop').click()
})

test('a locked area lets presses through, and the lock is stored on the shape', async () => {
  await page.goto(`/events/${ev.eventId}/map`)
  const draw = page.getByRole('button', { name: 'Draw areas' })
  await expect(draw).toBeVisible({ timeout: 20_000 })
  await draw.click()
  const map = page.locator('.bench-map')
  const box = await map.boundingBox()
  const at = (fx, fy) => ({ position: { x: box.width * fx, y: box.height * fy } })
  for (const [fx, fy] of [[0.3, 0.3], [0.7, 0.3], [0.7, 0.7], [0.3, 0.7], [0.3, 0.3]]) {
    await map.click(at(fx, fy))
  }
  await page.getByPlaceholder('e.g. Trees').fill('Lock test')
  await page.getByRole('button', { name: 'Save area' }).click()
  const lock = page.getByTestId('area-lock-Lock test')
  await expect(lock).toBeVisible()
  await expect(lock).toHaveAttribute('aria-pressed', 'false')

  // The outline as the map draws it, found by its size so the drawing helpers are left out.
  const outlineTakesPress = () =>
    page.evaluate(() => {
      const path = [...document.querySelectorAll('.bench-map .leaflet-overlay-pane path')]
        .map((p) => ({ p, r: p.getBoundingClientRect() }))
        .sort((x, y) => y.r.width * y.r.height - x.r.width * x.r.height)[0]
      const hit = document.elementFromPoint(path.r.left + path.r.width / 2, path.r.top + path.r.height / 2)
      return hit === path.p
    })
  expect(await outlineTakesPress()).toBe(true)

  await lock.click()
  await expect(lock).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByTestId('area-name-Lock test')).toBeDisabled()
  await expect.poll(outlineTakesPress).toBe(false) // a press on it now reaches the map underneath
  await shot(page, 'plan-05-area-locked')

  // Stored on the shape: a fresh page (as another planner would open it) shows it locked.
  await page.waitForTimeout(1500) // the bench writes when the gesture settles
  await page.reload()
  await expect(page.getByTestId('area-lock-Lock test')).toHaveAttribute('aria-pressed', 'true', { timeout: 20_000 })
  await page.getByTestId('area-lock-Lock test').click()
  await expect(page.getByTestId('area-lock-Lock test')).toHaveAttribute('aria-pressed', 'false')
})
