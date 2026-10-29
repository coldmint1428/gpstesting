<script setup>
// Sign in with email or username. After success, go back to the page the user wanted (?redirect=...)
import { ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import BenchAlert from '../components/BenchAlert.vue'
import { isNativeApp } from '../lib/platform'

const native = isNativeApp // phone app: brand header over the map, the form in a sheet (Figma screen 1)

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const identifier = ref('')
const password = ref('')
const errorMsg = ref('')
const busy = ref(false)

async function submit() {
  errorMsg.value = ''
  busy.value = true
  const message = await auth.signIn(identifier.value, password.value)
  busy.value = false
  if (message) {
    errorMsg.value = message
    return
  }
  router.push(route.query.redirect || '/events')
}
</script>

<template>
  <!-- ===== Website: Planova "Log in" (dark brand panel beside the form) ===== -->
  <main v-if="!native" class="pl-login">
    <section class="pl-login__brand">
      <h1>Plan the venue. Move every group on time.</h1>
      <ul class="pl-login__points">
        <li>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3V6m6-3v15m6-12v15" /></svg>
          <div><b>Draw zones on the venue map</b><span>Stage, entrances, assembly areas and no-go zones, sized to the real site.</span></div>
        </li>
        <li>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 7v5l3 2m7-2a10 10 0 1 1-20 0 10 10 0 1 1 20 0" /></svg>
          <div><b>Schedule where each group should be</b><span>A time-by-time run sheet every group can follow.</span></div>
        </li>
        <li>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 22S4 16 4 10a8 8 0 1 1 16 0c0 6-8 12-8 12ZM15 10a3 3 0 1 1-6 0 3 3 0 1 1 6 0Z" /></svg>
          <div><b>Follow one IC per group live</b><span>A clear map, not hundreds of dots, then replay the day afterwards.</span></div>
        </li>
      </ul>
    </section>
    <section class="pl-login__form">
      <div class="pl-login__card">
        <h2 class="pl-h-page mb-1">Log in</h2>
        <p class="pl-meta mb-3">Use your email or username.</p>
        <p v-if="route.query.confirm" class="alert alert-info py-2 small" data-testid="confirm-email">
          Account created. Check your email to confirm it, then log in here.
        </p>

        <form @submit.prevent="submit">
          <div class="mb-3">
            <label for="identifier" class="form-label">Email or username</label>
            <input
              id="identifier"
              v-model="identifier"
              class="form-control"
              autocomplete="username"
              autocapitalize="none"
              required
              data-testid="email"
            />
          </div>
          <div class="mb-3">
            <label for="password" class="form-label">Password</label>
            <input
              id="password"
              v-model="password"
              type="password"
              class="form-control"
              autocomplete="current-password"
              required
              data-testid="password"
            />
          </div>

          <BenchAlert v-if="errorMsg" data-testid="auth-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

          <button type="submit" class="btn btn-primary btn-lg w-100" :disabled="busy" data-testid="auth-submit">
            {{ busy ? 'Please wait...' : 'Log in' }}
          </button>
        </form>

        <hr class="my-4" />
        <p class="pl-meta mb-0">
          New to Planova?
          <RouterLink :to="{ name: 'signup', query: route.query.redirect ? { redirect: route.query.redirect } : {} }" data-testid="to-signup">
            Create an account
          </RouterLink>
        </p>
      </div>
    </section>
  </main>

  <!-- ===== Phone app: brand header over the map, the form in a sheet (Figma screen 1) ===== -->
  <main v-else class="pv-login">
    <div class="pv-login-hero">
      <div class="pv-logo">Planova</div>
      <p>Every group in the right place, on time.</p>
    </div>
    <div class="pv-login-sheet">
      <div>
        <div>
          <div>
            <h1 class="h4 mb-3">Sign in</h1>
            <p v-if="route.query.confirm" class="alert alert-info py-2 small" data-testid="confirm-email">
              Account created. Check your email to confirm it, then sign in here.
            </p>

            <form @submit.prevent="submit">
              <div class="mb-3">
                <label for="identifier" class="form-label">Email or username</label>
                <input
                  id="identifier"
                  v-model="identifier"
                  class="form-control"
                  autocomplete="username"
                  autocapitalize="none"
                  required
                  data-testid="email"
                />
              </div>
              <div class="mb-3">
                <label for="password" class="form-label">Password</label>
                <input
                  id="password"
                  v-model="password"
                  type="password"
                  class="form-control"
                  autocomplete="current-password"
                  required
                  data-testid="password"
                />
              </div>

              <BenchAlert v-if="errorMsg" data-testid="auth-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

              <button type="submit" class="btn btn-primary w-100 btn-lg" :disabled="busy" data-testid="auth-submit">
                {{ busy ? 'Please wait...' : 'Sign in' }}
              </button>
            </form>

            <p class="small text-center mt-3 mb-0">
              No account yet?
              <RouterLink :to="{ name: 'signup', query: route.query.redirect ? { redirect: route.query.redirect } : {} }" data-testid="to-signup">
                Create one
              </RouterLink>
            </p>
          </div>
        </div>
      </div>
    </div>
  </main>
</template>
