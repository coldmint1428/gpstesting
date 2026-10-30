// An NDP night as a Planova plan, for the stress and scenario tests.
//
// The times come from the NDP 2025 NE4 Adjusted Show Matrix (17 Jul): every moment the plan has is a row of that sheet
// (Doors Open, Host Entrance, Parade & Ceremony, Mobile Column, each act's formations, the finale), so a group moves
// when the real show moves it. The routes come from the NDP 25 Main map (KML): the spectator flows from Clarke Quay,
// Raffles City, Esplanade and Raffles Place MRT, the P&C, Mobile Column and Show Management movement routes, the
// Padang AO points and the medical posts. T+0 is the matrix's Doors Open.
//
// Each route is walked at a believable pace (crowds 1.0 m/s, contingents 1.3 m/s, vehicles 4 m/s) and cut into steps
// of at most 20 m, under the plan's 25 m rule, on a 5-second grid.
//
//   TZ=UTC node tools/qa/ndp-plan.mjs <show-matrix.xlsx> <ndp.kml> <out-dir>
// writes plan.json (groups + frames, the shape plan_import takes once group names are swapped for ids) and plan.csv
// (the board's own sheet format, for importing through the app).
import fs from 'node:fs'
import path from 'node:path'
import ExcelJS from 'exceljs'

if (process.env.TZ !== 'UTC') throw new Error('Run with TZ=UTC: ExcelJS turns the sheet\'s times into dates in the local zone')
const [xlsxPath, kmlPath, outDir] = process.argv.slice(2)
fs.mkdirSync(outDir, { recursive: true })

// ---------- the show matrix: programme name -> seconds after Doors Open ----------
const wb = new ExcelJS.Workbook()
await wb.xlsx.readFile(xlsxPath)
const ws = wb.worksheets[0]
const text = (v) => (v && v.richText ? v.richText.map((r) => r.text).join('') : v == null ? '' : String(v)).replace(/\s+/g, ' ').trim()
const secs = (v) => {
  const x = v && typeof v === 'object' && 'result' in v ? v.result : v
  if (x instanceof Date) return Math.round(((x.getTime() - Date.UTC(1899, 11, 30)) / 1000) % 86400)
  if (typeof x === 'number') return Math.round((x % 1) * 86400)
  return null
}
const rows = []
ws.eachRow((r) => {
  const at = secs(r.getCell(1).value)
  const prog = text(r.getCell(5).value)
  if (at != null && prog) rows.push({ at, prog })
})
const doorsOpen = rows.find((r) => /Doors Open/i.test(r.prog)).at
const cue = (pattern, after = 0) => {
  const row = rows.find((r) => pattern.test(r.prog) && r.at - doorsOpen >= after)
  if (!row) throw new Error('No show matrix row matches ' + pattern)
  return { t: row.at - doorsOpen, note: row.prog.slice(0, 80) }
}
const clock = (t) => {
  const s = doorsOpen + t
  return `${String(Math.floor(s / 3600)).padStart(2, '0')}:${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}`
}

// ---------- the map ----------
const kml = fs.readFileSync(kmlPath, 'utf8')
const placemarks = [...kml.matchAll(/<Placemark[^>]*>([\s\S]*?)<\/Placemark>/g)].map((m) => {
  const name = (m[1].match(/<name>([^<]*)<\/name>/) || [])[1] || ''
  const coords = (m[1].match(/<coordinates>\s*([^<]*)<\/coordinates>/) || [])[1] || ''
  const pts = coords.trim().split(/\s+/).filter(Boolean).map((p) => {
    const [lng, lat] = p.split(',').map(Number)
    return { lat, lng }
  })
  return { name: name.trim(), pts }
})
const place = (name) => {
  const hit = placemarks.find((p) => p.name === name)
  if (!hit) throw new Error('No placemark called ' + name)
  return hit.pts
}
const point = (name) => place(name)[0]

const metres = (a, b) => {
  const dy = (b.lat - a.lat) * 110574
  const dx = (b.lng - a.lng) * 111320 * Math.cos((a.lat * Math.PI) / 180)
  return Math.hypot(dx, dy)
}
const lerp = (a, b, f) => ({ lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f })

// ---------- groups and their moves ----------
const PALETTE = ['#0072B2', '#56B4E9', '#009E73', '#CC79A7', '#6A4C93']
const groups = []
const moves = [] // { group, start, path: [{lat,lng}], speed, note }

function group(name, category, headcount, start) {
  groups.push({ name, category, headcount, colour: PALETTE[groups.length % PALETTE.length], start })
  return name
}
function move(name, at, pts, speed, note) {
  moves.push({ group: name, start: at, path: pts, speed, note })
}

const reverse = (pts) => [...pts].reverse()
const last = (pts) => pts[pts.length - 1]

// Spectators: two waves down each spectator flow, from the station to the Padang
const FLOWS = ['Clarke Quay MRT', 'Raffles City - R1', 'Raffles City R2', 'Raffles City R3', 'Raffles City R4', 'Esplanade 1', 'Esplanade 2', 'Raffles Place MRT', 'Raffles Place MRT 2']
FLOWS.forEach((flow, i) => {
  for (const wave of [0, 1]) {
    const pts = place(flow)
    const g = group(`Spectators ${flow.replace(' - ', ' ').replace(' MRT', '')} ${wave ? 'B' : 'A'}`, 'spectators', 25, pts[0])
    move(g, 120 * i + wave * 1500, pts, 1.0, `Gates open: ${flow} flow ${wave ? 'second' : 'first'} wave`)
  }
})

// Motivators to their four sectors at "Theme Song MV / Motivators in positions" (no time in the sheet: 30 min after doors)
const SECTORS = [['Red', 'P7', 'P9'], ['Green', 'P2', 'P3'], ['Yellow', 'P5', 'P6'], ['Blue', 'P10', 'P11']]
for (const [colour, from, to] of SECTORS) {
  const g = group(`Motivators ${colour}`, 'motivators', 20, point(from))
  move(g, 1800, [point(from), point(to)], 1.3, 'Motivators in positions')
}

// Show hosts enter together and split to their sectors
const hosts = group('Show Hosts', 'hosts', 6, point('P1'))
const hostIn = cue(/Host Entrance Announcement/)
move(hosts, hostIn.t, [point('P1'), point('P2'), point('P3'), point('P7')], 1.3, hostIn.note)

// Show management crew: in from Suntec at doors open, back after the broadcast ends
const sm = group('Show Management Crew', 'crew', 30, place('Suntec to Padang')[0])
move(sm, 0, place('Suntec to Padang'), 1.3, 'Show management crew to the Padang')

// Parade & Ceremony contingents: Suntec to the casing location, casing to the Padang for P&C, back out after
const pc = cue(/^Parade & Ceremony/)
const mc = cue(/^Mobile Column/)
for (let i = 1; i <= 8; i++) {
  const g = group(`P&C Contingent ${i}`, 'contingent', 30, place('Suntec to Casing Location')[0])
  move(g, 900 + i * 90, place('Suntec to Casing Location'), 1.3, 'Contingents to the casing location')
  move(g, pc.t - 1200 + i * 60, place('Casing Location to Padang'), 1.3, pc.note)
  move(g, mc.t + 600 + i * 60, place('Padang to Casing Location'), 1.3, 'Contingents march off')
}

// Mobile Column: the vehicle route, at vehicle pace
const mcGroup = group('Mobile Column', 'vehicles', 40, place('MC movement route')[0])
move(mcGroup, mc.t - 600, place('MC movement route'), 4, mc.note)

// Red Lions land and move to the salute line
const rl = cue(/^RL TOT/)
const redLions = group('Red Lions', 'performers', 7, point('P9'))
move(redLions, rl.t + 120, [point('P9'), point('P4')], 1.3, cue(/Combined Salute/).note)

// Performers: in to their formation at their act, out at its end
const PERFORMERS = [
  ['Combined School Bands', /Combined School Marching Bands/, 'P13', 'P11'],
  ['Choir', /Padang Audience Placard Feature \+ Choir/, 'P16', 'P8'],
  ['RP Dancers', /Film 1 - Character Prelude/, 'P14', 'P10'],
  ['SOKA Dancers', /^Choir Feature/, 'P17', 'P9'],
  ['PA Dancers', /Film 3A/, 'P18', 'P10'],
  ['MOE Dancers', /The Road Ahead/, 'P19', 'P11'],
  ['SMU Drummers', /Drum Feature/, 'P15', 'P8'],
]
for (const [name, pattern, from, to] of PERFORMERS) {
  const c = cue(pattern)
  const g = group(name, 'performers', 40, point(from))
  move(g, c.t - 180, [point(from), point(to)], 1.3, c.note)
  move(g, c.t + 420, [point(to), point(from)], 1.3, `${name} exit`)
}

// Medical teams stay at their posts; the QRTs stand by and run to the Padang at the finale crowd surge
for (const post of ['Medical Post 1', 'Medical Post 2', 'VVIP Medical Post']) group(post.replace('Medical Post', 'Medical Team'), 'medical', 8, point(post))
const fin = cue(/Fireworks Medley/)
for (const q of ['QRT 1', 'QRT 2']) {
  const g = group(`Quick Response Team ${q.slice(-1)}`, 'medical', 6, point(q))
  move(g, fin.t, [point(q), point('P12')], 2.0, 'Finale: QRT forward to the Padang')
}
move(sm, cue(/End of Broadcast/).t + 300, place('Padang to Suntec (1)'), 1.3, 'Show management crew out')

// ---------- cut every move into steps of at most 20 m on a 5 s grid ----------
const GRID = 5
const STEP = 20
const positions = new Map() // t_s -> Map(group -> {lat,lng})
const notes = new Map()
const put = (t, g, p) => {
  if (!positions.has(t)) positions.set(t, new Map())
  positions.get(t).set(g, p)
}
for (const g of groups) put(0, g.name, g.start)
notes.set(0, 'Doors Open / House BGM')

// A move starts from wherever the group is: a route that begins elsewhere gets the walk to its start first
const at = new Map(groups.map((g) => [g.name, g.start]))
const lastT = new Map()
for (const m of [...moves].sort((a, b) => a.start - b.start)) {
  const from = at.get(m.group)
  if (metres(from, m.path[0]) > 1) m.path = [from, ...m.path]
  at.set(m.group, last(m.path))
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
      const at = Math.round((m.start + carried) / GRID) * GRID
      t = Math.max(t + GRID, at)
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

// The 25 m rule, checked here so a bad step is this script's error and not the board's
const lastAt = new Map()
let worst = 0
for (const f of frames) {
  for (const [g, p] of Object.entries(f.positions)) {
    if (lastAt.has(g)) worst = Math.max(worst, metres(lastAt.get(g), p))
    lastAt.set(g, p)
  }
}
if (worst > 25) throw new Error(`A step is ${worst.toFixed(1)} m, over the 25 m rule`)

const csv = ['﻿# NDP 2025 NE4 (show matrix 17 Jul): t_s is seconds after Doors Open ' + clock(0), 't_s,note,group,lat,lng,state,verify']
const cell = (v) => (/[",\r\n]/.test(String(v)) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v))
for (const f of frames) {
  let first = true
  for (const [g, p] of Object.entries(f.positions)) {
    csv.push([f.t_s, first ? cell(f.note) : '', cell(g), p.lat, p.lng, p.state, p.verify].join(','))
    first = false
  }
}
fs.writeFileSync(path.join(outDir, 'plan.csv'), csv.join('\r\n') + '\r\n')
fs.writeFileSync(path.join(outDir, 'plan.json'), JSON.stringify({ doorsOpen: clock(0), groups, frames }, null, 0))

const heads = groups.reduce((s, g) => s + g.headcount, 0)
console.log(`${groups.length} groups, ${heads} people, ${frames.length} frames, ${frames.reduce((s, f) => s + Object.keys(f.positions).length, 0)} positions`)
console.log(`T+0 = ${clock(0)}, last moment T+${frames[frames.length - 1].t_s}s (${clock(frames[frames.length - 1].t_s)}), worst step ${worst.toFixed(1)} m`)
