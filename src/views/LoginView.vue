<script setup>
// Sign in with email or username. After success, go back to the page the user wanted (?redirect=...)
import { ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import BenchAlert from '../components/BenchAlert.vue'
import KLogo from '../components/kinetic/KLogo.vue'
import KVenueMap from '../components/kinetic/KVenueMap.vue'
import { isNativeApp } from '../lib/platform'

const native = isNativeApp // phone app: brand header over the map, the form in a sheet (Figma screen 1)

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const identifier = ref('')
const password = ref('')
const showPassword = ref(false)
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
  router.push(route.query.redirect || '/') // the website's Home; the phone app's / goes on to My events
}
</script>

<template>
  <!-- ===== Website: Planova Kinetic "Log in" (forest art panel beside the form) ===== -->
  <div v-if="!native" class="k kq">
    <main class="kg">
      <aside class="kg-art">
        <RouterLink class="kl-brand" to="/" style="color: #fff; padding: 0; position: relative; z-index: 2"><KLogo on-forest /><span>planova</span></RouterLink>
        <div class="kl-stage kl-spin" aria-hidden="true"><KVenueMap /></div>
        <h2>Right place.<br /><em>Right time.</em></h2>
      </aside>
      <div class="kg-form">
        <form @submit.prevent="submit">
          <RouterLink class="ks-crumb" to="/" style="margin-bottom: 26px"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m15 18-6-6 6-6"></path></svg>Home</RouterLink>
          <h1>Welcome back</h1>
          <p class="mut" style="margin: 0 0 26px; font-size: 16px">Log in to see your events.</p>
          <p v-if="route.query.confirm" class="alert alert-info py-2 small" data-testid="confirm-email">
            Account created. Check your email to confirm it, then log in here.
          </p>

          <label for="identifier" class="lab">Email or username</label>
          <input id="identifier" v-model="identifier" class="kin" autocomplete="username" autocapitalize="none" required data-testid="email" />

          <label for="password" class="lab">Password</label>
          <div class="kg-pw">
            <input id="password" v-model="password" :type="showPassword ? 'text' : 'password'" class="kin" autocomplete="current-password" required data-testid="password" style="padding-right: 52px" />
            <button type="button" class="ib" :aria-label="showPassword ? 'Hide password' : 'Show password'" :aria-pressed="showPassword ? 'true' : 'false'" @click="showPassword = !showPassword">
              <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path></svg>
            </button>
          </div>

          <div v-if="errorMsg" style="margin-top: 14px">
            <BenchAlert data-testid="auth-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>
          </div>

          <button type="submit" class="kb kb-lime kb-lg" style="width: 100%; margin-top: 26px" :disabled="busy" data-testid="auth-submit">
            {{ busy ? 'Please wait...' : 'Log in' }}
          </button>
          <div class="kg-or">or</div>
          <p style="text-align: center; margin: 0; font-size: 15px">
            New to Planova?
            <RouterLink class="link" :to="{ name: 'signup', query: route.query.redirect ? { redirect: route.query.redirect } : {} }" data-testid="to-signup">Create an account</RouterLink>
          </p>
        </form>
      </div>
    </main>
  </div>

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
