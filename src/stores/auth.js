// Login state shared by every page (Pinia store, MIT licence - https://pinia.vuejs.org).
// Holds the Supabase session + the user's profile (username, display name).
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { supabase } from '../lib/supabase'
import { useLocationTracker, stopBackgroundTracking } from '../composables/useLocationTracker'

export const useAuthStore = defineStore('auth', () => {
  const session = ref(null)
  const profile = ref(null) // { id, username, display_name }
  const ready = ref(false) // true once we've checked for an existing login

  const user = computed(() => (session.value ? session.value.user : null))
  // Old anonymous test sessions have no profile, so they don't count as logged in
  const isLoggedIn = computed(() => profile.value !== null)

  let initPromise = null

  // Called once (by the router guard): restore the login saved in this browser
  function init() {
    if (!initPromise) {
      initPromise = (async () => {
        if (!supabase) {
          ready.value = true
          return
        }
        const { data } = await supabase.auth.getSession()
        session.value = data.session
        await loadProfile()

        // Keep the store in sync when the login changes (sign in/out, token refresh)
        supabase.auth.onAuthStateChange((event, newSession) => {
          session.value = newSession
          if (!newSession) {
            profile.value = null
          } else if (!profile.value || profile.value.id !== newSession.user.id) {
            // Don't call Supabase directly inside this callback (supabase-js can deadlock)
            setTimeout(loadProfile, 0)
          }
        })
        ready.value = true
      })()
    }
    return initPromise
  }

  async function loadProfile() {
    if (!user.value) {
      profile.value = null
      return
    }
    const { data } = await supabase
      .from('profiles')
      .select('id, username, display_name')
      .eq('id', user.value.id)
      .maybeSingle()
    profile.value = data
  }

  // Returns an error message, or '' on success
  async function signUp(email, password, username, displayName) {
    const name = username.trim().toLowerCase()
    if (!/^[a-z0-9_]{3,20}$/.test(name)) {
      return 'Username: 3-20 characters, only letters, numbers and _'
    }

    const { data: free, error: checkError } = await supabase.rpc('username_available', { p_username: name })
    if (checkError) return checkError.message
    if (!free) return 'That username is taken'

    // username + display_name are saved by a database trigger into "profiles"
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { username: name, display_name: displayName.trim() } },
    })
    if (error) return error.message
    if (!data.session) return 'Account created. Check your email to confirm, then sign in.'

    session.value = data.session
    await loadProfile()
    return ''
  }

  async function signIn(email, password) {
    const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    if (error) return error.message
    session.value = data.session
    await loadProfile()
    if (!profile.value) return 'This account has no profile. Please sign up again.'
    return ''
  }

  async function signOut() {
    // Stop sharing first (while still logged in, so the "Stopped" marker can be saved),
    // then clear the phone's background queue, otherwise it keeps uploading as this user
    const tracker = useLocationTracker()
    if (tracker.isTracking.value) await tracker.stop()
    await stopBackgroundTracking()
    await supabase.auth.signOut()
    session.value = null
    profile.value = null
  }

  return { session, profile, ready, user, isLoggedIn, init, signUp, signIn, signOut, loadProfile }
})
