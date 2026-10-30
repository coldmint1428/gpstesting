import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import PolygonTestView from '../views/PolygonTestView.vue'
import LoginView from '../views/LoginView.vue'
import SignupView from '../views/SignupView.vue'
import ProfileView from '../views/ProfileView.vue'
import EventsView from '../views/EventsView.vue'
import EventView from '../views/EventView.vue'
import CreateEventView from '../views/CreateEventView.vue'
import JoinView from '../views/JoinView.vue'
import GpsTestView from '../views/GpsTestView.vue'
import PhoneCheckView from '../views/PhoneCheckView.vue'
import MeView from '../views/MeView.vue'
import { isNativeApp } from '../lib/platform'
import { useAuthStore } from '../stores/auth'
import { fetchMembership } from '../services/memberService'
import { PAGES, PAGE_LABEL, canView, viewRole, defaultPage } from '../utils/permissions'
import { toast } from '../composables/useNotify'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    // The phone app opens on My events: the home page is a list of test pages, useful on the website only
    { path: '/', name: 'home', component: HomeView, beforeEnter: () => (isNativeApp ? { name: 'events' } : true) },
    // The DEMO drawing bench (no event). Zones are drawn in each event's Zones tab now, so this page is
    // out of the menu and only reachable on local dev (npm run dev) -- for the teammate's editor tests and
    // tools/bench_harness.mjs. On the deployed site it redirects to the events list. To be removed once
    // those tests use an event's Zones tab.
    {
      path: '/polygon',
      name: 'polygon',
      component: PolygonTestView,
      meta: { requiresAuth: true },
      beforeEnter: () => (import.meta.env.DEV ? true : { name: 'events' }),
    },
    // Signed-in users visiting these go to their events (meta.guestOnly)
    { path: '/login', name: 'login', component: LoginView, meta: { guestOnly: true } },
    { path: '/signup', name: 'signup', component: SignupView, meta: { guestOnly: true } },

    // Pages below need a logged-in user (meta.requiresAuth)
    { path: '/events', name: 'events', component: EventsView, meta: { requiresAuth: true } },
    // The 4-step "Create an event" wizard
    { path: '/events/new', name: 'event-new', component: CreateEventView, meta: { requiresAuth: true } },
    { path: '/profile', name: 'profile', component: ProfileView, meta: { requiresAuth: true } },
    // One event, one page of it: /events/:id/timeline, /events/:id/people ... (src/utils/permissions.js decides who sees
    // which). One route, so moving between pages keeps the same EventView: the live map and the show keep running.
    // Without a page it opens the role's default page.
    {
      path: '/events/:id/:page(' + PAGES.join('|') + ')?',
      name: 'event',
      component: EventView,
      props: true,
      meta: { requiresAuth: true },
    },
    {
      path: '/events/:id/share',
      name: 'share',
      component: GpsTestView,
      props: true,
      meta: { requiresAuth: true },
    },
    // "Set up sharing": the phone settings sharing needs (?event=&group=&share=1)
    { path: '/check-phone', name: 'phone-check', component: PhoneCheckView, meta: { requiresAuth: true } },
    // Phone app: the person, their sharing and sign-out (the website has these in its top bar)
    { path: '/me', name: 'me', component: MeView, meta: { requiresAuth: true } },
    // Invite link / QR code target: joins the event, then opens it
    { path: '/join/:code', name: 'join', component: JoinView, props: true, meta: { requiresAuth: true } },

    // Old test page address now goes to the events list
    { path: '/gps', redirect: '/events' },

    // Any other address (an old or mistyped link) used to show a blank white page - on the phone app with no address
    // bar and no tabs, so there was no way back. Go to the home page instead (My events on the phone).
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

// Send logged-out users to the login page, then back to where they were going
router.beforeEach(async (to, from) => {
  const auth = useAuthStore()
  if (to.meta.guestOnly) {
    await auth.init()
    return auth.isLoggedIn ? to.query.redirect || '/' : true
  }
  if (!to.meta.requiresAuth) return true

  await auth.init()
  if (!auth.isLoggedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  if (to.name === 'event') return eventPageGuard(to, from)
  return true
})

// Members only, and only the pages their role may view (the database limits what they can read anyway)
async function eventPageGuard(to, from) {
  const id = to.params.id
  let membership
  try {
    // fresh when arriving from outside the event (I may have been added or removed since)
    membership = await fetchMembership(id, { fresh: from.name !== 'event' || from.params.id !== id })
  } catch {
    return true // offline or the server failed: the page shows its own error
  }
  if (!membership) {
    toast("You don't have access to this event.", 'danger')
    return { name: 'events' }
  }
  const role = viewRole(membership)
  const page = to.params.page
  if (!page) {
    // a "tap to share" / "next move" notification opens the live view
    const landing = to.query.share || to.query.next ? 'live' : defaultPage(role, membership.live)
    return { name: 'event', params: { id, page: landing }, query: to.query, replace: true }
  }
  if (!canView(page, role) || (page === 'simulator' && !membership.is_simulation)) {
    toast('The ' + PAGE_LABEL[page] + " page isn't available for your role in this event.", 'warning')
    return { name: 'event', params: { id, page: 'overview' }, replace: true }
  }
  return true
}

export default router
