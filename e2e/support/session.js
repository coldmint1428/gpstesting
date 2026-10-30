// QA accounts for the E2E tests. The accounts and their password live in .tmp/qa-accounts.json (git-ignored),
// made by the QA setup, never in the repo. A session is fetched once through the auth API and cached in
// .tmp/e2e-sessions.json, so a test run signs in each account at most once (Supabase limits sign-ins per address).
import fs from 'node:fs'
import { createClient } from '@supabase/supabase-js'

const ENV = Object.fromEntries(
  fs
    .readFileSync(new URL('../../.env', import.meta.url), 'utf8')
    .split(/\r?\n/)
    .filter((l) => /^[A-Z_]+=/.test(l))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).trim()]),
)
export const SUPABASE_URL = ENV.VITE_SUPABASE_URL
export const ANON_KEY = ENV.VITE_SUPABASE_ANON_KEY
const REF = new URL(SUPABASE_URL).hostname.split('.')[0]
export const STORAGE_KEY = `sb-${REF}-auth-token`

const ACCOUNTS = JSON.parse(fs.readFileSync(new URL('../../.tmp/qa-accounts.json', import.meta.url), 'utf8'))
const CACHE = new URL('../../.tmp/e2e-sessions.json', import.meta.url)

export const qa = (name) => ACCOUNTS.users[name]

function readCache() {
  try {
    return JSON.parse(fs.readFileSync(CACHE, 'utf8'))
  } catch {
    return {}
  }
}

/** A fresh session for a QA account: refreshed from the cache when possible, signed in otherwise. */
export async function sessionFor(name) {
  const cache = readCache()
  const sb = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  let session = null
  const cached = cache[name]
  if (cached && cached.expires_at * 1000 > Date.now() + 10 * 60_000) session = cached
  else if (cached) {
    const { data } = await sb.auth.refreshSession({ refresh_token: cached.refresh_token })
    session = data.session
  }
  if (!session) {
    // Auth allows a burst of about 30 sign-ins per address; a test run waits its turn rather than failing on a 429
    for (let attempt = 0; ; attempt++) {
      const { data, error } = await sb.auth.signInWithPassword({ email: qa(name).email, password: ACCOUNTS.password })
      if (!error) {
        session = data.session
        break
      }
      if (error.status !== 429 || attempt >= 20) throw new Error(`QA sign-in for ${name} failed: ${error.message}`)
      await new Promise((r) => setTimeout(r, 3000))
    }
  }
  fs.writeFileSync(CACHE, JSON.stringify({ ...readCache(), [name]: session }))
  return session
}

/** A supabase client signed in as a QA account, for setting up and checking data around a test. */
export async function clientFor(name) {
  const session = await sessionFor(name)
  const sb = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  await sb.auth.setSession({ access_token: session.access_token, refresh_token: session.refresh_token })
  return { sb, user: session.user }
}

/** Playwright storageState that opens the app already signed in as this account. */
export async function storageFor(name, baseURL) {
  const session = await sessionFor(name)
  return {
    cookies: [],
    origins: [{ origin: new URL(baseURL).origin, localStorage: [{ name: STORAGE_KEY, value: JSON.stringify(session) }] }],
  }
}

/** A new browser context signed in as `name` (or signed out when name is null). */
export async function contextAs(browser, name, baseURL, options = {}) {
  const storageState = name ? await storageFor(name, baseURL) : undefined
  return browser.newContext({ baseURL, storageState, timezoneId: 'Asia/Singapore', ...options })
}
