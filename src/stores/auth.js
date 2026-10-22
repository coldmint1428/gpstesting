// Login state shared by every page (Pinia store, MIT licence - https://pinia.vuejs.org).
// Holds the Supabase session + the user's profile (username, display name).
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { supabase } from '../lib/supabase'
import { useLocationTracker, stopBackgroundTracking } from '../composables/useLocationTracker'
import { clearAllStartReminders } from '../composables/useStartReminders'
import { disablePush } from '../composables/usePushNotifications'
import { forgetMembership } from '../services/memberService'

// Usernames: 3-20 lowercase letters, numbers or _ (the same rule as the database)
export const USERNAME_RULE = /^[a-z0-9_]{3,20}$/

export const useAuthStore = defineStore('auth', () => {
  const session = ref(null)
  const profile = ref(null) // { id, username, display_name, first_name, last_name }
  const ready = ref(false) // true once we've checked for an existing login

  const user = computed(() => (session.value ? session.value.user : null))
  // Old anonymous test sessions have no profile, so they don't count as logged in
  const isLoggedIn = computed(() => profile.value !== null)

  let initPromise = null

  // The profile is kept on this device as well, so a page can open straight away instead of waiting
  // one round trip for it (the server is in Seoul). It is only names for the screen: the database
  // still checks every request against the real login. loadProfile refreshes it in the background.
  const PROFILE_KEY = 'gps-profile'
  function cachedProfile(userId) {
    try {
      const p = JSON.parse(localStorage.getItem(PROFILE_KEY))
      return p && p.id === userId ? p : null
    } catch {
      return null
    }
  }
  function cacheProfile(p) {
    try {
      if (p) localStorage.setItem(PROFILE_KEY, JSON.stringify(p))
      else localStorage.removeItem(PROFILE_KEY)
    } catch {
      // storage blocked (private mode): the profile is simply loaded every time
    }
  }

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
        const saved = data.session ? cachedProfile(data.session.user.id) : null
        if (saved) {
          profile.value = saved
          loadProfile() // not awaited: the page opens now, the names update if they changed
        } else {
          await loadProfile()
        }

        // Keep the store in sync when the login changes (sign in/out, token refresh)
        supabase.auth.onAuthStateChange((event, newSession) => {
          session.value = newSession
          if (!newSession) {
            profile.value = null
            cacheProfile(null)
            forgetMembership()
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
    // '*' rather than naming first_name / last_name: those only exist once 031 is applied, and naming a missing
    // column fails the whole read (every account then looked logged out)
    const { data } = await supabase.from('profiles').select('*').eq('id', user.value.id).maybeSingle()
    profile.value = data
    cacheProfile(data)
  }

  // Is this username free? true / false, or an error message. (Before sign-up: a taken username otherwise makes
  // Supabase answer only "Database error saving new user".)
  async function usernameAvailable(name) {
    const { data, error } = await supabase.rpc('username_available', { p_username: name })
    if (error) return error.message
    return data
  }

  // Returns { error, needsConfirm }: error '' on success; needsConfirm when the project asks for email confirmation
  async function signUp({ email, password, username, firstName, lastName }) {
    const name = username.trim().toLowerCase()
    if (!USERNAME_RULE.test(name)) return { error: 'Username: 3-20 lowercase letters, numbers or _' }

    const free = await usernameAvailable(name)
    if (typeof free === 'string') return { error: free }
    if (!free) return { error: 'That username is taken' }

    // username + names are saved into "profiles" by a database trigger (031)
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { username: name, first_name: firstName.trim(), last_name: lastName.trim() } },
    })
    if (error) return { error: error.message }
    if (!data.session) return { error: '', needsConfirm: true }

    session.value = data.session
    await loadProfile()
    return { error: '' }
  }

  // Email or username + password. Returns an error message, or '' on success.
  async function signIn(identifier, password) {
    const WRONG = 'Incorrect username/email or password'
    let email = identifier.trim()
    if (!email.includes('@')) {
      const { data, error } = await supabase.rpc('login_email', { p_username: email })
      // 031 not applied yet: there is no username lookup
      if (error && error.code === 'PGRST202') return 'Signing in with a username is not available yet. Use your email.'
      if (error) return error.message
      if (!data) return WRONG
      email = data
    }
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) return /confirm/i.test(error.message) ? 'Please confirm your email first (check your inbox).' : WRONG
    session.value = data.session
    await loadProfile()
    if (!profile.value) return 'This account has no profile. Please sign up again.'
    return ''
  }

  // My names and username. Returns an error message, or '' on success.
  async function updateProfile({ username, firstName, lastName }) {
    const name = username.trim().toLowerCase()
    if (!USERNAME_RULE.test(name)) return 'Username: 3-20 lowercase letters, numbers or _'
    const { data, error } = await supabase
      .from('profiles')
      .update({ username: name, first_name: firstName.trim() || null, last_name: lastName.trim() || null })
      .eq('id', user.value.id)
      .select('*')
      .maybeSingle()
    if (error) return error.code === '23505' ? 'That username is taken' : error.message
    profile.value = data
    cacheProfile(data)
    return ''
  }

  async function signOut() {
    // Stop sharing first (while still logged in, so the "Stopped" marker can be saved),
    // then clear the phone's background queue, otherwise it keeps uploading as this user
    const tracker = useLocationTracker()
    if (tracker.isTracking.value) await tracker.stop()
    await stopBackgroundTracking()
    await clearAllStartReminders()
    await disablePush()
    // 'local': log out THIS device only. The default ('global') also ended the same account's login
    // in every other browser and phone, which then failed with "Not signed in" on the next reminder.
    await supabase.auth.signOut({ scope: 'local' })
    session.value = null
    profile.value = null
    cacheProfile(null)
    // An unfinished Create-an-event draft holds other people's names: not for the next person on this device
    try {
      localStorage.removeItem('eventWizardDraft')
    } catch {
      // no storage
    }
    forgetMembership()
  }

  return { session, profile, ready, user, isLoggedIn, init, signUp, signIn, signOut, loadProfile, usernameAvailable, updateProfile }
})
