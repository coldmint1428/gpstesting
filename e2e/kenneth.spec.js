// E2E — Owner: Kenneth. Key feature: managing the event's groups and people.
//
// The two screens an organiser lives in before an event: who is in which group, and who is in the event at all. Both
// are tested against the database rather than the screen only -- the page is not the register, and a move that looks
// right and was never written is exactly the failure these pages exist to avoid. The second test is the same page on
// the phone a planner actually carries.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.setTimeout(120_000)

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }

let ev

test.beforeAll(async () => {
  ev = await makeQaEvent('People')
})

test('a planner moves a person from one group to another, and the database agrees', async ({ browser, baseURL }) => {
  const page = await (await contextAs(browser, 'root', baseURL, { viewport: { width: 1280, height: 900 } })).newPage()
  await page.goto(`/events/${ev.eventId}/groups`)

  // Open the group qa_member is in, and move them to the other one.
  await page.getByTestId('group-card-Alpha').click()
  const select = page.getByTestId('group-select-qa_member')
  await expect(select).toBeVisible({ timeout: 30_000 })
  await select.selectOption({ label: 'Bravo' })
  // Moving somebody asks first: "Move QA Member to Bravo?", because it changes what their phone sees.
  await page.getByTestId('confirm-ok').click()
  await shot(page, 'people-01-moved')

  // Read it back from the database, as another planner opening the page would.
  const { sb } = await clientFor('root')
  await expect
    .poll(async () => {
      const { data } = await sb.from('group_members').select('groups(name)').eq('event_id', ev.eventId).eq('user_id', (await clientFor('member')).user.id)
      return (data || []).map((r) => r.groups?.name)
    })
    .toEqual(['Bravo'])
  await expect(page.getByTestId('group-view-Alpha').or(page.getByTestId('group-card-Alpha'))).toBeVisible()
})

test('the People page is still usable on a phone, with no sideways scroll', async ({ browser, baseURL }) => {
  const context = await contextAs(browser, 'planner', baseURL, PHONE)
  const page = await context.newPage()
  await page.goto(`/events/${ev.eventId}/people`)

  // The roster is there, and the person's own role column is reachable rather than pushed off the edge.
  await expect(page.getByTestId('people-list')).toBeVisible({ timeout: 30_000 })
  const row = page.getByTestId('person-qa_member')
  await expect(row).toBeVisible()
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  )
  expect(overflow).toBeLessThanOrEqual(0) // nothing to scroll to the side for
  await shot(page, 'people-02-phone')
  await context.close()
})
