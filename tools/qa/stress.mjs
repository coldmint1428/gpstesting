// The stress tests ST1-ST12 (docs/stress-testing/STRESS-TEST-PLAN.md) on the team's load test, one command each.
// Step by step for the people at the screens: docs/stress-testing/GUIDE.md.
//
//   npm run stress -- setup [--users 60] [--fresh]      accounts, plan and the load-test event (once)
//   npm run stress -- st1 [--minutes 30] [--users 50] [--switches 5] [--ramp 120] [--yes]
//   npm run stress -- end                               end the load-test event by hand (if anything went wrong)
//
// st1 is ST1 + ST2 + ST5 + ST12 in one run: tools/qa/loadtest.mjs with END_AT_FINISH, REFRESH_TOKENS and
// REPUBLISH_EVERY_S set, then a results file in docs/stress-testing/results/.
//
// What setup makes, only if the team's own .tmp/qa-accounts.json is not on this laptop:
//   - three staff accounts (stress_root, stress_planner, stress_marshal) and loadtest-0001..N@planova.test, all with
//     STRESS_PHONE_PASSWORD from .env.stress, written to .tmp/qa-accounts.json the way the team's QA setup does;
//   - a stand-in plan (stress-plan.mjs) when the NDP show matrix has not been turned into .tmp/ndp/plan.json.
// Then loadtest-seed.mjs makes the event, and testuser2 + testuser3 (planners) and kayken (a member) join it, so
// A, B and C can watch it on the website. Everything in .tmp is git-ignored; no password is ever written in code.
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createInterface } from 'node:readline/promises'
import { createClient } from '@supabase/supabase-js'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
process.chdir(ROOT) // the team's scripts read and write .tmp/... relative to the repo

const ACCOUNTS = '.tmp/qa-accounts.json'
const MADE = '.tmp/stress-accounts-made.json'
const PLAN = '.tmp/ndp/plan.json'
const SEED = '.tmp/loadtest/seed.json'
const SESSIONS = '.tmp/loadtest/sessions.json'
const STAFF = '.tmp/e2e-sessions.json'
const RESULTS = 'docs/stress-testing/results'
const MADE_BY = 'npm run stress -- setup'

// ---------- settings ----------
function readEnvFile(file) {
  const out = {}
  if (!fs.existsSync(file)) return out
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '')
  }
  return out
}
const env = { ...readEnvFile('.env'), ...readEnvFile('.env.stress'), ...process.env }
function need(name) {
  if (!env[name]) throw new Error(`${name} is not set. Put it in .env.stress (docs/stress-testing/GUIDE.md, step 0).`)
  return env[name]
}
const URL_ = need('VITE_SUPABASE_URL')
const KEY = need('VITE_SUPABASE_ANON_KEY')
const anon = () => createClient(URL_, KEY, { auth: { persistSession: false, autoRefreshToken: false } })

const readJson = (file, fallback) => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : fallback)
const writeJson = (file, data) => {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(data, null, 1))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const num = (v, fallback) => (v === undefined || v === true || Number.isNaN(Number(v)) ? fallback : Number(v))

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue
    const key = argv[i].slice(2)
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) out[key] = argv[++i]
    else out[key] = true
  }
  return out
}

// Nothing heavy starts without a person pressing Enter (or --yes)
async function confirm(text, args) {
  console.log('\n' + text)
  if (args.yes) return
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  const answer = await rl.question('Press Enter to go on, or type n and Enter to stop: ')
  rl.close()
  if (answer.trim().toLowerCase().startsWith('n')) {
    console.log('Stopped. Nothing was changed.')
    process.exit(0)
  }
}

// Supabase limits sign-ups and sign-ins from one address (Authentication -> Rate Limits): wait and try again
async function patiently(what, fn) {
  for (let attempt = 0; ; attempt++) {
    const r = await fn()
    if (!r.error || r.error.status !== 429 || attempt >= 60) return r
    if (attempt === 0) console.log(`  (Supabase is limiting ${what}s from this laptop: waiting 15 s and trying again, as long as it takes)`)
    await sleep(15000)
  }
}

// A login may be an email or a username, like the login page
async function signIn(login, password, label) {
  const sb = anon()
  let email = login
  if (!login.includes('@')) {
    const { data, error } = await sb.rpc('login_email', { p_username: login })
    if (error || !data) throw new Error(`${label}: no account with the username ${login}`)
    email = data
  }
  const { data, error } = await patiently('sign-in', () => sb.auth.signInWithPassword({ email, password }))
  if (error) throw new Error(`${label}: sign-in failed (${error.message})`)
  await sb.auth.setSession(data.session)
  return { sb, user: data.user }
}

// The child scripts: node <file> with extra environment, sharing this terminal
function run(file, extraEnv = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [file], { stdio: 'inherit', env: { ...process.env, ...extraEnv } })
    child.on('exit', (code) => resolve(code ?? 1))
  })
}

// ---------- accounts ----------
const STAFF_ACCOUNTS = {
  root: { email: 'stress-root@planova-stress.test', username: 'stress_root' },
  planner: { email: 'stress-planner@planova-stress.test', username: 'stress_planner' },
  marshal: { email: 'stress-marshal@planova-stress.test', username: 'stress_marshal' },
}
const loadtestEmail = (i) => `loadtest-${String(i).padStart(4, '0')}@planova.test`

async function ensureAccount(email, username, password, made) {
  if (made.has(email)) return
  const sb = anon()
  const up = await patiently('sign-up', () => sb.auth.signUp({ email, password, options: { data: { username, first_name: 'Stress', last_name: username } } }))
  if (!up.error) {
    if (!up.data.session) throw new Error(`${email} was made but needs its email confirmed. Turn off "Confirm email" (Supabase -> Authentication -> Sign In / Providers -> Email).`)
  } else if (/already (been )?registered|already exists/i.test(up.error.message)) {
    const si = await patiently('sign-in', () => sb.auth.signInWithPassword({ email, password }))
    if (si.error) throw new Error(`${email} already exists with another password (made by someone else?). Ask the team for their .tmp/qa-accounts.json, or delete that account in Supabase -> Authentication -> Users.`)
  } else {
    throw new Error(`${email}: could not make the account (${up.error.message})`)
  }
  made.add(email)
  writeJson(MADE, [...made])
}

// A session that is good for at least `needMs` more: refreshed when possible, signed in otherwise
async function fresh(old, email, password, needMs) {
  if (old && old.expires_at && old.expires_at * 1000 > Date.now() + needMs) return old
  if (old && old.refresh_token) {
    const r = await anon().auth.refreshSession({ refresh_token: old.refresh_token })
    if (!r.error && r.data.session) return r.data.session
  }
  const r = await patiently('sign-in', () => anon().auth.signInWithPassword({ email, password }))
  if (r.error) throw new Error(`${email}: sign-in failed (${r.error.message})`)
  return r.data.session
}

async function freshenSessions(seed, users, needMs) {
  const accounts = readJson(ACCOUNTS)
  const staff = readJson(STAFF, {})
  for (const who of ['root', 'planner', 'marshal']) {
    staff[who] = await fresh(staff[who], accounts.users[who].email, accounts.password, needMs)
  }
  writeJson(STAFF, staff)
  const sessions = readJson(SESSIONS, {})
  let n = 0
  for (const p of seed.people.slice(0, users)) {
    const s = await fresh(sessions[p.id], p.email, accounts.password, needMs)
    sessions[p.id] = { access_token: s.access_token, refresh_token: s.refresh_token, expires_at: s.expires_at }
    if (++n % 25 === 0) console.log(`  ${n} of ${users} sign-ins ready`)
  }
  writeJson(SESSIONS, sessions)
}

const rootClient = async () => (await import(pathToFileURL(path.join(ROOT, 'e2e/support/session.js')).href)).clientFor('root')

// ---------- setup ----------
async function setup(args) {
  const users = num(args.users, 60)
  const existing = readJson(ACCOUNTS, null)
  const theirs = existing && existing.madeBy !== MADE_BY
  const seed = readJson(SEED, null)

  await confirm(
    'Setup for the stress tests:\n' +
      (theirs
        ? `  - using the team's QA accounts in ${ACCOUNTS}\n`
        : `  - make (or check) 3 staff accounts and ${users} people loadtest-0001..${String(users).padStart(4, '0')}@planova.test,\n` +
          '    all with STRESS_PHONE_PASSWORD (throwaway accounts, like the stress_phone ones)\n') +
      (fs.existsSync(PLAN) ? `  - the plan in ${PLAN} is already there\n` : '  - write a stand-in NDP plan (20 groups, 2 hours) to .tmp/ndp/plan.json\n') +
      (seed && !args.fresh
        ? `  - the load-test event is already there (${seed.people.length} people)\n`
        : `  - make the event "QA-LOADTEST NDP 2025 NE4" with the plan published, and have ${users} people join it\n`) +
      '  - testuser2 and testuser3 join as planners, kayken as a member of P&C Contingent 1',
    args,
  )

  if (!theirs) {
    const password = need('STRESS_PHONE_PASSWORD')
    writeJson(ACCOUNTS, { madeBy: MADE_BY, password, users: STAFF_ACCOUNTS })
    const made = new Set(readJson(MADE, []))
    console.log('Accounts...')
    for (const a of Object.values(STAFF_ACCOUNTS)) await ensureAccount(a.email, a.username, password, made)
    for (let i = 1; i <= users; i++) {
      await ensureAccount(loadtestEmail(i), `loadtest_${String(i).padStart(4, '0')}`, password, made)
      if (i % 10 === 0) console.log(`  ${i} of ${users} people`)
    }
  }

  if (!fs.existsSync(PLAN)) {
    if ((await run('tools/qa/stress-plan.mjs')) !== 0) throw new Error('The stand-in plan could not be written')
  }

  if (seed && args.fresh) {
    const { sb } = await rootClient()
    await sb.rpc('end_event', { p_event_id: seed.eventId })
    const old = SEED.replace('.json', `-${Date.now()}.json`)
    fs.renameSync(SEED, old)
    console.log(`The old event's details are kept in ${old}; a new event is made.`)
  }
  if (!fs.existsSync(SEED)) {
    console.log('Making the event (loadtest-seed.mjs)...')
    if ((await run('tools/qa/loadtest-seed.mjs', { USERS: String(users) })) !== 0) throw new Error('loadtest-seed.mjs stopped with an error (above)')
  } else if (readJson(SEED).people.length < users) {
    console.log(`The event has ${readJson(SEED).people.length} people. For ${users}, run: npm run stress -- setup --users ${users} --fresh`)
  }

  // A, B and C on the website
  const s = readJson(SEED)
  const { sb: root } = await rootClient()
  for (const [login, pass, label] of [
    ['STRESS_PLANNER_LOGIN', 'STRESS_PLANNER_PASSWORD', 'planner (A)'],
    ['STRESS_PLANNER2_LOGIN', 'STRESS_PLANNER2_PASSWORD', 'second planner (C)'],
  ]) {
    const who = await signIn(need(login), need(pass), label)
    await who.sb.rpc('join_event', { p_code: s.joinCode })
    const { data: roles } = await root.from('event_roles').select('role').eq('event_id', s.eventId).eq('user_id', who.user.id)
    if (!(roles || []).some((r) => r.role === 'planner')) {
      const r = await root.rpc('set_member_role', { p_event_id: s.eventId, p_user_id: who.user.id, p_new_role: 'planner' })
      if (r.error) throw new Error(`${label}: could not be made a planner (${r.error.message})`)
    }
    console.log(`${env[login]} is a planner`)
  }
  const member = await signIn(need('STRESS_MEMBER_LOGIN'), need('STRESS_MEMBER_PASSWORD'), 'member (B)')
  await member.sb.rpc('join_event', { p_code: s.joinCode })
  const groupId = s.groups['P&C Contingent 1'] || Object.values(s.groups)[0]
  const { data: gm } = await root.from('group_members').select('group_id').eq('event_id', s.eventId).eq('user_id', member.user.id)
  if (!(gm || []).length) {
    const r = await root.rpc('add_event_member', { p_event_id: s.eventId, p_user_id: member.user.id, p_group_id: groupId })
    if (r.error) throw new Error(`member (B): could not be put in a group (${r.error.message})`)
  }
  console.log(`${env.STRESS_MEMBER_LOGIN} is a member of P&C Contingent 1`)
  console.log(`\nReady: ${s.people.length} people, ${s.people.filter((p) => p.isIC).length} of them ICs. On the website: Events -> "QA-LOADTEST NDP 2025 NE4" (join code ${s.joinCode}).`)
}

// ---------- the functions a run needs (a missing one means a migration is not applied) ----------
const NEEDED = {
  plan_ops: { p_session: null },
  session_timetable: { p_session: null },
  plan_log_list: { p_plan: null, p_limit: 1 },
  frame_shift: { p_plan: null, p_from_s: 0, p_delta_s: 0, p_to_s: null },
  frame_hold: { p_plan: null, p_frame: null, p_seconds: 0, p_groups: [] },
  plan_publish: { p_plan: null, p_plan_rev: 0 },
  plan_broadcast: { p_plan: null, p_body: '', p_audience: 'all', p_group: null },
  start_tracking_pass: { p_event_id: null, p_group_id: null },
  latest_locations: { p_event_id: null },
}
async function preflight(sb) {
  const missing = []
  for (const [fn, a] of Object.entries(NEEDED)) {
    const { error } = await sb.rpc(fn, a)
    if (error && (error.code === 'PGRST202' || /could not find the function/i.test(error.message))) missing.push(fn)
  }
  if (missing.length) throw new Error(`These database functions are missing on the live project: ${missing.join(', ')}. Apply supabase/migrations (npm run db:status) first.`)
}

// ---------- st1: ST1 + ST2 + ST5 + ST12 ----------
async function st1(args) {
  const seed = readJson(SEED, null)
  if (!seed) throw new Error('No load-test event yet. Run: npm run stress -- setup')
  const minutes = num(args.minutes, 30)
  const users = Math.min(num(args.users, seed.people.length), seed.people.length)
  const switches = num(args.switches, 5)
  const ramp = num(args.ramp, 120)
  const ics = seed.people.slice(0, users).filter((p) => p.isIC).length
  const durationS = Math.round(minutes * 60)
  const republishEvery = switches > 0 ? Math.floor(durationS / (switches + 1)) : 0

  const { sb: root } = await rootClient()
  await preflight(root)

  await confirm(
    `ST1 + ST2 + ST5 + ST12 on "QA-LOADTEST NDP 2025 NE4" (join code ${seed.joinCode}):\n` +
      `  - ${users} people for ${minutes} min; ${ics} of them are ICs sending a reading every 5 s over the internet\n` +
      `    (about ${Math.round((ics * durationS) / 5).toLocaleString()} readings, under 1 MB)\n` +
      `  - people arrive over ${ramp} s; ${Math.round(users * 0.08) + 3} of them keep the live map open\n` +
      `  - the planner: whole night +5 min at ${Math.round(minutes * 0.55)} min, a message to everyone at ${Math.round(minutes * 0.7)} min,\n` +
      `    one contingent held 3 min at ${Math.round(minutes * 0.85)} min` +
      (switches ? `, and ${switches} republishes (+30 s each, every ${Math.round(republishEvery / 60)} min)\n` : '\n') +
      '  - at the end, on Ctrl+C or on a crash, the event is ended\n' +
      'Before you press Enter: tell the team, check db_size.sql says under 300 MB, and open the live map (GUIDE.md).',
    args,
  )

  console.log('Getting sign-ins ready...')
  await freshenSessions(seed, users, 20 * 60000)

  const started = Date.now()
  const ignore = () => {}
  process.on('SIGINT', ignore) // Ctrl+C reaches the load test too; it stops early, writes its results and ends the event
  const code = await run('tools/qa/loadtest.mjs', {
    USERS: String(users),
    DURATION_S: String(durationS),
    RAMP_S: String(ramp),
    END_AT_FINISH: '1',
    REFRESH_TOKENS: '1',
    REPUBLISH_EVERY_S: String(republishEvery),
  })
  process.off('SIGINT', ignore)

  // Second safety net: whatever happened above, no session of this event is left live. (A new client: the run renewed
  // root's sign-in and spent the old one.)
  const { sb: rootAfter } = await rootClient()
  const { data: live } = await rootAfter.from('event_sessions').select('id').eq('event_id', seed.eventId).is('ended_at', null)
  if (live && live.length) {
    const r = await rootAfter.rpc('end_event', { p_event_id: seed.eventId })
    console.log(r.error ? `COULD NOT END THE EVENT: ${r.error.message}. End it on the website now.` : 'The event was still live: ended it.')
  }

  const files = fs.readdirSync('.tmp/loadtest').filter((f) => /^result-\d+\.json$/.test(f) && fs.statSync(path.join('.tmp/loadtest', f)).mtimeMs >= started)
  if (!files.length) throw new Error(`The load test stopped (exit ${code}) without writing results. The event is ended; see the messages above.`)
  const file = path.join('.tmp/loadtest', files.sort().pop())
  const md = writeReport(JSON.parse(fs.readFileSync(file, 'utf8')), file, { minutes, users, ics, switches })
  console.log(`\nResults: ${md}\nNext: paste its SQL into Supabase -> SQL Editor and fill in the hand tables (GUIDE.md, "After it finishes").`)
}

// ---------- results ----------
const SG = 'Asia/Singapore'
const sgDate = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: SG, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
const sgClock = (d) => new Intl.DateTimeFormat('en-GB', { timeZone: SG, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(d)
const mark = (ok) => (ok === null || ok === undefined ? '➖ record only' : ok ? '✅ pass' : '❌ fail')
const ms = (x) => (x === null || x === undefined ? '–' : x >= 10000 ? (x / 1000).toFixed(1) + ' s' : Math.round(x) + ' ms')

function writeReport(r, jsonPath, { minutes, users, ics, switches }) {
  const op = (name) => r.ops[name]
  const delay = (name) => (r.realtime.delays || {})[name]
  const from = new Date(r.startedAt)
  const to = new Date(r.at)
  const rl = op('report_location')
  const po = op('plan_ops')
  const map = delay('location reached a map')
  const bc = op('plan_broadcast (under load)')
  const reps = (r.stress && r.stress.republishes) || []

  const okReadings = rl ? rl.errors === 0 : false
  const okOps = po ? po.errors === 0 && 5000 + po.p95 < 10000 : false
  const okMap = map ? map.p95 < 10000 && r.realtime.failed === 0 : false
  const okReps = switches ? reps.length >= switches && reps.every((e) => !e.error && e.within30s >= e.activeThen) : null

  const sql = fs
    .readFileSync('tools/qa/sql/tick_timing.sql', 'utf8')
    .split(/\r?\n/)
    .filter((l) => !l.startsWith('--'))
    .join('\n')
    .replace('{{FROM}}', from.toISOString())
    .replace('{{TO}}', to.toISOString())
    .trim()

  const slowest = Object.entries(r.ops)
    .sort((a, b) => (b[1].p95 ?? 0) - (a[1].p95 ?? 0))
    .slice(0, 15)
    .map(([k, o]) => `| ${k} | ${o.n} | ${o.errors} | ${ms(o.p50)} | ${ms(o.p95)} | ${ms(o.max)} |`)
  const errors = Object.entries(r.ops).flatMap(([k, o]) => Object.entries(o.errorKinds || {}).map(([e, n]) => `| ${k} | ${n} | ${e.replace(/\|/g, '/')} |`))

  const L = [
    `# ST1 + ST2 + ST5 + ST12 results, ${sgDate(from)}`,
    '',
    `Run ${sgClock(from)} to ${sgClock(to)} SGT (${minutes} min), event ${r.eventId}, session ${r.session}.`,
    `${users} people, ${ics} of them ICs sending a reading every 5 s over the internet. ${r.totals.calls.toLocaleString()} calls, ${r.totals.errors} errors, ${(r.totals.readingsStored ?? 0).toLocaleString()} readings stored.`,
    `Event ended at the end: ${r.stress && r.stress.endAtFinish ? 'yes (checked again after the run)' : 'no'}. Raw numbers: \`${path.basename(jsonPath)}\` next to this file.`,
    '',
    '## ST1 · Volume',
    '',
    '| Tester Plan line | Measured | |',
    '|---|---|---|',
    `| Every phone reading accepted | report_location: ${rl ? `${rl.n} ok, ${rl.errors} errors, p50 ${ms(rl.p50)}, p95 ${ms(rl.p95)}` : 'none sent'} | ${mark(okReadings)} |`,
    `| Needs attention updates within 10 s | plan_ops every 5 s, p95 ${ms(po && po.p95)} (${po ? po.errors : '–'} errors), so at worst 5 s + ${ms(po && po.p95)} | ${mark(okOps)} |`,
    '| Engine tick on time | paste the SQL below: `gps-plan-push` p95_s under 2 and failed 0 | ⬜ fill in |',
    '',
    '**SQL Editor** (Supabase → SQL Editor → paste → Run), then paste the result table under it:',
    '',
    '```sql',
    sql,
    '```',
    '',
    'Result:',
    '',
    '```',
    '(paste here)',
    '```',
    '',
    'Database size before / after (`tools/qa/sql/db_size.sql`): ___ MB / ___ MB',
    '',
    '## ST2 · Many viewers',
    '',
    '| Tester Plan line | Measured | |',
    '|---|---|---|',
    `| A reading reaches an open map within 10 s | ${map ? `${map.n} arrivals, p50 ${ms(map.p50)}, p95 ${ms(map.p95)}, max ${ms(map.max)}` : 'no map arrivals'} | ${mark(okMap)} |`,
    `| No viewer dropped | realtime channels joined ${r.realtime.joined}, failed ${r.realtime.failed} | ${mark(r.realtime.failed === 0)} |`,
    '',
    'By hand (every 5 minutes):',
    '',
    '| Minute | A: fps on the laptop | B: smooth / slow / stuck | C: smooth / slow / stuck |',
    '|---|---|---|---|',
    ...[5, 10, 15, 20, 25, 30].filter((m) => m <= minutes).map((m) => `| +${m} | | | |`),
    '',
    'Supabase → Reports → Database (CPU, memory) and Realtime (messages, connections) for the run: screenshots next to this file.',
    '',
    '## ST5 · Push burst',
    '',
    `Message to everyone at ${Math.round(minutes * 0.7)} min: ${bc ? (bc.errors ? `❌ refused (${Object.keys(bc.errorKinds).join('; ')})` : `sent in ${ms(bc.p50)}`) : 'not sent: the run ended first (the planner waits for its earlier plan changes, so a slow database delays it)'}.`,
    '',
    '| Message | Recipients | Tapped Got it |',
    '|---|---|---|',
    ...(r.acks || []).map((a) => `| ${a.kind}: ${(a.body || '').replace(/\|/g, '/')} | ${a.recipients ?? '–'} | ${a.acked ?? '–'} |`),
    '',
    '| Phone | Time on the notification | Within 10 s of the send? |',
    '|---|---|---|',
    '| B (kayken) | | |',
    '| C | | |',
    '',
    '## ST12 · Many publishes',
    '',
    `Pass: every republish accepted, and every phone open at the time heard it within 30 s. ${mark(okReps)}`,
    '',
    '| # | At (SGT) | Accepted | Phones open | Heard within 30 s | p95 | slowest |',
    '|---|---|---|---|---|---|---|',
    ...reps.map((e) => `| ${e.n} | ${sgClock(new Date(e.at))} | ${e.error ? '❌ ' + e.error : '✅'} | ${e.activeThen} | ${e.within30s} | ${ms(e.p95)} | ${ms(e.max)} |`),
    '',
    `Also measured: a plan change reaching a phone p95 ${ms(delay('plans UPDATE reached a phone') && delay('plans UPDATE reached a phone').p95)}; the phone re-reading its timetable after it p95 ${ms(delay('timetable re-read after a publish') && delay('timetable re-read after a publish').p95)}.`,
    '',
    '## Every call, slowest first',
    '',
    '| Call | ok | errors | p50 | p95 | max |',
    '|---|---|---|---|---|---|',
    ...slowest,
    '',
    ...(errors.length ? ['### Errors', '', '| Call | Count | Message |', '|---|---|---|', ...errors, ''] : []),
    '## Notes from A, B and C',
    '',
    '- A:',
    '- B:',
    '- C:',
  ]
  fs.mkdirSync(RESULTS, { recursive: true })
  const stamp = sgDate(from) + 'T' + sgClock(from).slice(0, 5).replace(':', '')
  const base = path.join(RESULTS, `ST1-ST2-ST5-ST12-${stamp}`)
  fs.copyFileSync(jsonPath, base + '.json')
  fs.writeFileSync(base + '.md', L.join('\n') + '\n')
  return base + '.md'
}

// ---------- end ----------
async function end() {
  const seed = readJson(SEED, null)
  if (!seed) return console.log('No load-test event on this laptop.')
  const { sb } = await rootClient()
  const r = await sb.rpc('end_event', { p_event_id: seed.eventId })
  console.log(r.error ? `Could not end it: ${r.error.message}` : 'The load-test event is ended.')
}

const COMMANDS = { setup, st1, end }
const [name, ...rest] = process.argv.slice(2)
const command = COMMANDS[(name || '').toLowerCase()]
if (!command) {
  console.log('Usage: npm run stress -- <setup | st1 | end> [options]   (docs/stress-testing/GUIDE.md)')
  process.exit(name ? 1 : 0)
}
command(parseArgs(rest)).then(
  () => process.exit(0),
  (e) => {
    console.error('\n' + (e && e.message ? e.message : e))
    process.exit(1)
  },
)
