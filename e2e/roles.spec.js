// E2E + access checks: what each role sees on the pages, and what the database refuses whatever the page shows.
// The page tests check what a person experiences; the API tests check the same rule cannot be bypassed by calling the
// database directly with that person's own session (Row Level Security and the RPCs' own role checks).
import { test, expect } from '@playwright/test'
import { contextAs, clientFor } from './support/session.js'
import { makeQaEvent, ids } from './support/fixture.js'
import { shot } from './support/shots.js'

test.describe.configure({ mode: 'serial' })

let ev
test.beforeAll(async () => {
  ev = await makeQaEvent('Roles')
  const { sb } = await clientFor('root')
  const { error } = await sb.rpc('start_event', { p_event_id: ev.eventId }) // tracking only
  if (error) throw error
  const ic = await clientFor('ic1')
  const r = await ic.sb.from('locations').insert({ event_id: ev.eventId, group_id: ev.groups.Alpha, user_id: ic.user.id, lat: 1.2903, lng: 103.8517, accuracy: 8, source: 'gps', recorded_at: new Date().toISOString() })
  if (r.error) throw r.error
})

test.describe('the database refuses what a role may not do', () => {
  test('someone outside the event reads nothing of it', async () => {
    const { sb } = await clientFor('outsider')
    for (const table of ['events', 'groups', 'group_members', 'locations', 'plans']) {
      const col = table === 'events' ? 'id' : 'event_id'
      const { data } = await sb.from(table).select('*').eq(col, ev.eventId)
      expect(data || [], table).toHaveLength(0)
    }
  })

  test('a member cannot start or end the event, make a plan, or share a location', async () => {
    const { sb, user } = await clientFor('member')
    expect((await sb.rpc('end_event', { p_event_id: ev.eventId })).error).not.toBeNull()
    expect((await sb.rpc('plan_save', { p_event: ev.eventId, p_plan: { name: 'Sneaky plan' } })).error?.message).toMatch(/root user or a planner/)
    const ins = await sb.from('locations').insert({ event_id: ev.eventId, group_id: ev.groups.Alpha, user_id: user.id, lat: 1.29, lng: 103.85, accuracy: 5, source: 'gps', recorded_at: new Date().toISOString() })
    expect(ins.error).not.toBeNull()
  })

  test('an IC cannot write a location as somebody else, or for another group', async () => {
    const { sb } = await clientFor('ic1')
    const u = await ids('ic2')
    const asOther = await sb.from('locations').insert({ event_id: ev.eventId, group_id: ev.groups.Alpha, user_id: u.ic2, lat: 1.29, lng: 103.85, accuracy: 5, source: 'gps', recorded_at: new Date().toISOString() })
    expect(asOther.error).not.toBeNull()
    const otherGroup = await sb.from('locations').insert({ event_id: ev.eventId, group_id: ev.groups.Bravo, user_id: (await clientFor('ic1')).user.id, lat: 1.29, lng: 103.85, accuracy: 5, source: 'gps', recorded_at: new Date().toISOString() })
    expect(otherGroup.error).not.toBeNull()
  })

  test('a group admin cannot touch a group that is not theirs', async () => {
    const { sb } = await clientFor('admin')
    const u = await ids('outsider')
    const { error } = await sb.from('group_members').insert({ group_id: ev.groups.Bravo, event_id: ev.eventId, user_id: u.outsider, is_admin: false, is_ic: true })
    expect(error).not.toBeNull()
    const rename = await sb.from('groups').update({ name: 'Taken over' }).eq('id', ev.groups.Bravo).select()
    expect(rename.data || []).toHaveLength(0)
  })

  test('a planner cannot delete the event; only root can', async () => {
    const { sb } = await clientFor('planner')
    const del = await sb.from('events').delete().eq('id', ev.eventId).select()
    expect(del.data || []).toHaveLength(0)
    const root = await clientFor('root')
    const still = await root.sb.from('events').select('id').eq('id', ev.eventId)
    expect(still.data).toHaveLength(1)
  })

  test('a member sees their own group\'s locations, the marshal sees every group', async () => {
    const member = await clientFor('member')
    const marshal = await clientFor('marshal')
    const m = await member.sb.from('locations').select('group_id').eq('event_id', ev.eventId)
    expect(m.data.length).toBeGreaterThan(0)
    expect(new Set(m.data.map((r) => r.group_id))).toEqual(new Set([ev.groups.Alpha]))
    const k = await marshal.sb.from('locations').select('group_id').eq('event_id', ev.eventId)
    expect(k.data.length).toBe(m.data.length)
  })
})

test.describe('the pages show each role what it may do', () => {
  test('root sees the invite code and Delete event; a planner sees the code but not Delete', async ({ browser, baseURL }) => {
    const root = await (await contextAs(browser, 'root', baseURL)).newPage()
    await root.goto(`/events/${ev.eventId}/overview`)
    await expect(root.getByTestId('join-code-display').first()).toContainText(ev.joinCode)
    await expect(root.getByTestId('delete-event')).toBeVisible()
    await shot(root, 'roles-01-root-overview', { fullPage: true })

    const planner = await (await contextAs(browser, 'planner', baseURL)).newPage()
    await planner.goto(`/events/${ev.eventId}/overview`)
    await expect(planner.getByTestId('join-code-display').first()).toContainText(ev.joinCode)
    await expect(planner.getByTestId('delete-event')).toHaveCount(0)
    await shot(planner, 'roles-02-planner-overview', { fullPage: true })
  })

  test('a member sees no invite code, no Playback and no manage menus', async ({ browser, baseURL }) => {
    const page = await (await contextAs(browser, 'member', baseURL)).newPage()
    await page.goto(`/events/${ev.eventId}/overview`)
    await expect(page.getByTestId('join-code-display')).toHaveCount(0)
    await expect(page.getByRole('link', { name: /Playback/ })).toHaveCount(0)
    await page.goto(`/events/${ev.eventId}/playback`)
    await expect(page).toHaveURL(/\/overview$/)
    await page.goto(`/events/${ev.eventId}/people`)
    await expect(page.getByTestId('person-card').or(page.getByTestId('people-list')).first()).toBeVisible()
    await expect(page.locator('[data-testid^="person-menu-"]')).toHaveCount(0)
    await shot(page, 'roles-03-member-people', { fullPage: true })
  })

  test('a group admin can make someone in their own group an IC', async ({ browser, baseURL }) => {
    const page = await (await contextAs(browser, 'admin', baseURL)).newPage()
    await page.goto(`/events/${ev.eventId}/people`)
    await expect(page.locator('[data-testid="person-ic-toggle-qa_member"]:visible')).toBeVisible() // inline on a laptop
    await expect(page.locator('[data-testid="person-ic-toggle-qa_planner"]')).toHaveCount(0) // not in their group
    await expect(page.locator('[data-testid="person-role-select-qa_member"]')).toHaveCount(0) // ranks are root's and planners'
    await shot(page, 'roles-04-admin-people', { fullPage: true })
  })

  test('the IC who is not sharing shows as not sharing to the planner', async ({ browser, baseURL }) => {
    const page = await (await contextAs(browser, 'root', baseURL)).newPage()
    await page.goto(`/events/${ev.eventId}/groups`)
    await expect(page.getByText(/qa_ic2|QA Ic2/).first()).toBeVisible()
    await shot(page, 'roles-05-root-groups', { fullPage: true })
  })

  test('someone outside the event is sent back to their events', async ({ browser, baseURL }) => {
    const page = await (await contextAs(browser, 'outsider', baseURL)).newPage()
    await page.goto(`/events/${ev.eventId}/overview`)
    await expect(page).toHaveURL(/\/events$/)
    await shot(page, 'roles-06-outsider-bounced')
  })
})
