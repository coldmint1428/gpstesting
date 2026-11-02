<script setup>
// Create an account: names, email, username (checked while typing), password with a live checklist.
import { ref, computed, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useUsernameCheck } from '../composables/useUsernameCheck'
import BenchAlert from '../components/BenchAlert.vue'
import KLogo from '../components/kinetic/KLogo.vue'
import KVenueMap from '../components/kinetic/KVenueMap.vue'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

const firstName = ref('')
const lastName = ref('')
const email = ref('')
const username = ref('')
const password = ref('')
const confirm = ref('')
const showPassword = ref(false)
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
  <div class="k kq">
    <main class="kg">
      <aside class="kg-art">
        <RouterLink class="kl-brand" to="/" style="color: #fff; padding: 0; position: relative; z-index: 2"><KLogo on-forest /><span>planova</span></RouterLink>
        <div class="kl-stage kl-spin" aria-hidden="true"><KVenueMap /></div>
        <h2>Right place.<br /><em>Right time.</em></h2>
      </aside>
      <div class="kg-form">
        <form novalidate @submit.prevent="submit">
          <RouterLink class="ks-crumb" to="/" style="margin-bottom: 26px"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m15 18-6-6 6-6"></path></svg>Home</RouterLink>
          <h1>Create account</h1>
          <p class="mut" style="margin: 0 0 26px; font-size: 16px">Plan your first event in minutes.</p>

          <div class="su-names">
            <div>
              <label for="firstName" class="lab">First name</label>
              <input id="firstName" v-model="firstName" class="kin" maxlength="50" autocomplete="given-name" required data-testid="first-name" />
            </div>
            <div>
              <label for="lastName" class="lab">Last name</label>
              <input id="lastName" v-model="lastName" class="kin" maxlength="50" autocomplete="family-name" required data-testid="last-name" />
            </div>
          </div>
          <label for="email" class="lab">Email</label>
          <input id="email" v-model="email" type="email" class="kin" autocomplete="email" placeholder="you@example.com" required data-testid="email" />

          <label for="username" class="lab">Username</label>
          <input
            id="username"
            v-model="username"
            class="kin"
            :class="{ 'is-invalid': ['invalid', 'taken'].includes(check.status.value), 'is-valid': check.status.value === 'free' }"
            :aria-invalid="['invalid', 'taken'].includes(check.status.value) ? 'true' : 'false'"
            maxlength="20"
            autocapitalize="none"
            autocomplete="username"
            aria-describedby="username-help"
            required
            data-testid="username"
          />
          <p id="username-help" class="hint su-help" aria-live="polite" data-testid="username-status">{{ check.message.value }}</p>

          <label for="password" class="lab">Password</label>
          <div class="kg-pw">
            <input id="password" v-model="password" :type="showPassword ? 'text' : 'password'" class="kin" autocomplete="new-password" aria-describedby="password-rules" required data-testid="password" style="padding-right: 52px" />
            <button type="button" class="ib" :aria-label="showPassword ? 'Hide password' : 'Show password'" :aria-pressed="showPassword ? 'true' : 'false'" @click="showPassword = !showPassword">
              <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path></svg>
            </button>
          </div>
          <label for="confirm" class="lab">Confirm password</label>
          <input id="confirm" v-model="confirm" :type="showPassword ? 'text' : 'password'" class="kin" autocomplete="new-password" required data-testid="password-confirm" />
          <ul id="password-rules" class="su-rules" aria-live="polite" data-testid="password-rules">
            <li v-for="r in rules" :key="r.text" :class="{ 'su-ok': r.ok }">
              <span aria-hidden="true">{{ r.ok ? '✓' : '○' }}</span> {{ r.text }}<span class="visually-hidden">{{ r.ok ? ' (done)' : ' (not yet)' }}</span>
            </li>
          </ul>

          <BenchAlert v-if="errorMsg" data-testid="auth-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

          <button type="submit" class="kb kb-lime kb-lg" style="width: 100%; margin-top: 20px" :disabled="!canSubmit" data-testid="auth-submit">
            {{ busy ? 'Please wait...' : 'Create account' }}
          </button>
          <div class="kg-or">or</div>
          <p style="text-align: center; margin: 0; font-size: 15px">
            Already have an account?
            <RouterLink class="link" :to="{ name: 'login', query: route.query.redirect ? { redirect: route.query.redirect } : {} }" data-testid="to-login">Log in</RouterLink>
          </p>
        </form>
      </div>
    </main>
  </div>
</template>

<style scoped>
.su-names { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.su-help { margin-top: 6px; min-height: 18px; }
.su-rules { list-style: none; margin: 12px 0 0; padding: 0; font-size: 13px; font-weight: 600; color: var(--muted); }
.su-ok { color: var(--olive); }
</style>
