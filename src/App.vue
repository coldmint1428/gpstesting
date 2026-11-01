<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { RouterLink, RouterView, useRouter } from 'vue-router'
import { useAuthStore } from './stores/auth'
import { useLocationTracker } from './composables/useLocationTracker'
import { syncStartReminders, listenForReminderTaps } from './composables/useStartReminders'
import { enablePush } from './composables/usePushNotifications'
import NotifyHost from './components/NotifyHost.vue'
import PhoneTabBar from './components/PhoneTabBar.vue'
import { isNativeApp } from './lib/platform'
import { pendingNavigation } from './router' // QA-09: the bar while a page change waits on the server
import KLogo from './components/kinetic/KLogo.vue'

const auth = useAuthStore()
const router = useRouter()
const tracker = useLocationTracker() // shared by every page

// Phone app: the screens outside an event share one set of bottom tabs (inside an event the event page draws its
// own, which follow the role). The website keeps its top bar instead.
const APP_TABS = [
  { key: 'events', label: 'Events', icon: 'events', to: { name: 'events' } },
  { key: 'phone-check', label: 'Phone', icon: 'phone', to: { name: 'phone-check' } },
  { key: 'me', label: 'Me', icon: 'me', to: { name: 'me' } },
]
const appTab = computed(() => {
  const name = String(router.currentRoute.value.name || '')
  return APP_TABS.some((t) => t.key === name) ? name : ''
})

onMounted(async () => {
  // Phone app: start Transistorsoft while the login is checked, not after (both take a moment)
  tracker.prepare()
  await auth.init()
  // Phone app: start Transistorsoft (must happen on every launch) and show tracking
  // that is still running from before. Does nothing in a normal browser.
  await tracker.resume(auth.isLoggedIn)
  // Phone app: "Event started - tap to share" reminders (taps open the event and start sharing)
  listenForReminderTaps(router)
  watch(
    () => auth.isLoggedIn,
    async (loggedIn) => {
      if (!loggedIn) {
        // Signed out in another tab (the login is shared by the browser): don't leave this tab
        // showing a page that needs a login, with data it can no longer load.
        const here = router.currentRoute.value
        if (here.meta.requiresAuth) router.replace({ name: 'login', query: { redirect: here.fullPath } })
        return
      }
      await enablePush(router) // server pushes, reach a closed app (Firebase)
      syncStartReminders(auth.user.id, tracker.sharingEventId.value) // phone alarms (used when push isn't set up)
    },
    { immediate: true },
  )
})

// The top bar: which page it is on, and whether that page draws its own instead
const routeName = computed(() => String(router.currentRoute.value.name || ''))
const showTopBar = computed(() => {
  const name = routeName.value
  if (name === 'login' || name === 'signup') return false
  return !(name === 'home' && !auth.isLoggedIn)
})
const initials = computed(() => {
  const p = auth.profile || {}
  const name = String(p.display_name || p.username || '')
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('')
})
// The account menu closes when you click away
const meOpen = ref(false)
const meWrap = ref(null)
function closeMe(event) {
  if (meOpen.value && meWrap.value && !meWrap.value.contains(event.target)) meOpen.value = false
}
onMounted(() => document.addEventListener('pointerdown', closeMe))
onBeforeUnmount(() => document.removeEventListener('pointerdown', closeMe))

async function logout() {
  meOpen.value = false
  await auth.signOut()
  router.push('/login')
}
</script>

<template>
  <!-- The site's top bar. The landing, log in and sign up pages draw their own, so it only hides there: it stays in the
       page because a page can put its own controls in it (#k-nav-context, #k-nav-actions). -->
  <div v-if="!isNativeApp" v-show="showTopBar" class="k kq k-topbar">
    <header class="ke2-nav">
      <RouterLink class="ks-brand" to="/" aria-label="Planova home"><KLogo /><span>planova</span></RouterLink>
      <div id="k-nav-context" class="k-nav-context"></div>
      <nav class="k-nav-tabs" aria-label="Main">
        <RouterLink class="tab" to="/" :aria-current="routeName === 'home' ? 'page' : undefined">Home</RouterLink>
        <!-- Events needs an account: a visitor would only be sent to Log in -->
        <RouterLink v-if="auth.isLoggedIn" class="tab" to="/events" :aria-current="routeName === 'events' ? 'page' : undefined">Events</RouterLink>
      </nav>
      <span class="sp"></span>
      <!-- Visible on every page while sharing, so users always know -->
      <RouterLink
        v-if="tracker.isTracking.value && tracker.sharingEventId.value"
        :to="{ name: 'share', params: { id: tracker.sharingEventId.value } }"
        class="chip chip-ink k-sharing"
        data-testid="nav-sharing"
      >
        <i class="dot pulse" style="background: var(--lime)"></i>Sharing location
      </RouterLink>
      <div id="k-nav-actions" class="k-nav-actions"></div>
      <div v-if="auth.isLoggedIn" ref="meWrap" class="wrapm">
        <button type="button" class="ks-av" aria-label="Account" :aria-expanded="meOpen ? 'true' : 'false'" data-testid="nav-account" @click="meOpen = !meOpen">{{ initials }}</button>
        <div v-if="meOpen" class="menu r" role="menu">
          <div class="k-me"><b>{{ auth.profile.username }}</b><div class="mut">Signed in</div></div>
          <hr />
          <RouterLink role="menuitem" class="k-menu-link" to="/profile" data-testid="nav-user" @click="meOpen = false">Profile</RouterLink>
          <button type="button" role="menuitem" data-testid="logout-btn" @click="logout">Log out</button>
        </div>
      </div>
      <RouterLink v-else class="kb kb-ghost" to="/login">Log in</RouterLink>
    </header>
  </div>

  <!-- One page per event: going straight from one event to another (a "Start sharing" push for event B tapped
       while event A is open) used to reuse A's page -- the address said B, the page showed and acted on A. Keyed
       by the route and its id, so only a different event rebuilds the page, not a query change like ?share=1. -->
  <div v-if="pendingNavigation" class="nav-loading" role="status" aria-live="polite" data-testid="nav-loading">
    <span class="nav-loading-bar"></span><span class="nav-loading-text">Loading…</span>
  </div>
  <!-- A page change from the top navigation fades the old page out and slides the new one up (motion.css). The
       wrapper gives the transition one element to animate, whatever the page's own template looks like. -->
  <RouterView v-slot="{ Component, route }">
    <Transition name="page" mode="out-in">
      <div :key="String(route.name) + ':' + (route.params.id || '')" class="page-shell">
        <component :is="Component" />
      </div>
    </Transition>
  </RouterView>
  <PhoneTabBar v-if="isNativeApp && auth.isLoggedIn && appTab" :items="APP_TABS" :active="appTab" />
  <NotifyHost />
</template>
