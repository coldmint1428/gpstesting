import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import PolygonTestView from '../views/PolygonTestView.vue'
import LoginView from '../views/LoginView.vue'
import EventsView from '../views/EventsView.vue'
import EventView from '../views/EventView.vue'
import JoinView from '../views/JoinView.vue'
import GpsTestView from '../views/GpsTestView.vue'
import { useAuthStore } from '../stores/auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'home', component: HomeView },
    { path: '/polygon', name: 'polygon', component: PolygonTestView },
    { path: '/login', name: 'login', component: LoginView },

    // Pages below need a logged-in user (meta.requiresAuth)
    { path: '/events', name: 'events', component: EventsView, meta: { requiresAuth: true } },
    { path: '/events/:id', name: 'event', component: EventView, props: true, meta: { requiresAuth: true } },
    {
      path: '/events/:id/share',
      name: 'share',
      component: GpsTestView,
      props: true,
      meta: { requiresAuth: true },
    },
    // Invite link / QR code target: joins the event, then opens it
    { path: '/join/:code', name: 'join', component: JoinView, props: true, meta: { requiresAuth: true } },

    // Old test page address now goes to the events list
    { path: '/gps', redirect: '/events' },
  ],
})

// Send logged-out users to the login page, then back to where they were going
router.beforeEach(async (to) => {
  if (!to.meta.requiresAuth) return true

  const auth = useAuthStore()
  await auth.init()
  if (!auth.isLoggedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  return true
})

export default router
