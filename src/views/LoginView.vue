<script setup>
// Sign in with email or username. After success, go back to the page the user wanted (?redirect=...)
import { ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import BenchAlert from '../components/BenchAlert.vue'

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
  <main class="container py-4">
    <div class="row justify-content-center">
      <div class="col-12 col-sm-10 col-md-7 col-lg-5">
        <div class="card">
          <div class="card-body">
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

              <button type="submit" class="btn btn-primary w-100" :disabled="busy" data-testid="auth-submit">
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
