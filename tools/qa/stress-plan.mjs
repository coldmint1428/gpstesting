// A stand-in for tools/qa/ndp-plan.mjs, for when the NDP show matrix (.xlsx) and map (.kml) are not on this laptop.
//
//   node tools/qa/stress-plan.mjs [out-dir]        (default .tmp/ndp; `npm run stress -- setup` runs it for you)
//
// Writes plan.json in exactly the shape ndp-plan.mjs writes ({ doorsOpen, groups, frames }), so loadtest-seed.mjs and
// loadtest.mjs take it unchanged. It is smaller than the real night: 20 groups around the Padang over 2 hours,
// with most of the movement in the first 30 minutes, which is when a stress run is watching. The group names that
// loadtest.mjs uses by name ('P&C Contingent 3', held for 3 min at 85% of a run) are kept.
//
// Same rules as ndp-plan.mjs: walks at 1.0 m/s (crowds), 1.3 m/s (contingents), 2 m/s (medics), cut into steps of at
// most 20 m on a 5-second grid, so no step breaks the plan's 25 m rule. It refuses to overwrite a real plan.json.
import fs from 'node:fs'
import path from 'node:path'

const outDir = process.argv[2] || '.tmp/ndp'
const outFile = path.join(outDir, 'plan.json')
if (fs.existsSync(outFile)) {
  const old = JSON.parse(fs.readFileSync(outFile, 'utf8'))
  if (!old.standIn) {
    console.log(`${outFile} is a real NDP plan (from ndp-plan.mjs): left alone.`)
    process.exit(0)
  }
}
fs.mkdirSync(outDir, { recursive: true })

// ---------- places, in metres east (x) and north (y) of the middle of the Padang ----------
const CENTRE = { lat: 1.2905, lng: 103.852 }
const at = (x, y) => ({ lat: CENTRE.lat + y / 110574, lng: CENTRE.lng + x / (111320 * Math.cos((CENTRE.lat * Math.PI) / 180)) })
const P = {
  cityHall: at(-150, 260),
  esplanade: at(360, -110),
  rafflesPlace: at(-60, -480),
  clarkeQuay: at(-680, -160),
  suntec: at(700, 450),
  casing: at(300, 250),
  gate: at(150, 110),
  north: at(0, 120),
  south: at(0, -120),
  east: at(150, 0),
  west: at(-150, 0),
  middle: at(0, 0),
  stage: at(200, -50),
  medical: at(-200, 150),
}

const metres = (a, b) => {
  const dy = (b.lat - a.lat) * 110574
  const dx = (b.lng - a.lng) * 111320 * Math.cos((a.lat * Math.PI) / 180)
  return Math.hypot(dx, dy)
}
const lerp = (a, b, f) => ({ lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f })
const last = (pts) => pts[pts.length - 1]
const nudge = (p, x, y) => ({ lat: p.lat + y / 110574, lng: p.lng + x / (111320 * Math.cos((p.lat * Math.PI) / 180)) })

// ---------- groups and their moves ----------
const PALETTE = ['#0072B2', '#56B4E9', '#009E73', '#CC79A7', '#6A4C93']
const groups = []
const moves = [] // { group, start, path, speed, note }
function group(name, category, headcount, start) {
  groups.push({ name, category, headcount, colour: PALETTE[groups.length % PALETTE.length], start })
  return name
}
function move(name, start, pts, speed, note) {
  moves.push({ group: name, start, path: pts, speed, note })
}

// Spectators: two waves from each of four stations into a sector, and home again near the end
const STATIONS = [['City Hall', P.cityHall, P.north], ['Esplanade', P.esplanade, P.east], ['Raffles Place', P.rafflesPlace, P.south], ['Clarke Quay', P.clarkeQuay, P.west]]
STATIONS.forEach(([name, from, sector], i) => {
  for (const wave of [0, 1]) {
    const g = group(`Spectators ${name} ${wave ? 'B' : 'A'}`, 'spectators', 25, from)
    const seat = nudge(sector, wave ? 20 : -20, wave ? -10 : 10)
    move(g, 60 * i + wave * 420, [from, seat], 1.0, `Gates open: ${name} ${wave ? 'second' : 'first'} wave`)
    move(g, 6000 + 60 * i, [seat, from], 1.0, `${name} spectators leave`)
  }
})

// Contingents: Suntec to the casing location, onto the Padang, and off again
for (let i = 1; i <= 8; i++) {
  const g = group(`P&C Contingent ${i}`, 'contingent', 30, P.suntec)
  const spot = nudge(P.middle, (i - 4.5) * 25, 40)
  move(g, 120 + i * 60, [P.suntec, P.casing], 1.3, 'Contingents to the casing location')
  move(g, 1080 + i * 60, [P.casing, P.gate, spot], 1.3, 'Parade & Ceremony: contingents march on')
  move(g, 4200 + i * 60, [spot, P.gate, P.casing], 1.3, 'Contingents march off')
}

const red = group('Motivators Red', 'motivators', 20, nudge(P.west, 0, -80))
move(red, 600, [nudge(P.west, 0, -80), P.north], 1.3, 'Motivators in positions')
move(red, 5400, [P.north, nudge(P.west, 0, -80)], 1.3, 'Motivators stand down')
const blue = group('Motivators Blue', 'motivators', 20, nudge(P.east, 0, 80))
move(blue, 600, [nudge(P.east, 0, 80), P.south], 1.3, 'Motivators in positions')
move(blue, 5400, [P.south, nudge(P.east, 0, 80)], 1.3, 'Motivators stand down')

const hosts = group('Show Hosts', 'hosts', 6, P.stage)
move(hosts, 900, [P.stage, P.middle], 1.3, 'Host entrance')
move(hosts, 3600, [P.middle, P.stage], 1.3, 'Hosts off')

const qrt = group('Quick Response Team', 'medical', 6, P.medical)
move(qrt, 1500, [P.medical, P.middle], 2.0, 'QRT forward for the contingents')
move(qrt, 3000, [P.middle, P.medical], 2.0, 'QRT back to the medical post')

// ---------- frames on a 5-second grid, steps of at most 20 m (as ndp-plan.mjs) ----------
const GRID = 5
const STEP = 20
const positions = new Map()
const notes = new Map()
const put = (t, g, p) => {
  if (!positions.has(t)) positions.set(t, new Map())
  positions.get(t).set(g, p)
}
for (const g of groups) put(0, g.name, g.start)
notes.set(0, 'Doors open')

const where = new Map(groups.map((g) => [g.name, g.start]))
const lastT = new Map()
for (const m of [...moves].sort((a, b) => a.start - b.start)) {
  const from = where.get(m.group)
  if (metres(from, m.path[0]) > 1) m.path = [from, ...m.path]
  where.set(m.group, last(m.path))
  m.start = Math.max(m.start, (lastT.get(m.group) ?? -GRID) + GRID)
  let t = Math.round(m.start / GRID) * GRID
  notes.set(t, notes.get(t) || m.note)
  put(t, m.group, m.path[0])
  let carried = 0
  for (let i = 1; i < m.path.length; i++) {
    const a = m.path[i - 1]
    const b = m.path[i]
    const d = metres(a, b)
    const n = Math.max(1, Math.ceil(d / STEP))
    for (let k = 1; k <= n; k++) {
      carried += d / n / m.speed
      t = Math.max(t + GRID, Math.round((m.start + carried) / GRID) * GRID)
      put(t, m.group, lerp(a, b, k / n))
    }
  }
  lastT.set(m.group, t)
}

const frames = [...positions.keys()]
  .sort((a, b) => a - b)
  .map((t) => ({
    t_s: t,
    note: notes.get(t) || '',
    positions: Object.fromEntries([...positions.get(t)].map(([g, p]) => [g, { lat: p.lat, lng: p.lng, state: 'on_site', verify: 'auto' }])),
  }))

const lastAt = new Map()
let worst = 0
for (const f of frames) {
  for (const [g, p] of Object.entries(f.positions)) {
    if (lastAt.has(g)) worst = Math.max(worst, metres(lastAt.get(g), p))
    lastAt.set(g, p)
  }
}
if (worst > 25) throw new Error(`A step is ${worst.toFixed(1)} m, over the 25 m rule`)

fs.writeFileSync(outFile, JSON.stringify({ standIn: true, doorsOpen: 'T+0', groups, frames }))
const heads = groups.reduce((s, g) => s + g.headcount, 0)
console.log(`Stand-in plan: ${groups.length} groups, ${heads} people, ${frames.length} moments, last at T+${frames[frames.length - 1].t_s}s, worst step ${worst.toFixed(1)} m -> ${outFile}`)
