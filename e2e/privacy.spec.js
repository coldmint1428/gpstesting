// E2E: adding people is by exact email only (068, 1 Nov). Like email to someone outside your organisation: nothing
// is suggested while typing, no list of accounts is ever returned, and nobody's email address is shown to you.
// Checked twice: against the database directly (what any client could ask), and on the People page.
import { test, expect } from '@playwright/test'
import { createClient } from '@supabase/supabase-js'
import { contextAs, clientFor, qa, SUPABASE_URL, ANON_KEY } from './support/session.js'
import { makeQaEvent } from './support/fixture.js'
import { shot } from './support/shots.js'

test.setTimeout(120_000)

test('the database finds one account by its exact email, and nothing by a name, a part or a pattern', async () => {
  const { sb } = await clientFor('planner')
  const find = async (p_email) => {
    const { data, error } = await sb.rpc('find_person_by_email', { p_email })
    expect(error).toBeNull()
    return data
  }
  const member = qa('member').email
  const exact = await find(member)
  expect(exact).toHaveLength(1)
  expect(exact[0].display_name).toBe('QA Member')
  expect(Object.keys(exact[0]).sort()).toEqual(['display_name', 'id']) // the email is never sent back
  expect(await find('  ' + member.toUpperCase() + ' ')).toHaveLength(1) // email ignores case
  expect(await find(member.split('@')[0])).toEqual([]) // the part before @
  expect(await find('QA Member')).toEqual([]) // a name
  expect(await find('qa')).toEqual([])
  expect(await find('%@planova.test')).toEqual([]) // a pattern
  expect(await find('nobody-' + Date.now() + '@planova.test')).toEqual([])
  expect(await find(qa('planner').email)).toEqual([]) // yourself
})

test('the old name search is gone, and nobody signed out can look anyone up', async () => {
  const { sb } = await clientFor('planner')
  const old = await sb.rpc('search_people', { p_term: 'QA' })
  expect(old.error, 'search_people should no longer exist').not.toBeNull()
  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } })
  const { error } = await anon.rpc('find_person_by_email', { p_email: qa('member').email })
  expect(error && error.message).toMatch(/permission denied/)
})

test('the People page adds a person by their email and shows no one else', async ({ browser, baseURL }) => {
  const ev = await makeQaEvent('Privacy')
  const context = await contextAs(browser, 'root', baseURL, { viewport: { width: 1280, height: 900 } })
  const page = await context.newPage()
  await page.goto(`/events/${ev.eventId}/people`)
  const email = page.getByTestId('add-email')
  const add = page.getByTestId('add-email-btn')
  await expect(email).toBeVisible()
  await expect(email).toHaveAttribute('type', 'email')
  await expect(email).toHaveAttribute('autocomplete', 'off')

  await email.fill('QA Out') // a name: cannot be submitted, and nothing appears under the field
  await expect(add).toBeDisabled()
  await expect(page.locator('[data-testid=add-found]')).toHaveCount(0)
  await email.fill('someone-' + Date.now() + '@planova.test')
  await add.click()
  await expect(page.getByTestId('add-none')).toContainText('No account uses that email')
  await shot(page, 'privacy-01-no-account')

  await email.fill(qa('outsider').email)
  await add.click()
  await expect(page.getByText(/QA Outsider was added to the event/)).toBeVisible({ timeout: 15_000 })
  await expect(email).toHaveValue('')
  await expect(page.getByText('QA Outsider').first()).toBeVisible()
  await shot(page, 'privacy-02-added')

  // Adding them twice says so, rather than failing quietly
  await email.fill(qa('outsider').email)
  await add.click()
  await expect(page.getByTestId('add-none')).toContainText('already in this event')
  await context.close()
})
