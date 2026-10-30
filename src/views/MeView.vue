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
  <main class="me pv-has-tabs">
    <header class="me-head">
      <div class="me-avatar" aria-hidden="true">{{ initials }}</div>
      <div class="min-w-0">
        <h1 class="me-name">{{ name }}</h1>
        <p class="me-user" data-testid="me-username">@{{ auth.profile && auth.profile.username }}</p>
      </div>
    </header>

    <section class="me-card" aria-labelledby="me-share-h">
      <h2 id="me-share-h" class="pv-label mb-2">Location sharing</h2>
      <template v-if="sharing">
        <p class="mb-3 d-flex align-items-center gap-2"><span class="me-dot" aria-hidden="true"></span><strong>Sharing now</strong> · every 10 s</p>
        <div class="d-flex gap-2">
          <RouterLink :to="{ name: 'event', params: { id: tracker.sharingEventId.value } }" class="btn btn-outline-primary flex-grow-1">Open event</RouterLink>
          <button type="button" class="btn btn-outline-danger flex-grow-1" data-testid="me-stop" @click="stopSharing">Stop sharing</button>
        </div>
      </template>
      <p v-else class="mb-0 text-muted">Not sharing. An IC shares from the event's Now tab once a planner starts the event.</p>
    </section>

    <RouterLink :to="{ name: 'phone-check' }" class="me-row">
      <span class="flex-grow-1">
        <strong class="d-block">Phone set-up</strong>
        <span class="text-muted small">Location "All the time", battery and notifications</span>
      </span>
      <span aria-hidden="true" class="me-chev">›</span>
    </RouterLink>

    <button type="button" class="btn btn-outline-secondary w-100 mt-2" data-testid="me-logout" @click="logout">Log out</button>
  </main>
</template>

<style scoped>
.me {
  padding: calc(16px + var(--pv-safe-top, 0px)) 16px 0;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.me-head {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 8px 4px 4px;
}
.me-avatar {
  flex: none;
  width: 64px;
  height: 64px;
  border-radius: 999px;
  background: var(--pv-highlight);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 24px;
  font-weight: 600;
}
.me-name {
  font-size: 26px;
  font-weight: 600;
  margin: 0;
}
.me-user {
  margin: 0;
  color: var(--pv-muted);
}
.me-card {
  background: var(--pv-card);
  border-radius: 20px;
  padding: 16px;
}
.me-dot {
  width: 10px;
  height: 10px;
  border-radius: 999px;
  background: var(--pv-success);
}
.me-row {
  display: flex;
  align-items: center;
  gap: 12px;
  background: var(--pv-card);
  border-radius: 20px;
  padding: 14px 16px;
  color: var(--pv-text);
  text-decoration: none;
  min-height: 56px;
}
.me-chev {
  font-size: 26px;
  color: var(--pv-muted);
  line-height: 1;
}
.min-w-0 {
  min-width: 0;
}
</style>
