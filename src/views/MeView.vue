<script setup>
// Me (phone app): who is signed in, whether this phone is sharing its location right now (and for which event),
// the phone set-up, and signing out. On the website these live in the top bar.
import { computed } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useLocationTracker } from '../composables/useLocationTracker'
import { askConfirm } from '../composables/useNotify'

const auth = useAuthStore()
const router = useRouter()
const tracker = useLocationTracker()

const name = computed(() => (auth.profile && (auth.profile.display_name || auth.profile.username)) || '')
const initials = computed(() =>
  name.value
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join(''),
)
const sharing = computed(() => tracker.isTracking.value && tracker.sharingEventId.value)

async function stopSharing() {
  if (!(await askConfirm({ title: 'Stop sharing your location?', message: 'Your planners and group will see you as stopped.', confirmText: 'Stop sharing', danger: true }))) return
  await tracker.stop()
}
async function logout() {
  if (!(await askConfirm({ title: 'Log out?', message: sharing.value ? 'Sharing stops when you log out.' : '', confirmText: 'Log out', danger: true }))) return
  await auth.signOut()
  router.push('/login')
}
</script>

<template>
  <main class="kp-page kp-page-sm kp-stack pv-has-tabs">
    <header class="kp-inline">
      <div class="kp-av kp-av-lg" aria-hidden="true">{{ initials }}</div>
      <div class="kp-minw0">
        <h1 class="kp-title" style="font-size: 24px">{{ name }}</h1>
        <p class="kp-sub" data-testid="me-username">@{{ auth.profile && auth.profile.username }}</p>
      </div>
    </header>

    <section class="kp-card" aria-labelledby="me-share-h">
      <h2 id="me-share-h" class="kp-label">Location sharing</h2>
      <template v-if="sharing">
        <p class="kp-inline mb-3"><span class="kp-dot" style="background: var(--live)" aria-hidden="true"></span><strong>Sharing now</strong> · every 10 s</p>
        <div class="kp-actions">
          <RouterLink :to="{ name: 'event', params: { id: tracker.sharingEventId.value } }" class="btn btn-outline-secondary flex-grow-1">Open event</RouterLink>
          <button type="button" class="btn btn-outline-danger flex-grow-1" data-testid="me-stop" @click="stopSharing">Stop sharing</button>
        </div>
      </template>
      <p v-else class="mb-0 text-muted">Not sharing right now.</p>
    </section>

    <RouterLink :to="{ name: 'phone-check' }" class="kp-card kp-inline text-reset text-decoration-none">
      <span class="kp-row-main">
        <strong>Phone set-up</strong>
        <span>Location, battery, notifications</span>
      </span>
      <span aria-hidden="true">›</span>
    </RouterLink>

    <button type="button" class="btn btn-ghost" data-testid="me-logout" @click="logout">Log out</button>
  </main>
</template>
