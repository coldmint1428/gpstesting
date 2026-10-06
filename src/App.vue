<script setup>
import { onMounted } from 'vue'
import { RouterLink, RouterView, useRouter } from 'vue-router'
import { useAuthStore } from './stores/auth'
import { useLocationTracker } from './composables/useLocationTracker'

const auth = useAuthStore()
const router = useRouter()
const tracker = useLocationTracker() // shared by every page

onMounted(async () => {
  await auth.init()
  // Phone app: start Transistorsoft (must happen on every launch) and show tracking
  // that is still running from before. Does nothing in a normal browser.
  tracker.resume(auth.isLoggedIn)
})

async function logout() {
  await auth.signOut()
  router.push('/login')
}
</script>

<template>
  <nav class="navbar navbar-expand-sm navbar-dark bg-dark">
    <div class="container">
      <RouterLink class="navbar-brand" to="/">GPS Testing</RouterLink>
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
          <li class="nav-item"><RouterLink class="nav-link" to="/polygon">Polygons</RouterLink></li>
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
            <span class="navbar-text small me-2" data-testid="nav-user">@{{ auth.profile.username }}</span>
            <button class="btn btn-outline-light btn-sm" data-testid="logout-btn" @click="logout">Log out</button>
          </li>
          <li v-else class="nav-item">
            <RouterLink class="nav-link" to="/login">Sign in</RouterLink>
          </li>
        </ul>
      </div>
    </div>
  </nav>

  <RouterView />
</template>
