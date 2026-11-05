// E2E: venue areas on the map (Hazel's part). An area's type is what it is: drawn as No-Go, it is saved as No-Go,
// comes back as No-Go after a reload, and is listed under No-Go.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

let ev
let context
let page

test.beforeAll(async ({ browser, baseURL }) => {
  ev = await makeQaEvent('Areas')
  context = await contextAs(browser, 'root', baseURL, { viewport: { width: 1400, height: 1100 } })
  page = await context.newPage()
})
test.afterAll(async () => {
  await context?.close()
})

test('an area drawn as No-Go is still No-Go after a reload, and is listed under it', async () => {
  await page.goto(`/events/${ev.eventId}/map`)
  const draw = page.getByRole('button', { name: 'Draw area' })
  await expect(draw).toBeVisible({ timeout: 30_000 })
  await draw.click()
  const map = page.locator('.bench-map')
  const box = await map.boundingBox()
  const at = (fx, fy) => ({ position: { x: box.width * fx, y: box.height * fy } })
  for (const [fx, fy] of [[0.35, 0.35], [0.65, 0.35], [0.65, 0.65], [0.35, 0.65], [0.35, 0.35]]) {
    await map.click(at(fx, fy))
  }
  await page.getByPlaceholder('e.g. Trees').fill('Closed lawn')
  await page.getByTestId('area-kind').selectOption('no_go')
  await page.getByRole('button', { name: 'Save area' }).click()
  await expect(page.getByTestId('area-row-Closed lawn')).toBeVisible()
  await expect(page.getByTestId('area-group-no_go')).toHaveText('No-Go (1)')
  await shot(page, 'area-01-no-go-drawn')

  // Stored on the shape: a fresh page reads it back as No-Go
  await page.waitForTimeout(1500) // the bench writes when the gesture settles
  await page.reload()
  await expect(page.getByTestId('area-group-no_go')).toHaveText('No-Go (1)', { timeout: 20_000 })
  await expect(page.getByTestId('area-group-no_go').locator('..').getByTestId('area-row-Closed lawn')).toBeVisible()
  await expect(page.getByTestId('area-group-zone')).toHaveCount(0)
  await shot(page, 'area-02-no-go-after-reload')
})
