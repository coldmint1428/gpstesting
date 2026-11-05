// E2E — Owner: Hazel. Key feature: drawing the venue's areas on the map.
//
// The bench is where the venue is drawn, and a drawing is only worth anything if it is still there tomorrow and if the
// type it was given still means what it says -- the type is the colour on every map, and it is what a plan checks a
// group against ("did they walk through a No-Go area"). So this draws one area, calls it No-Go, reloads, and asks the
// list which group it belongs to. The lock on an area has its own test in planning.spec.js.
import { test, expect } from '@playwright/test'
import { contextAs } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.setTimeout(120_000)

let ev

test.beforeAll(async () => {
  ev = await makeQaEvent('Areas')
})

test('an area drawn as No-Go is still No-Go after a reload, and is listed under it', async ({ browser, baseURL }) => {
  const context = await contextAs(browser, 'root', baseURL, { viewport: { width: 1400, height: 1100 } })
  const page = await context.newPage()
  await page.goto(`/events/${ev.eventId}/map`)

  // Draw a square on the bench, the way a planner does: press, four corners, close on the first.
  const draw = page.getByRole('button', { name: 'Draw area' })
  await expect(draw).toBeVisible({ timeout: 30_000 })
  await draw.click()
  const map = page.locator('.bench-map')
  const box = await map.boundingBox()
  for (const [fx, fy] of [[0.25, 0.35], [0.45, 0.35], [0.45, 0.55], [0.25, 0.55], [0.25, 0.35]]) {
    await map.click({ position: { x: box.width * fx, y: box.height * fy } })
  }
  await page.getByPlaceholder('e.g. Trees').fill('No-go test')
  await page.getByRole('button', { name: 'Save area' }).click()

  // Give it a type. The row has to be open before its dropdown is live.
  const row = page.getByTestId('area-row-No-go test')
  await expect(row).toBeVisible({ timeout: 20_000 })
  await page.getByTestId('area-open-No-go test').click()
  await page.getByTestId('area-kind-select-No-go test').selectOption('no_go')
  // The heading counts its rows; the row itself is the sibling the heading sits over.
  await expect(page.getByTestId('area-group-no_go')).toContainText('No-Go (1)')
  await expect(page.getByTestId('area-row-No-go test')).toBeVisible()
  await shot(page, 'areas-01-typed')

  // The bench writes when the gesture settles, so a reload straight after the click would race it.
  await page.waitForTimeout(1500)
  await page.reload()

  // Still No-Go, and still under No-Go in the list rather than back under Zone -- which is what a planner reads to
  // check the plan against the venue.
  await expect(page.getByTestId('area-group-no_go')).toContainText('No-Go (1)', { timeout: 30_000 })
  await expect(page.getByTestId('area-row-No-go test')).toBeVisible()
  await shot(page, 'areas-02-after-reload')
  await context.close()
})
