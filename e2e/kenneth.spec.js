// E2E: groups and users (Kenneth's part). Moving a person between groups is saved where it counts, the database, and
// the People page still fits a phone.
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent, ids } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })
test.setTimeout(120_000)

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
let ev
const contexts = []
async function as(browser, baseURL, role, options = { viewport: { width: 1360, height: 900 } }) {
  const context = await contextAs(browser, role, baseURL, options)
  contexts.push(context)
  return context.newPage()
}

test.beforeAll(async () => {
  ev = await makeQaEvent('People')
})
test.afterAll(async () => {
  for (const c of contexts) await c.close()
})

/** The group qa_member is in, read from the database (not from the screen). */
async function memberGroup() {
  const { sb } = await clientFor('root')
  const { member } = await ids('member')
  const { data } = await sb.from('group_members').select('group_id').eq('event_id', ev.eventId).eq('user_id', member).maybeSingle()
  return data ? data.group_id : null
}

test('a planner moves a person from one group to another, and the database agrees', async ({ browser, baseURL }) => {
  expect(await memberGroup()).toBe(ev.groups.Alpha)
  const page = await as(browser, baseURL, 'planner')
  await page.goto(`/events/${ev.eventId}/groups?group=${ev.groups.Alpha}`)
  const select = page.getByTestId('group-select-qa_member')
  await expect(select).toBeVisible({ timeout: 30_000 })
  await select.selectOption({ label: 'Bravo' })
  await expect(page.getByTestId('confirm-dialog')).toContainText('Bravo') // "Move QA Member to Bravo?"
  await page.getByTestId('confirm-ok').click()
  await expect(page.getByTestId('member-qa_member')).toHaveCount(0) // gone from Alpha's list
  await shot(page, 'people-01-moved')

  await expect.poll(memberGroup, { timeout: 15_000 }).toBe(ev.groups.Bravo)
  await page.goto(`/events/${ev.eventId}/groups?group=${ev.groups.Bravo}`)
  await expect(page.getByTestId('member-qa_member')).toBeVisible({ timeout: 30_000 })
})

test('the People page is still usable on a phone, with no sideways scroll', async ({ browser, baseURL }) => {
  const page = await as(browser, baseURL, 'root', PHONE)
  await page.goto(`/events/${ev.eventId}/people`)
  await expect(page.getByTestId('people-list')).toBeVisible({ timeout: 30_000 })
  const row = page.getByTestId('person-qa_member')
  await expect(row).toBeVisible()
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  )
  expect(overflow).toBeLessThanOrEqual(0)
  const box = await row.boundingBox()
  expect(box.x).toBeGreaterThanOrEqual(0)
  expect(box.x + box.width).toBeLessThanOrEqual(390) // the whole row is on the screen

  // The role filter is one dropdown on a phone, and it still filters
  await page.getByTestId('people-role-select').selectOption('ic')
  await expect(page.getByTestId('person-qa_ic1')).toBeVisible()
  await expect(page.getByTestId('person-qa_member')).toHaveCount(0)
  await shot(page, 'people-02-phone', { fullPage: true })
})
