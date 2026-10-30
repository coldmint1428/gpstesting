// E2E: what a person sees when the server is slow or failing (the stress test's overload, made on purpose here by
// holding one of the browser's requests back with page.route).
import { test, expect } from '@playwright/test'
import { contextAs } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.setTimeout(90_000)

test('regression QA-09: an event opened while the server does not answer shows Loading, then the page, not a blank screen', async ({ browser, baseURL }) => {
  const ev = await makeQaEvent('Slow')
  const page = await (await contextAs(browser, 'member', baseURL)).newPage()
  await page.goto('/events')
  await page.getByPlaceholder('Search events').fill('QA-Slow')
  const row = page.getByText(/^QA-Slow /).last() // the newest (the laptop list has no row test id; the phone list does)
  await expect(row).toBeVisible()
  // From here the membership check the event guard waits on never answers
  await page.route('**/rest/v1/rpc/my_event_membership', () => {})
  await row.click()
  await expect(page.getByTestId('nav-loading')).toBeVisible({ timeout: 5_000 })
  await shot(page, 'res-01-loading')
  // After 10 s the guard lets the page open; the event's own reads are not held back, so it shows
  await expect(page.getByTestId('nav-loading')).toBeHidden({ timeout: 20_000 })
  await expect(page.getByRole('heading', { level: 1 })).toContainText('QA-Slow', { timeout: 20_000 })
  await shot(page, 'res-02-opened')
})
