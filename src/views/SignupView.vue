<script setup>
// Create an account: names, email, username (checked while typing), password with a live checklist.
import { ref, computed, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useUsernameCheck } from '../composables/useUsernameCheck'
import BenchAlert from '../components/BenchAlert.vue'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const firstName = ref('')
const lastName = ref('')
const email = ref('')
const username = ref('')
const password = ref('')
const confirm = ref('')
const errorMsg = ref('')
const busy = ref(false)

// lowercase while typing (usernames are stored lowercase)
watch(username, (v) => {
  const lower = v.toLowerCase().replace(/\s/g, '')
  if (lower !== v) username.value = lower
})
const check = useUsernameCheck(username)

const rules = computed(() => [
  { text: 'At least 8 characters', ok: password.value.length >= 8 },
  { text: 'Contains a number', ok: /\d/.test(password.value) },
  { text: 'Contains a letter', ok: /[a-z]/i.test(password.value) },
  { text: 'Passwords match', ok: password.value !== '' && password.value === confirm.value },
])
const passwordOk = computed(() => rules.value.every((r) => r.ok))
const canSubmit = computed(() => passwordOk.value && check.ok.value && firstName.value.trim() && lastName.value.trim() && !busy.value)

async function submit() {
  if (!canSubmit.value) return
  errorMsg.value = ''
  busy.value = true
  const result = await auth.signUp({
    email: email.value,
    password: password.value,
    username: username.value,
    firstName: firstName.value,
    lastName: lastName.value,
  })
  busy.value = false
  if (result.error) {
    errorMsg.value = result.error
    return
  }
  if (result.needsConfirm) {
    router.push({ name: 'login', query: { confirm: '1', ...(route.query.redirect ? { redirect: route.query.redirect } : {}) } })
    return
  }
  router.push(route.query.redirect || '/') // the website's Home; the phone app's / goes on to My events
}
</script>

<template>
  <main class="pl-login">
    <section class="pl-login__brand">
      <h1>Plan the venue. Move every group on time.</h1>
    </section>
    <section class="pl-login__form">
      <div class="pl-login__card">
        <h2 class="pl-h-page mb-1">Create account</h2>
        <p class="pl-meta mb-3">One account for every event you are part of.</p>
            <form novalidate @submit.prevent="submit">
              <div class="row g-2 mb-3">
                <div class="col-12 col-sm-6">
                  <label for="firstName" class="form-label">First name</label>
                  <input id="firstName" v-model="firstName" class="form-control" maxlength="50" autocomplete="given-name" required data-testid="first-name" />
                </div>
                <div class="col-12 col-sm-6">
                  <label for="lastName" class="form-label">Last name</label>
                  <input id="lastName" v-model="lastName" class="form-control" maxlength="50" autocomplete="family-name" required data-testid="last-name" />
                </div>
              </div>
              <div class="mb-3">
                <label for="email" class="form-label">Email</label>
                <input id="email" v-model="email" type="email" class="form-control" autocomplete="email" required data-testid="email" />
              </div>
              <div class="mb-3">
                <label for="username" class="form-label">Username</label>
                <input
                  id="username"
                  v-model="username"
                  class="form-control"
                  :class="{ 'is-invalid': ['invalid', 'taken'].includes(check.status.value), 'is-valid': check.status.value === 'free' }"
                  maxlength="20"
                  autocapitalize="none"
                  autocomplete="username"
                  aria-describedby="username-help"
                  required
                  data-testid="username"
                />
                <div id="username-help" class="form-text" aria-live="polite" data-testid="username-status">{{ check.message.value }}</div>
              </div>
              <div class="mb-2">
                <label for="password" class="form-label">Password</label>
                <input id="password" v-model="password" type="password" class="form-control" autocomplete="new-password" aria-describedby="password-rules" required data-testid="password" />
              </div>
              <div class="mb-2">
                <label for="confirm" class="form-label">Confirm password</label>
                <input id="confirm" v-model="confirm" type="password" class="form-control" autocomplete="new-password" required data-testid="password-confirm" />
              </div>
              <ul id="password-rules" class="list-unstyled small mb-3" aria-live="polite" data-testid="password-rules">
                <li v-for="r in rules" :key="r.text" :class="r.ok ? 'text-success' : 'text-muted'">
                  <span aria-hidden="true">{{ r.ok ? '✓' : '○' }}</span> {{ r.text }}<span class="visually-hidden">{{ r.ok ? ' (done)' : ' (not yet)' }}</span>
                </li>
              </ul>

              <BenchAlert v-if="errorMsg" data-testid="auth-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

              <button type="submit" class="btn btn-primary w-100" :disabled="!canSubmit" data-testid="auth-submit">
                {{ busy ? 'Please wait...' : 'Create account' }}
              </button>
            </form>
            <p class="small text-center mt-3 mb-0">
              Already have an account?
              <RouterLink :to="{ name: 'login', query: route.query.redirect ? { redirect: route.query.redirect } : {} }" data-testid="to-login">
                Log in
              </RouterLink>
            </p>
      </div>
    </section>
  </main>
</template>
