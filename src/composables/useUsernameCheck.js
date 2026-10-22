// Checks a username while it is typed (sign-up and profile pages): format first, then, 400 ms after the last key,
// whether it is free. status: 'empty' | 'invalid' | 'checking' | 'free' | 'taken' | 'same' (my own) | 'error'
import { ref, computed, watch, onUnmounted } from 'vue'
import { useAuthStore, USERNAME_RULE } from '../stores/auth'

export function useUsernameCheck(username, currentUsername = () => '') {
  const auth = useAuthStore()
  const status = ref('empty')
  const errorText = ref('')
  let timer = null
  let latest = 0

  watch(
    username,
    (value) => {
      clearTimeout(timer)
      const name = (value || '').trim()
      if (!name) return (status.value = 'empty')
      if (!USERNAME_RULE.test(name)) return (status.value = 'invalid')
      if (name === currentUsername()) return (status.value = 'same')
      status.value = 'checking'
      const ask = ++latest
      timer = setTimeout(async () => {
        const free = await auth.usernameAvailable(name)
        if (ask !== latest) return // a newer value is being checked
        if (typeof free === 'string') {
          status.value = 'error'
          errorText.value = free
        } else status.value = free ? 'free' : 'taken'
      }, 400)
    },
    { immediate: true },
  )
  onUnmounted(() => clearTimeout(timer))

  const ok = computed(() => status.value === 'free' || status.value === 'same')
  const message = computed(
    () =>
      ({
        empty: '3-20 lowercase letters, numbers or _. Others add you to events with it.',
        invalid: 'Use 3-20 lowercase letters, numbers or _.',
        checking: 'Checking...',
        free: '✓ Available',
        taken: '✗ That username is taken',
        same: 'Your current username',
        error: 'Could not check: ' + errorText.value,
      })[status.value],
  )

  return { status, ok, message }
}
