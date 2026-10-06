<script setup>
// Sign in / sign up page. After success, go back to the page the user wanted (?redirect=...)
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const mode = ref('signin') // 'signin' | 'signup'
const email = ref('')
const password = ref('')
const username = ref('')
const displayName = ref('')
const errorMsg = ref('')
const busy = ref(false)

async function submit() {
  errorMsg.value = ''
  busy.value = true
  const message =
    mode.value === 'signin'
      ? await auth.signIn(email.value, password.value)
      : await auth.signUp(email.value, password.value, username.value, displayName.value)
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
            <ul class="nav nav-pills nav-fill mb-3">
              <li class="nav-item">
                <button
                  class="nav-link w-100"
                  :class="{ active: mode === 'signin' }"
                  data-testid="tab-signin"
                  @click="mode = 'signin'"
                >
                  Sign in
                </button>
              </li>
              <li class="nav-item">
                <button
                  class="nav-link w-100"
                  :class="{ active: mode === 'signup' }"
                  data-testid="tab-signup"
                  @click="mode = 'signup'"
                >
                  Create account
                </button>
              </li>
            </ul>

            <form @submit.prevent="submit">
              <div class="mb-3">
                <label for="email" class="form-label">Email</label>
                <input id="email" v-model="email" type="email" class="form-control" autocomplete="email" required data-testid="email" />
              </div>
              <div class="mb-3">
                <label for="password" class="form-label">Password</label>
                <input
                  id="password"
                  v-model="password"
                  type="password"
                  class="form-control"
                  minlength="6"
                  :autocomplete="mode === 'signin' ? 'current-password' : 'new-password'"
                  required
                  data-testid="password"
                />
              </div>

              <template v-if="mode === 'signup'">
                <div class="mb-3">
                  <label for="username" class="form-label">Username</label>
                  <input
                    id="username"
                    v-model="username"
                    class="form-control"
                    pattern="[A-Za-z0-9_]{3,20}"
                    autocapitalize="none"
                    required
                    data-testid="username"
                  />
                  <div class="form-text">Others add you to events with this. 3-20 letters, numbers or _.</div>
                </div>
                <div class="mb-3">
                  <label for="displayName" class="form-label">Display name</label>
                  <input id="displayName" v-model="displayName" class="form-control" maxlength="50" required data-testid="display-name" />
                  <div class="form-text">Shown on the map, e.g. "Komin Chow".</div>
                </div>
              </template>

              <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="auth-error">{{ errorMsg }}</div>

              <button type="submit" class="btn btn-primary w-100" :disabled="busy" data-testid="auth-submit">
                {{ busy ? 'Please wait...' : mode === 'signin' ? 'Sign in' : 'Create account' }}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
  </main>
</template>
