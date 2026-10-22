<script setup>
import { computed, onMounted, watch } from 'vue'
import { RouterLink, RouterView, useRouter } from 'vue-router'
import { useAuthStore } from './stores/auth'
import { useLocationTracker } from './composables/useLocationTracker'
import { syncStartReminders, listenForReminderTaps } from './composables/useStartReminders'
import { enablePush } from './composables/usePushNotifications'
import NotifyHost from './components/NotifyHost.vue'
import PhoneTabBar from './components/PhoneTabBar.vue'
import { isNativeApp } from './lib/platform'

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

async function logout() {
  await auth.signOut()
  router.push('/login')
}
</script>

<template>
  <nav v-if="!isNativeApp" class="navbar navbar-expand-sm navbar-dark app-nav">
    <div class="container-fluid app-nav-inner">
      <RouterLink class="navbar-brand fw-semibold" to="/">Event Tracker</RouterLink>
      <button
        class="navbar-toggler"
        type="button"
        data-bs-toggle="collapse"
        data-bs-target="#mainNav"
        aria-controls="mainNav"
        aria-expanded="false"
        aria-label="Toggle navigation"
      >
        <span class="navbar-toggler-icon"></span>
      </button>
      <div id="mainNav" class="collapse navbar-collapse">
        <ul class="navbar-nav ms-auto align-items-sm-center">
          <li class="nav-item"><RouterLink class="nav-link" to="/">Home</RouterLink></li>
          <li class="nav-item"><RouterLink class="nav-link" to="/events">Events</RouterLink></li>
          <li v-if="tracker.isTracking.value && tracker.sharingEventId.value" class="nav-item">
            <!-- Visible on every page while sharing, so users always know -->
            <RouterLink
              :to="{ name: 'share', params: { id: tracker.sharingEventId.value } }"
              class="nav-link"
              data-testid="nav-sharing"
            >
              <span class="badge text-bg-success">● Sharing location</span>
            </RouterLink>
          </li>
          <li v-if="auth.isLoggedIn" class="nav-item ms-sm-2">
            <RouterLink class="navbar-text small me-2 text-decoration-none" to="/profile" data-testid="nav-user">
              @{{ auth.profile.username }}
            </RouterLink>
            <button class="btn btn-outline-light btn-sm" data-testid="logout-btn" @click="logout">Log out</button>
          </li>
          <li v-else class="nav-item">
            <RouterLink class="nav-link" to="/login">Sign in</RouterLink>
          </li>
        </ul>
      </div>
    </div>
  </nav>

  <!-- One page per event: going straight from one event to another (a "Start sharing" push for event B tapped
       while event A is open) used to reuse A's page -- the address said B, the page showed and acted on A. Keyed
       by the route and its id, so only a different event rebuilds the page, not a query change like ?share=1. -->
  <RouterView v-slot="{ Component, route }">
    <component :is="Component" :key="String(route.name) + ':' + (route.params.id || '')" />
  </RouterView>
  <PhoneTabBar v-if="isNativeApp && auth.isLoggedIn && appTab" :items="APP_TABS" :active="appTab" />
  <NotifyHost />
</template>
