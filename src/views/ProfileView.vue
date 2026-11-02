<script setup>
// My profile: email (read-only, it belongs to the login), names and username; log out.
import { ref, computed, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useUsernameCheck } from '../composables/useUsernameCheck'
import { toast } from '../composables/useNotify'
import BenchAlert from '../components/BenchAlert.vue'

const auth = useAuthStore()
const router = useRouter()

const firstName = ref('')
const lastName = ref('')
const username = ref('')
const errorMsg = ref('')
const busy = ref(false)

// Older accounts only have a display name: start from it
function fill(p) {
  if (!p) return
  const words = (p.display_name || '').trim().split(/\s+/)
  firstName.value = p.first_name ?? words[0] ?? ''
  lastName.value = p.last_name ?? (p.first_name ? '' : words.slice(1).join(' '))
  username.value = p.username
}
watch(() => auth.profile, fill, { immediate: true })

watch(username, (v) => {
  const lower = v.toLowerCase().replace(/\s/g, '')
  if (lower !== v) username.value = lower
})
const check = useUsernameCheck(username, () => (auth.profile ? auth.profile.username : ''))

const changed = computed(() => {
  const p = auth.profile
  if (!p) return false
  return username.value !== p.username || firstName.value.trim() !== (p.first_name || '') || lastName.value.trim() !== (p.last_name || '')
})
const canSave = computed(() => changed.value && check.ok.value && firstName.value.trim() && lastName.value.trim() && !busy.value)

async function save() {
  if (!canSave.value) return
  errorMsg.value = ''
  busy.value = true
  const message = await auth.updateProfile({ username: username.value, firstName: firstName.value, lastName: lastName.value })
  busy.value = false
  if (message) errorMsg.value = message
  else toast('Profile saved.')
}

async function logout() {
  await auth.signOut()
  router.push('/login')
}
</script>

<template>
  <main class="kp-page kp-page-sm">
    <div class="kp-head">
      <h1>Profile</h1>
      <button type="button" class="btn btn-sm btn-ghost" data-testid="profile-logout" @click="logout">Log out</button>
    </div>
    <form v-if="auth.profile" class="kp-card kp-fields" novalidate @submit.prevent="save">
      <div>
        <label for="email" class="form-label">Email</label>
        <input id="email" :value="auth.user && auth.user.email" class="form-control" readonly disabled aria-describedby="email-help" data-testid="profile-email" />
        <div id="email-help" class="form-text">Your login email can't be changed.</div>
      </div>
      <div class="kp-fields-2">
        <div>
          <label for="firstName" class="form-label">First name</label>
          <input id="firstName" v-model="firstName" class="form-control" maxlength="50" autocomplete="given-name" required data-testid="first-name" />
        </div>
        <div>
          <label for="lastName" class="form-label">Last name</label>
          <input id="lastName" v-model="lastName" class="form-control" maxlength="50" autocomplete="family-name" required data-testid="last-name" />
        </div>
      </div>
      <div>
        <label for="username" class="form-label">Username</label>
        <input
          id="username"
          v-model="username"
          class="form-control"
          :class="{ 'is-invalid': ['invalid', 'taken'].includes(check.status.value), 'is-valid': check.status.value === 'free' }"
          maxlength="20"
          autocapitalize="none"
          aria-describedby="username-help"
          required
          data-testid="username"
        />
        <div id="username-help" class="form-text" aria-live="polite">{{ check.message.value }}</div>
      </div>

      <BenchAlert v-if="errorMsg" data-testid="profile-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

      <button type="submit" class="btn btn-primary" :disabled="!canSave" data-testid="profile-save">
        {{ busy ? 'Saving...' : 'Save changes' }}
      </button>
    </form>
  </main>
</template>
