// Integration tests: the homepage with a real router, a stand-in signed-in user and a mocked event service
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { reactive } from 'vue'
import { createRouter, createMemoryHistory } from 'vue-router'

const auth = reactive({ isLoggedIn: false, user: null, profile: null })
vi.mock('../../stores/auth', () => ({ useAuthStore: () => auth }))

const service = vi.hoisted(() => ({
  getMyEvents: vi.fn(),
  getLiveEventIds: vi.fn(),
  joinEventByCode: vi.fn(),
}))
vi.mock('../../services/eventService', () => service)

import HomeView from '../HomeView.vue'

const Blank = { template: '<div />' }
function makeRouter() {
  return createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', name: 'home', component: HomeView },
      { path: '/login', name: 'login', component: Blank },
      { path: '/signup', name: 'signup', component: Blank },
      { path: '/events', name: 'events', component: Blank },
      { path: '/events/new', name: 'event-new', component: Blank },
      { path: '/join/:code', name: 'join', component: Blank },
      { path: '/events/:id/:page?', name: 'event', component: Blank },
    ],
  })
}

async function mountHome() {
  const router = makeRouter()
  await router.push('/')
  await router.isReady()
  const wrapper = mount(HomeView, { global: { plugins: [router] } })
  await flushPromises()
  return { wrapper, router }
}

const event = (id, name, extra = {}) => ({ id, name, roles: ['planner'], isAdmin: false, isIC: false, startsAt: null, venue: 'Marina Bay', ...extra })

beforeEach(() => {
  Object.assign(auth, { isLoggedIn: false, user: null, profile: null })
  service.getMyEvents.mockReset()
  service.getLiveEventIds.mockReset()
  service.joinEventByCode.mockReset()
})

describe('HomeView for a visitor', () => {
  it('shows the landing page and loads no events', async () => {
    const { wrapper } = await mountHome()
    expect(wrapper.text()).toContain('Every group in the right place, right on time.')
    expect(service.getMyEvents).not.toHaveBeenCalled()
  })

  it('keeps only letters and digits in the event code, in capitals, up to six', async () => {
    const { wrapper } = await mountHome()
    const input = wrapper.find('[data-testid=visitor-join-code]')
    await input.setValue('9z8-gg!xq')
    expect(input.element.value).toBe('9Z8GGX')
    const filled = wrapper.findAll('.hm-box').map((b) => b.text())
    expect(filled).toEqual(['9', 'Z', '8', 'G', 'G', 'X'])
  })

  it('sends a visitor with a full code to the join page (which asks them to sign in)', async () => {
    const { wrapper, router } = await mountHome()
    await wrapper.find('[data-testid=visitor-join-code]').setValue('9Z8GGZ')
    await wrapper.find('[data-testid=visitor-join-code]').trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(router.currentRoute.value.name).toBe('join')
    expect(router.currentRoute.value.params.code).toBe('9Z8GGZ')
    expect(service.joinEventByCode).not.toHaveBeenCalled()
  })
})

describe('HomeView when signed in', () => {
  beforeEach(() => {
    Object.assign(auth, { isLoggedIn: true, user: { id: 'u1' }, profile: { first_name: 'Komin' } })
  })

  it('greets the person and shows one big live card, with any other live events as a list', async () => {
    service.getMyEvents.mockResolvedValue([event('a', 'NDP Rehearsal 3'), event('b', 'Route bench'), event('c', 'Ops bench'), event('d', 'Sports Day', { startsAt: '2099-01-02T01:00:00Z' })])
    service.getLiveEventIds.mockResolvedValue(['a', 'b', 'c'])
    const { wrapper } = await mountHome()

    expect(wrapper.text()).toContain('Komin')
    expect(wrapper.findAll('[data-testid=home-live]')).toHaveLength(1)
    expect(wrapper.find('[data-testid=home-live]').text()).toContain('NDP Rehearsal 3')
    const also = wrapper.find('[data-testid=home-also-live]')
    expect(also.text()).toContain('Also live · 2')
    expect(also.text()).toContain('Route bench')
    expect(also.text()).toContain('Ops bench')
    expect(wrapper.text()).toContain('Sports Day') // under Coming up
  })

  it('shows no Also live list when only one event is live', async () => {
    service.getMyEvents.mockResolvedValue([event('a', 'NDP Rehearsal 3')])
    service.getLiveEventIds.mockResolvedValue(['a'])
    const { wrapper } = await mountHome()
    expect(wrapper.findAll('[data-testid=home-live]')).toHaveLength(1)
    expect(wrapper.find('[data-testid=home-also-live]').exists()).toBe(false)
  })

  it('still shows the events when the live check fails', async () => {
    service.getMyEvents.mockResolvedValue([event('d', 'Sports Day', { startsAt: '2099-01-02T01:00:00Z' })])
    service.getLiveEventIds.mockRejectedValue(new Error('offline'))
    const { wrapper } = await mountHome()
    expect(wrapper.text()).toContain('Sports Day')
    expect(wrapper.find('[data-testid=home-live]').exists()).toBe(false)
  })

  it('joins with a full code and opens the event', async () => {
    service.getMyEvents.mockResolvedValue([])
    service.getLiveEventIds.mockResolvedValue([])
    service.joinEventByCode.mockResolvedValue('new-event-id')
    const { wrapper, router } = await mountHome()

    const btn = wrapper.find('[data-testid=home-join-btn]')
    expect(btn.attributes('disabled')).toBeDefined() // empty code
    await wrapper.find('[data-testid=home-join-code]').setValue('9z8ggz')
    expect(btn.attributes('disabled')).toBeUndefined()
    await btn.trigger('click')
    await flushPromises()

    expect(service.joinEventByCode).toHaveBeenCalledWith('9Z8GGZ')
    expect(router.currentRoute.value.name).toBe('event')
    expect(router.currentRoute.value.params.id).toBe('new-event-id')
  })

  it('shows the database message when the code is wrong', async () => {
    service.getMyEvents.mockResolvedValue([])
    service.getLiveEventIds.mockResolvedValue([])
    service.joinEventByCode.mockRejectedValue(new Error('No event has that code'))
    const { wrapper } = await mountHome()
    await wrapper.find('[data-testid=home-join-code]').setValue('ZZZZZZ')
    await wrapper.find('[data-testid=home-join-btn]').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('No event has that code')
  })
})
