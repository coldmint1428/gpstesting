// E2E: logging out from an event page (3 Nov). Bug report: "when the user logs out it shows a notification that they
// are not a member of the event". Logging out also leaves the page without a membership, and the event page took that
// for being removed. A planner really removing someone still tells them (roles.spec covers what they may see).
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'

let ev

test.beforeAll(async () => {
  ev = await makeQaEvent('Logout')
})
test.afterAll(async () => {
  const { sb } = await clientFor('root')
  await sb.rpc('delete_event', { p_event_id: ev.eventId })
})

test('logging out from an event page goes to log in, with no "no longer a member" message', async ({ browser, baseURL }) => {
  const context = await contextAs(browser, 'admin', baseURL)
  const page = await context.newPage()
  await page.goto(`/events/${ev.eventId}/overview`)
  await expect(page.getByTestId('event-name').first()).toBeVisible({ timeout: 30_000 })
  // Every message shown from here on, however briefly: a toast can come and go before the log in page has loaded
  await page.evaluate(() => {
    window.__seen = []
    new MutationObserver(() => {
      const text = document.body.innerText
      if (text.includes('no longer a member') && !window.__seen.length) window.__seen.push(text)
    }).observe(document.body, { subtree: true, childList: true, characterData: true })
  })
  await page.getByTestId('nav-account').click()
  await page.getByTestId('logout-btn').click()
  await expect(page).toHaveURL(/\/login/, { timeout: 15_000 })
  await page.waitForTimeout(1500) // the membership watcher runs as the session goes
  expect(await page.evaluate(() => window.__seen.length), 'a "no longer a member" message was shown').toBe(0)
  await context.close()
})
