// The presentation video, played by a script: the run sheet's laptop segments in a real, visible Chrome window that
// records itself (1920 x 1080), the IC's phone view in a second, phone-sized window, and the other people in the story
// (the IC walking to the Padang, the cadet's SOS and replies) played by the QA accounts. Each segment is held to its
// slot in the run sheet, so the narration can be laid over it, and a cue sheet says where each one starts.
//
//   node tools/demo/director.mjs [--base https://gpstesting.vercel.app] [--event <id>] [--only 1,2,3] [--no-video] [--shots] [--phone] [--phone-user <user id>] [--paced]
//
// --phone also records the USB phone's screen (adb screenrecord, 3-minute clips back to back) for the whole run.
// Videos, the cue sheet and any failure screenshots go to .tmp/demo-run/<time>/. A fresh demo event is made first
// (tools/demo/seed-ndp-demo.mjs), so every run starts from the same place; the event the wizard makes is deleted after.
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync, spawn } from 'node:child_process'
import { chromium } from '@playwright/test'
import { contextAs, clientFor, qa, SUPABASE_URL, ANON_KEY } from '../../e2e/support/session.js'

const arg = (name, fallback) => {
  const i = process.argv.indexOf('--' + name)
  return i < 0 ? fallback : process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : true
}
const BASE = arg('base', 'https://gpstesting.vercel.app')
const ONLY = arg('only', '') ? String(arg('only')).split(',').map(Number) : null
const VIDEO = !arg('no-video', false)
const PHONE = !!arg('phone', false)
// The account signed in on the USB phone: made a planner for segment 13, so the phone shows the planner's tabs
const PHONE_USER = arg('phone-user', '') || null
// Tight by default: no padding to the narration slots, and plain pauses cut to 2 s (--paced keeps the slots)
const TIGHT = !arg('paced', false)
// --shots: a screenshot of the laptop at the end of every segment, to check what a quiet skip left on screen
const SHOTS = !!arg('shots', false)
const OUT = path.join('.tmp', 'demo-run', new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19))
fs.mkdirSync(OUT, { recursive: true })
const ADB = path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk', 'platform-tools', 'adb.exe')

// ---------- the event: a fresh copy of the NE4 rehearsal, or --event <id> made earlier so a phone can join first ----------
const seedOut = arg('event', '') ? `event ${arg('event')}\njoin code (made earlier)` : execFileSync('node', ['tools/demo/seed-ndp-demo.mjs'], { encoding: 'utf8' })
const EV = seedOut.match(/event ([0-9a-f-]{36})/)[1]
const CODE = seedOut.match(/join code (.+)/)[1]
const { sb: rootSb } = await clientFor('root')
const groupId = async (name) => (await rootSb.from('groups').select('id').eq('event_id', EV).eq('name', name).single()).data.id
console.log(`demo event ${EV} (code ${CODE}) — output in ${OUT}`)

// ---------- the windows ----------
const browser = await chromium.launch({ headless: false, args: ['--window-position=0,0'] })
const video = (w, h) => (VIDEO ? { recordVideo: { dir: OUT, size: { width: w, height: h } } } : {})
const laptop = await contextAs(browser, 'root', BASE, { viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1, ...video(1920, 1080) })
const phoneCtx = await contextAs(browser, 'ic1', BASE, {
  viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true,
  geolocation: { latitude: 1.29111, longitude: 103.85591, accuracy: 8 }, permissions: ['geolocation'], ...video(780, 1688),
})
// A visible cursor: Playwright's own is not drawn, and viewers need to see what is pressed
const CURSOR = `addEventListener('DOMContentLoaded', () => {
  const c = document.createElement('div')
  c.style.cssText = 'position:fixed;z-index:2147483647;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;background:rgba(198,243,107,.55);border:2px solid #0a1f17;pointer-events:none;transition:transform .08s;left:-40px;top:-40px'
  document.body.appendChild(c)
  addEventListener('mousemove', (e) => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px' }, true)
  addEventListener('mousedown', () => (c.style.transform = 'scale(.7)'), true)
  addEventListener('mouseup', () => (c.style.transform = ''), true)
})`
await laptop.addInitScript(CURSOR)
await phoneCtx.addInitScript(CURSOR) // the IC's window: a dot where the finger lands
const page = await laptop.newPage()
const ic = await phoneCtx.newPage()

// ---------- helpers ----------
const wait = (ms) => page.waitForTimeout(TIGHT ? Math.min(ms, 2000) : ms)
const icWait = (ms) => ic.waitForTimeout(TIGHT ? Math.min(ms, 2500) : ms)
// Something is moving on screen (the plan playing, the IC walking): shorter, but long enough to see it
const watch = (ms) => page.waitForTimeout(TIGHT ? ms * 0.6 : ms)
// A person's hand, not a robot's: the cursor travels on a gentle curve, quick then slowing as it arrives, lands
// somewhere inside the button rather than its exact middle, and hesitates a moment before it clicks; typing has the
// uneven rhythm of real keys, a little slower after a space or a comma.
const rand = (a, b) => a + Math.random() * (b - a)
let mouse = { x: 960, y: 540 }
async function point(locator) {
  const el = locator.first()
  await el.scrollIntoViewIfNeeded()
  const b = await el.boundingBox()
  const at = { x: b.width * rand(0.35, 0.65), y: b.height * rand(0.35, 0.65) } // where in the element
  const to = { x: b.x + at.x, y: b.y + at.y }
  const from = mouse
  const dist = Math.hypot(to.x - from.x, to.y - from.y)
  const steps = Math.max(10, Math.min(45, Math.round(dist / 18)))
  // A control point off to one side of the straight line: the path bows a little, the way a wrist moves
  const bow = rand(-0.18, 0.18) * dist
  const mid = { x: (from.x + to.x) / 2 - ((to.y - from.y) / (dist || 1)) * bow, y: (from.y + to.y) / 2 + ((to.x - from.x) / (dist || 1)) * bow }
  for (let i = 1; i <= steps; i++) {
    const t = 1 - (1 - i / steps) ** 3 // ease out: fast start, careful arrival
    const x = (1 - t) ** 2 * from.x + 2 * (1 - t) * t * mid.x + t ** 2 * to.x
    const y = (1 - t) ** 2 * from.y + 2 * (1 - t) * t * mid.y + t ** 2 * to.y
    await page.mouse.move(x, y)
    await page.waitForTimeout(8)
  }
  mouse = to
  el.__at = at
  return el
}
async function press(locator, pause = 500) {
  const el = await point(locator)
  await page.waitForTimeout(rand(140, 320))
  // Playwright's click still waits for the control to be ready (Publish is disabled while the board is busy)
  await el.click({ position: el.__at })
  await wait(pause)
  return el
}
async function write(locator, text) {
  const el = await press(locator, 150)
  await el.fill('')
  for (const ch of text) {
    await page.keyboard.type(ch)
    await page.waitForTimeout(/[ ,.]/.test(ch) ? rand(90, 180) : rand(35, 95))
  }
  await wait(300)
}
const byId = (id, p = page) => p.getByTestId(id)
async function confirmIfAsked(p = page) {
  const ok = p.getByTestId('confirm-ok')
  // Some confirms open after a server call (the broadcast counts its recipients first), so wait for one
  if (await ok.waitFor({ state: 'visible', timeout: 4000 }).then(() => true, () => false)) {
    if (p === page) await press(ok, 800)
    else await ok.click()
  }
}

// ---------- the IC's walk, from the casing location to the Padang (the NDP 25 map's route, straight) ----------
const CASING = { lat: 1.29110796, lng: 103.85590897 }
const PADANG = { lat: 1.28976508, lng: 103.85331845 }
let walking = null
function startWalk(seconds = TIGHT ? 60 : 150) {
  let i = 0
  const steps = Math.round(seconds / 5)
  walking = setInterval(() => {
    const f = Math.min(1, i++ / steps)
    phoneCtx.setGeolocation({ latitude: CASING.lat + (PADANG.lat - CASING.lat) * f, longitude: CASING.lng + (PADANG.lng - CASING.lng) * f, accuracy: 8 }).catch(() => {})
  }, 5000)
}

// ---------- the phone over USB ----------
let phoneRec = null
let phoneClip = 0
function adb(...a) {
  return execFileSync(ADB, a, { encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } })
}
function recordPhone() {
  adb('shell', 'settings', 'put', 'system', 'show_touches', '1')
  const next = () => {
    const name = `/sdcard/planova-demo-${String(++phoneClip).padStart(2, '0')}.mp4`
    phoneRec = spawn(ADB, ['shell', 'screenrecord', '--size', '1080x2340', '--bit-rate', '8000000', '--time-limit', '180', name])
    phoneRec.on('exit', () => phoneRec && next())
  }
  next()
}
function stopPhone() {
  const rec = phoneRec
  phoneRec = null
  if (rec) rec.kill('SIGINT')
  try {
    adb('shell', 'pkill', '-INT', 'screenrecord')
  } catch {}
  execFileSync('node', ['-e', 'setTimeout(()=>{},2500)'])
  for (let i = 1; i <= phoneClip; i++) {
    const name = `planova-demo-${String(i).padStart(2, '0')}.mp4`
    try {
      adb('pull', '/sdcard/' + name, path.join(OUT, 'phone-' + name))
      adb('shell', 'rm', '/sdcard/' + name)
    } catch {}
  }
  try {
    adb('shell', 'settings', 'put', 'system', 'show_touches', '0')
  } catch {}
}

// ---------- the segments, as in the run sheet (docs/demo/planova-demo-script.html; slot in seconds) ----------
let wizardEvent = null
// The phone app's bottom tabs, as fractions of the screen: the web view's contents are not in Android's UI dump, so
// a tab is tapped by where it sits (five tabs, measured on a 1080 x 2340 screen; they scale with the screen)
const TAB_X = [0.13, 0.314, 0.5, 0.682, 0.867]
const TAB_Y = 0.89
function phoneTapTab(index) {
  const m = adb('shell', 'wm', 'size').match(/(\d+)x(\d+)/)
  if (!m) return false
  const [w, h] = [Number(m[1]), Number(m[2])]
  adb('shell', 'input', 'tap', String(Math.round(w * TAB_X[index])), String(Math.round(h * TAB_Y)))
  return true
}
// A rehearsal a few days before the event (090: a rehearsal goes before the event day), at 6 pm Singapore time
async function rehearsalBefore() {
  const { data: event } = await rootSb.from('events').select('starts_at').eq('id', EV).single()
  const day = new Date(new Date(event.starts_at).getTime() - 3 * 86400_000)
  const sg = new Date(Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), 10, 0, 0)) // 18:00 SGT
  return { starts_at: sg.toISOString(), ends_at: new Date(sg.getTime() + 3 * 3600_000).toISOString() }
}
const SEGMENTS = [
  [1, 'Intro, roles and how it works', 50, async () => {
    await page.goto('/')
    await wait(3000)
    await page.goto('/events')
    await wait(3000)
    await point(page.getByText('NDP 2025 NE4 Rehearsal').first())
  }],
  [2, 'Create an event', 40, async () => {
    await page.goto('/events/new')
    await write(byId('wiz-name'), 'NDP Rehearsal 4')
    await write(byId('wiz-venue'), 'The Padang')
    const sat = new Date()
    sat.setDate(sat.getDate() + ((6 - sat.getDay() + 7) % 7 || 7))
    const local = (d, h) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}T${h}:00`
    await byId('wiz-start').fill(local(sat, '18'))
    await byId('wiz-end').fill(local(sat, '22'))
    await press(byId('wiz-next'))
    for (const who of ['ic1', 'member']) {
      await write(byId('wiz-email'), qa(who).email)
      await press(byId('wiz-email-add'), 900)
    }
    await press(byId('wiz-next'))
    for (const g of ['Navy', 'Air Force']) {
      await write(byId('wiz-group-name'), g)
      await press(byId('wiz-add-group'))
    }
    const groups = byId('wiz-groups')
    const addAll = groups.getByRole('button', { name: /Add all|Add everyone/ })
    if (await addAll.count()) await press(addAll)
    else for (let i = 0; i < 2; i++) await press(groups.getByRole('button', { name: 'Add', exact: true }))
    await groups.locator('li, div', { hasText: /^QA Ic1/ }).getByLabel('IC').first().check().catch(() => {})
    await press(byId('wiz-next'))
    await wait(1500)
    await press(byId('wiz-confirm'))
    await page.waitForURL(/\/events\/[0-9a-f-]{36}/, { timeout: 30_000 })
    wizardEvent = page.url().match(/events\/([0-9a-f-]{36})/)[1]
    await wait(3000)
  }],
  [3, 'Draw the venue', 40, async () => {
    await page.goto(`/events/${EV}/map`)
    const draw = page.getByRole('button', { name: 'Draw area' })
    await draw.waitFor({ timeout: 30_000 })
    // The map flies from its first view to the event's areas: corners placed mid-flight land in the wrong place, so
    // wait until the areas are drawn and the map has stopped moving
    await page.locator('.bench-map path.leaflet-interactive').first().waitFor({ timeout: 30_000 }).catch(() => {})
    let last = null
    for (let i = 0; i < 20; i++) {
      const b = await page.locator('.bench-map path.leaflet-interactive').first().boundingBox().catch(() => null)
      const key = b && [b.x, b.y, b.width].map(Math.round).join(',')
      if (key && key === last) break
      last = key
      await page.waitForTimeout(400)
    }
    await wait(800)
    await press(draw)
    const map = page.locator('.bench-map')
    const box = await map.boundingBox()
    for (const [fx, fy] of [[0.6, 0.5], [0.74, 0.5], [0.74, 0.66], [0.6, 0.66], [0.6, 0.5]]) {
      const to = { x: box.x + box.width * fx, y: box.y + box.height * fy }
      await page.mouse.move(to.x, to.y, { steps: 10 })
      await page.mouse.click(to.x, to.y)
      await wait(350)
    }
    await write(page.getByPlaceholder('e.g. Trees'), 'Esplanade Park')
    // Its type is picked while drawing: No-Go, so anyone walking in lights up on the live map
    const draftKind = byId('area-kind')
    if (await draftKind.isVisible().catch(() => false)) {
      await point(draftKind)
      await draftKind.selectOption('no_go').catch(() => {})
      await wait(800)
    }
    await press(page.getByRole('button', { name: 'Save area' }), 1200)
    const kind = byId('area-kind-select-Esplanade Park')
    if (await kind.count()) await kind.selectOption('no_go').catch(() => {})
    await wait(1200)
    await press(byId('area-lock-Padang'), 1500)
  }],
  [4, 'Build the timeline', 70, async () => {
    await page.goto(`/events/${EV}/timeline`)
    await byId('plan-picker').waitFor({ timeout: 30_000 })
    await wait(2000)
    for (const file of ['ndp-ne4-demo.csv']) { // no distance rule since 091: a long jump is not refused, so no broken copy
      await press(byId('plan-more'))
      await point(byId('sheet-import'))
      await wait(400)
      await page.keyboard.press('Escape')
      await byId('sheet-file').setInputFiles(path.join('docs', 'demo', file))
      await wait(1500)
      await confirmIfAsked()
      await wait(8000)
      const dismiss = byId('plan-refusal-dismiss')
      if (await dismiss.isVisible().catch(() => false)) await press(dismiss)
    }
    // Play the night at 60x, then 120x: the contingents march onto the Padang
    await press(byId('play'))
    await watch(8000)
    const speed = byId('play-speed')
    if (await speed.isVisible().catch(() => false)) await speed.selectOption('120').catch(() => {})
    await watch(6000)
    await press(byId('play'))
    // Zoom keeps the open frame in view
    await press(byId('zoom-in'), 800)
    await press(byId('zoom-in'), 800)
    // A stretch of frames deleted at once, and one Undo brings it back
    const dots = page.locator('.pv-frame')
    if ((await dots.count()) > 12) {
      await dots.nth(8).click({ force: true })
      await dots.nth(11).click({ force: true, modifiers: ['Shift'] })
      await wait(800)
      const del = byId('frame-delete')
      if (await del.isVisible().catch(() => false)) {
        await press(del)
        await confirmIfAsked()
        await wait(2500)
        await press(byId('undo'), 2500)
      }
    }
    await press(byId('zoom-out'), 600)
    await press(byId('zoom-out'), 600)
  }],
  [5, 'Problems, and two planners at once', 45, async () => {
    // A second planner opens the board and nudges a badge: it moves here too, held for them while they drag
    const planner = await contextAs(browser, 'planner', BASE, { viewport: { width: 1280, height: 800 } })
    const pp = await planner.newPage()
    await pp.goto(`/events/${EV}/timeline`)
    await pp.locator('.pv-frame').nth(6).click({ timeout: 30_000, force: true })
    await pp.waitForTimeout(2000)
    await page.locator('.pv-frame').nth(6).click({ force: true }).catch(() => {})
    await wait(1500)
    const n = await pp.locator('.pv-map .pv-marker').first().boundingBox()
    if (n) {
      await pp.mouse.move(n.x + n.width / 2, n.y + n.height / 2)
      await pp.mouse.down()
      for (let i = 1; i <= 6; i++) await pp.mouse.move(n.x + n.width / 2 + 1.5 * i, n.y + n.height / 2 + 0.5 * i) // a few metres
      await pp.waitForTimeout(1500)
      await pp.mouse.up()
    }
    await wait(3000)
    await planner.close()
    // Then a badge walked straight through the No-Go area drawn in segment 3 (red, dashed): the Problems panel says so,
    // and Publish is locked until it's fixed. One Undo puts the badge back.
    const nogo = page.locator('.pv-map path[stroke="#DC2626"]').first()
    const z = (await nogo.count()) ? await nogo.boundingBox().catch(() => null) : null
    const m = await page.locator('.pv-map .pv-marker').nth(2).boundingBox()
    if (z && m) {
      await page.mouse.move(m.x + m.width / 2, m.y + m.height / 2, { steps: 10 })
      await page.mouse.down()
      const to = { x: z.x + z.width / 2, y: z.y + z.height / 2 }
      for (let i = 1; i <= 24; i++) await page.mouse.move(m.x + m.width / 2 + ((to.x - m.x - m.width / 2) * i) / 24, m.y + m.height / 2 + ((to.y - m.y - m.height / 2) * i) / 24)
      await page.mouse.up()
      mouse = to
      await wait(3500)
      const panel = byId('plan-problems')
      if (await panel.isVisible().catch(() => false)) await point(panel)
      await wait(2000)
      await point(byId('plan-publish')) // locked while there is an error
      await wait(1500)
      await press(byId('undo'), 2500)
    } else console.log('   (no No-Go area or badge on the timeline map to walk through)')
    await press(byId('plan-publish'), 1500)
    await confirmIfAsked()
    await wait(2500)
  }],
  [6, 'Groups and people', 30, async () => {
    await page.goto(`/events/${EV}/groups`)
    await wait(3000)
    await point(page.getByText('P&C Contingent 3').first())
    await wait(1500)
    await page.goto(`/events/${EV}/people`)
    await wait(2500)
    const search = byId('people-search')
    if (await search.isVisible().catch(() => false)) await write(search, 'QA')
    await wait(2500)
  }],
  [7, 'Rehearsals', 30, async () => {
    // One rehearsal on the calendar, before the event day; a cadet asks to be excused
    const when = await rehearsalBefore()
    const { data: rh } = await rootSb.from('event_rehearsals').insert({ event_id: EV, ...when, note: 'NE5: full dress rehearsal' }).select('id').single()
    await page.goto(`/events/${EV}/rehearsals`)
    await wait(2500)
    const edit = byId('rehearsal-edit')
    if (await edit.first().isVisible().catch(() => false)) {
      await press(edit.first())
      await write(byId('rehearsal-note'), 'NE5: full dress rehearsal, bring water')
      await press(byId('rehearsal-add'), 1500)
    }
    if (rh) {
      const { sb: memberSb } = await clientFor('member')
      await memberSb.rpc('rehearsal_absence_request', { p_rehearsal: rh.id, p_reason: 'School exam that evening' })
    }
    const requests = byId('rehearsal-tab-requests')
    if (await requests.isVisible().catch(() => false)) {
      await press(requests, 1500)
      const approve = byId('request-approve')
      if (await approve.first().isVisible().catch(() => false)) await press(approve.first(), 1500)
    }
  }],
  [8, 'Taking attendance', 35, async () => {
    await page.goto(`/events/${EV}/attendance`)
    await wait(2000)
    const qrMode = page.getByRole('button', { name: 'QR code', exact: true }).or(page.getByText('QR code', { exact: true }))
    if (await qrMode.first().isVisible().catch(() => false)) await press(qrMode.first(), 1200)
    await ic.goto(`/events/${EV}/attendance`)
    await byId('attendance-title', ic).fill('Casing location muster', { timeout: 30_000 })
    await byId('attendance-start', ic).click()
    await byId('attendance-qr', ic).waitFor({ timeout: 20_000 }).catch(() => {})
    await wait(4000)
    // The cadet scans the IC's code
    const { sb: icSb } = await clientFor('ic1')
    const { sb: memberSb } = await clientFor('member')
    const open = (await rootSb.from('attendance_rollcalls').select('id').eq('event_id', EV).is('closed_at', null).order('opened_at', { ascending: false }).limit(1)).data?.[0]
    if (open) {
      const { data: qr } = await icSb.rpc('rollcall_qr', { p_rollcall: open.id })
      if (qr) await memberSb.rpc('scan_rollcall', { p_rollcall: open.id, p_token: qr.token })
    }
    await wait(4000)
    const close = byId('attendance-close', ic)
    if (await close.isVisible().catch(() => false)) await close.click()
    await confirmIfAsked(ic)
  }],
  [9, 'Run it live', 55, async () => {
    await page.goto(`/events/${EV}/live`)
    await wait(2000)
    // Start waits for the plan list; on a slow load, reload once, as a person would
    const start = byId('start-event-btn')
    const ready = () => start.first().isEnabled({ timeout: 1000 }).catch(() => false)
    for (let i = 0; i < 30 && !(await ready()); i++) await page.waitForTimeout(1000)
    if (!(await ready())) {
      await page.reload()
      for (let i = 0; i < 30 && !(await ready()); i++) await page.waitForTimeout(1000)
    }
    await press(start)
    const engine = byId('start-engine')
    const opts = await engine.locator('option').allTextContents()
    const label = opts.find((o) => o.includes('NE4'))
    if (label) await engine.selectOption({ label }, { timeout: 5000 }).catch(() => {})
    await wait(800)
    await press(byId('start-confirm-btn'))
    await confirmIfAsked()
    await wait(3000)
    // The IC starts sharing on their phone, and walks
    await ic.goto(`/events/${EV}/live`)
    await byId('share-btn', ic).click({ timeout: 30_000 })
    await confirmIfAsked(ic)
    startWalk()
    const remind = byId('remind-ics-btn')
    if (await remind.isVisible().catch(() => false)) await press(remind, 1500)
    // The Live page opens on Operations: every group against the plan
    const ops = byId('live-tab-ops')
    if (await ops.isVisible().catch(() => false)) await press(ops, 3000)
    // The show slips: the salute moves a minute, and the plan is published again
    await page.goto(`/events/${EV}/timeline`)
    await wait(3000)
    const salute = page.locator('.pv-frame[title*="Combined Salute"]').first()
    if (await salute.count()) {
      await salute.scrollIntoViewIfNeeded()
      await point(salute)
      await salute.click({ force: true, timeout: 5000 }) // the dots around T+3m overlap
      await wait(800)
      await press(byId('push-60'))
      await confirmIfAsked()
      await wait(2500)
      await press(byId('plan-publish'))
      await confirmIfAsked()
    }
    await wait(2500)
  }],
  [10, 'What members and ICs see', 70, async () => {
    // The IC's phone window: the Schedule (route, stops, countdown), We're here, My group (this window has its own video)
    await ic.goto(`/events/${EV}/timeline`)
    await icWait(8000)
    const here = byId('sched-here', ic)
    if (await here.first().isVisible().catch(() => false)) await here.first().click()
    await icWait(5000)
    for (const p of ['groups', 'live']) { // the Map page is the planners' (3 Nov): the IC's route is on the Schedule
      await ic.goto(`/events/${EV}/${p}`)
      await icWait(6000)
    }
    // The laptop meanwhile shows Operations
    await page.goto(`/events/${EV}/live`)
    await wait(4000)
  }],
  [11, 'Live location', 35, async () => {
    await page.goto(`/events/${EV}/live`)
    await wait(3000)
    const people = byId('live-tab-people')
    if (await people.isVisible().catch(() => false)) await press(people, 1500)
    const badge = page.locator('.live-map .leaflet-marker-icon').first()
    if (await badge.isVisible().catch(() => false)) await press(badge, 3000)
    await watch(12_000)
  }],
  [12, 'Messages and SOS', 45, async () => {
    await page.goto(`/events/${EV}/live`)
    await wait(2000)
    const tab = byId('live-tab-message').or(page.getByRole('tab', { name: /Message/ }))
    if (await tab.first().isVisible().catch(() => false)) await press(tab.first())
    await write(byId('broadcast-body-input'), 'Red Lions running 1 min late. Hold salute positions.')
    await press(byId('broadcast-send'))
    await confirmIfAsked()
    await wait(2500)
    // The cadet's "Got it"
    const { sb: memberSb } = await clientFor('member')
    const last = (await rootSb.from('broadcasts').select('id').eq('event_id', EV).order('at', { ascending: false }).limit(1)).data?.[0]
    if (last) await memberSb.rpc('broadcast_mark', { p_id: last.id, p_ack: true })
    await wait(2500)
    // The cadet feels faint: SOS from the casing location
    const { data: sosId } = await memberSb.rpc('raise_sos', { p_event: EV, p_lat: CASING.lat, p_lng: CASING.lng, p_accuracy: 10, p_note: 'Feeling faint, heat' })
    await wait(3500)
    const show = byId('sos-show')
    if (await show.first().isVisible().catch(() => false)) await press(show.first(), 2500)
    const help = byId('sos-help')
    if (await help.first().isVisible().catch(() => false)) await press(help.first(), 3000)
    if (sosId) await memberSb.rpc('resolve_sos', { p_id: sosId })
    await wait(2500)
  }],
  [13, 'End and playback', 55, async () => {
    clearInterval(walking)
    await page.goto(`/events/${EV}/live`)
    await wait(2000)
    // Manage event → End event (the page has an End button per layout; only the shown one counts)
    const menu = byId('event-menu-btn')
    const end = page.getByTestId('end-event-btn').filter({ visible: true })
    for (let i = 0; i < 2; i++) {
      if (await end.first().isVisible().catch(() => false)) break
      if (await menu.isVisible().catch(() => false)) await press(menu, 800)
      await end.first().waitFor({ state: 'visible', timeout: 5000 }).catch(() => {})
    }
    await press(end)
    await write(byId('confirm-type'), 'END')
    await press(byId('confirm-ok'), 3000)
    await page.goto(`/events/${EV}/playback`)
    await wait(3000)
    // The run gets a proper name
    const more = byId('recording-menu')
    if (await more.first().waitFor({ state: 'visible', timeout: 10_000 }).then(() => true, () => false)) {
      await press(more.first())
      const rename = byId('rename-recording-btn')
      if (await rename.first().isVisible().catch(() => false)) {
        await press(rename.first())
        await write(byId('rename-recording-input'), 'NE4 full dress')
        await press(byId('rename-recording-save'), 1500)
      }
    }
    await press(byId('play-recording-btn'), 2500)
    // Drag to a moment two-thirds in, where the IC is on the move, then play from there
    const bar = byId('timeline')
    const tb = await bar.boundingBox().catch(() => null)
    if (tb) {
      await page.mouse.move(tb.x + 8, tb.y + tb.height / 2, { steps: 12 }) // the handle, at the start
      await page.mouse.down()
      await page.mouse.move(tb.x + tb.width * 0.66, tb.y + tb.height / 2, { steps: 25 })
      await page.mouse.up()
      mouse = { x: tb.x + tb.width * 0.66, y: tb.y + tb.height / 2 }
      await wait(1500)
    }
    await press(byId('play-btn'))
    await watch(8000)
    const trails = byId('trails-switch')
    if (await trails.isVisible().catch(() => false)) await press(trails, 2500)
    const follow = byId('follow-btn')
    if (await follow.first().isVisible().catch(() => false)) await press(follow.first(), 3000)
    const dl = byId('player-download')
    if (await dl.isVisible().catch(() => false)) await point(dl)
    await wait(1500)
  }],
  [14, "The planner's phone", 20, async () => {
    // The USB phone becomes a planner's: the root makes its account a planner, the open event page sees its role change
    // and swaps to the planner's tabs, and the phone is tapped through Ops, Map, Timeline and People. The laptop rests
    // on the Overview.
    await page.goto(`/events/${EV}/overview`)
    if (!PHONE || !PHONE_USER) return wait(3000)
    const { error } = await rootSb.rpc('set_member_role', { p_event_id: EV, p_user_id: PHONE_USER, p_new_role: 'planner' })
    if (error) throw new Error('making the phone a planner: ' + error.message)
    await page.waitForTimeout(4000)
    for (const index of [0, 1, 2, 3]) {
      if (!phoneTapTab(index)) console.log('   (no screen size from the phone)')
      await page.waitForTimeout(3500)
    }
  }],
  [15, 'How we tested it', 45, async () => {
    await page.goto(`/events/${EV}/overview`)
    await wait(3000)
  }],
  [16, 'Close', 20, async () => {
    await page.goto(`/events/${EV}/overview`)
    await wait(3000)
  }],
]

// ---------- run ----------
const cues = []
const t0 = Date.now()
const clock = (ms) => `${Math.floor(ms / 60000)}:${String(Math.floor((ms % 60000) / 1000)).padStart(2, '0')}`
if (PHONE) recordPhone()
try {
  await page.goto('/events')
  await page.waitForTimeout(2000)
  for (const [n, title, slot, run] of SEGMENTS) {
    if (ONLY && !ONLY.includes(n)) continue
    const start = Date.now()
    cues.push(`${clock(start - t0)}  segment ${n}: ${title}`)
    console.log(cues.at(-1))
    try {
      await run()
      if (SHOTS) await page.screenshot({ path: path.join(OUT, `seg-${String(n).padStart(2, '0')}.png`) }).catch(() => {})
    } catch (e) {
      const shot = path.join(OUT, `fail-${n}.png`)
      await page.screenshot({ path: shot }).catch(() => {})
      console.log(`   ! segment ${n} stopped early: ${String(e.message).split('\n')[0]} (${shot})`)
      cues.push(`        (segment ${n} stopped early: ${String(e.message).split('\n')[0]})`)
    }
    const left = slot * 1000 - (Date.now() - start)
    if (TIGHT) await page.waitForTimeout(1000)
    else if (left > 0) await page.waitForTimeout(left)
    else if (left < 0) console.log(`   segment ${n} ran ${Math.round(-left / 1000)} s over its ${slot} s slot`)
  }
} finally {
  clearInterval(walking)
  cues.push(`${clock(Date.now() - t0)}  end`)
  fs.writeFileSync(path.join(OUT, 'cues.txt'), cues.join('\n') + '\n')
  await page.close()
  await ic.close()
  await laptop.close()
  await phoneCtx.close()
  await browser.close()
  if (PHONE) stopPhone()
  if (wizardEvent) await rootSb.rpc('delete_event', { p_event_id: wizardEvent })
  console.log(`done: ${fs.readdirSync(OUT).join(', ')}`)
}
