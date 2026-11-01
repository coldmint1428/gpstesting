// E2E: making an event with the four-step wizard, and deleting it again (root only).
import { test, expect } from '@playwright/test'
import { contextAs, clientFor, qa } from './support/session.js'
import { shot } from './support/shots.js'

test.setTimeout(120_000)

const local = (d) => new Date(d.getTime() + 8 * 3600_000).toISOString().slice(0, 16) // datetime-local, Singapore

test('root makes an event with people and a group, then deletes it', async ({ browser, baseURL }) => {
  const page = await (await contextAs(browser, 'root', baseURL)).newPage()
  await page.goto('/events/new')

  // Step 1: details, with the checks a person runs into
  await page.getByTestId('wiz-next').click()
  await expect(page.getByTestId('wiz-errors')).toBeVisible() // no name, no times
  await shot(page, 'wiz-01-errors')
  const name = 'QA-Wizard ' + Date.now().toString(36)
  await page.getByTestId('wiz-name').fill(name)
  await page.getByTestId('wiz-venue').fill('The Padang')
  const start = new Date(Date.now() + 24 * 3600_000)
  await page.getByTestId('wiz-start').fill(local(start))
  await page.getByTestId('wiz-end').fill(local(new Date(start.getTime() - 3600_000))) // ends before it starts
  await page.getByTestId('wiz-next').click()
  await expect(page.getByTestId('wiz-errors')).toBeVisible()
  await page.getByTestId('wiz-end').fill(local(new Date(start.getTime() + 5 * 3600_000)))
  await page.getByTestId('wiz-next').click()

  // Step 2: people, added by their exact email only (068, 1 Nov). Nothing is suggested while typing: a name or part
  // of an address cannot even be submitted, and a wrong address says so without naming anyone.
  const email = page.getByTestId('wiz-email')
  const add = page.getByTestId('wiz-email-add')
  await email.fill('QA Mem')
  await expect(add).toBeDisabled()
  await expect(page.locator('[data-testid=wiz-results]')).toHaveCount(0) // there is no list of accounts any more
  await email.fill('nobody-' + Date.now() + '@planova.test')
  await add.click()
  await expect(page.getByTestId('wiz-email-result')).toContainText('No account uses that email')
  for (const who of ['member', 'ic1']) {
    await email.fill(qa(who).email.toUpperCase()) // the match ignores case, as email does
    await add.click()
    await expect(page.getByTestId('wiz-email-result')).toContainText('added')
  }
  await expect(page.getByTestId('wiz-people')).toContainText('QA Member')
  await shot(page, 'wiz-02-people')
  await page.getByTestId('wiz-next').click()

  // Step 3: a group with both of them in it
  await page.getByTestId('wiz-group-name').fill('Gate Crew')
  await page.getByTestId('wiz-add-group').click()
  const groups = page.getByTestId('wiz-groups')
  await expect(groups).toContainText('Gate Crew')
  const addAll = groups.getByRole('button', { name: /Add all|Add everyone/ })
  if (await addAll.count()) await addAll.first().click()
  else for (let i = 0; i < 2; i++) await groups.getByRole('button', { name: 'Add', exact: true }).first().click()
  // A group with people needs an IC: the wizard refuses to go on, and says which group
  await page.getByTestId('wiz-next').click()
  await expect(page.getByText('"Gate Crew" needs at least one IC')).toBeVisible()
  await groups.locator('li, div', { hasText: /^QA Ic1/ }).getByLabel('IC').first().check().catch(async () => {
    await page.locator('label:has-text("IC")').nth(2).click()
  })
  await shot(page, 'wiz-03-groups', { fullPage: true })
  await page.getByTestId('wiz-next').click()

  // Step 4: preview and make it
  await expect(page.getByTestId('wiz-preview-details')).toContainText(name)
  await shot(page, 'wiz-04-preview', { fullPage: true })
  await page.getByTestId('wiz-confirm').click()
  await expect(page).toHaveURL(/\/events\/[0-9a-f-]{36}/, { timeout: 30_000 })
  const eventId = page.url().match(/events\/([0-9a-f-]{36})/)[1]

  const { sb } = await clientFor('root')
  const { data: gm } = await sb.from('group_members').select('user_id, groups(name)').eq('event_id', eventId)
  expect(gm.map((r) => r.groups.name)).toEqual(['Gate Crew', 'Gate Crew', 'Gate Crew']) // root, member, IC

  // Delete it from the overview
  await page.goto(`/events/${eventId}/overview`)
  await page.getByTestId('delete-event').click()
  const type = page.getByTestId('confirm-type')
  if (await type.isVisible({ timeout: 2000 }).catch(() => false)) await type.fill(name)
  await page.getByTestId('confirm-ok').click()
  await expect(page).toHaveURL(/\/events$/, { timeout: 20_000 })
  const { data: gone } = await sb.from('events').select('id').eq('id', eventId)
  expect(gone).toHaveLength(0)
  await shot(page, 'wiz-05-deleted')
})
