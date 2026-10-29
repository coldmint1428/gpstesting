#!/usr/bin/env node
// Mint a real session for a user, so a page that needs a login can be rendered and screenshotted.
//
// How it works, in order:
//   1. the personal access token fetches the project's service_role key
//   2. the service key mints a one-time login link for that user (admin/generate_link)
//   3. the link is exchanged for a session without following the redirect
//   4. the session is written in the shape supabase-js keeps in localStorage
//
// It changes nothing about the account: no password is set, no email is sent. The session is a normal login
// that expires on its own. The file is written to .tmp/ and deleted after use.
//
//   $env:SUPABASE_PAT = 'sbp_...'
//   node tools/authlink.mjs <user id>
//
// !!! The output file contains live tokens. Delete it when done.

import fs from 'node:fs'

const REF = process.env.SUPABASE_REF || 'ikvzxmygjhpxrqiiyzqe'
const PAT = process.env.SUPABASE_PAT
const userId = process.argv[2]
const outFile = process.argv[3] || '.tmp/session.json'

if (!PAT || !userId) {
  console.error('usage: SUPABASE_PAT=sbp_... node tools/authlink.mjs <user id> [out.json]')
  process.exit(2)
}

const mgmt = `https://api.supabase.com/v1/projects/${REF}`
const projectUrl = `https://${REF}.supabase.co`
const mgmtHeaders = { Authorization: `Bearer ${PAT}` }

const keysRes = await fetch(`${mgmt}/api-keys`, { headers: mgmtHeaders })
if (!keysRes.ok) {
  console.error(`api-keys: HTTP ${keysRes.status} ${await keysRes.text()}`)
  process.exit(1)
}
const keys = await keysRes.json()
const serviceKey = (keys.find((k) => k.name === 'service_role') || {}).api_key
if (!serviceKey) {
  console.error('no service_role key in the project')
  process.exit(1)
}

const adminHeaders = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  'Content-Type': 'application/json',
}

const userRes = await fetch(`${projectUrl}/auth/v1/admin/users/${userId}`, { headers: adminHeaders })
if (!userRes.ok) {
  console.error(`admin/users: HTTP ${userRes.status} ${await userRes.text()}`)
  process.exit(1)
}
const user = await userRes.json()
console.log(`user: ${user.email}`)

const linkRes = await fetch(`${projectUrl}/auth/v1/admin/generate_link`, {
  method: 'POST',
  headers: adminHeaders,
  body: JSON.stringify({ type: 'magiclink', email: user.email }),
})
if (!linkRes.ok) {
  console.error(`generate_link: HTTP ${linkRes.status} ${await linkRes.text()}`)
  process.exit(1)
}
const link = await linkRes.json()
const tokenHash = link.hashed_token || new URL(link.action_link).searchParams.get('token')
if (!tokenHash) {
  console.error('no token in the generated link')
  process.exit(1)
}

// Exchange it. redirect: 'manual' keeps the tokens in the Location header instead of following them to a page
// that may not be running.
const verifyRes = await fetch(`${projectUrl}/auth/v1/verify?token=${encodeURIComponent(tokenHash)}&type=magiclink`, {
  redirect: 'manual',
})
const location = verifyRes.headers.get('location') || ''
const fragment = location.includes('#') ? location.slice(location.indexOf('#') + 1) : ''
const params = new URLSearchParams(fragment)

const accessToken = params.get('access_token')
const refreshToken = params.get('refresh_token')
const expiresIn = Number(params.get('expires_in') || 3600)

if (!accessToken || !refreshToken) {
  console.error(`verify: HTTP ${verifyRes.status}, no tokens. location=${location.slice(0, 200)}`)
  process.exit(1)
}

// supabase-js v2 keeps a JSON-encoded session under this key.
const session = {
  access_token: accessToken,
  refresh_token: refreshToken,
  token_type: 'bearer',
  expires_in: expiresIn,
  expires_at: Math.floor(Date.now() / 1000) + expiresIn,
  user,
}

fs.mkdirSync(outFile.replace(/[\\/][^\\/]+$/, ''), { recursive: true })
fs.writeFileSync(
  outFile,
  JSON.stringify({ key: `sb-${REF}-auth-token`, value: JSON.stringify(session), userId }, null, 2),
)
console.log(`session written to ${outFile} (delete it when done)`)
