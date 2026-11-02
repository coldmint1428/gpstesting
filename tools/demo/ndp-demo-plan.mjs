// The presentation video's plan: a slice of the real NDP night, small enough to show and run on camera.
//
// It cuts the full NE4 plan (tools/qa/ndp-plan.mjs, from the 17 Jul Adjusted Show Matrix and the NDP 25 KML) down to
// a dozen groups and the stretch from just before Parade & Ceremony to the end of the Mobile Column, and moves T+0 to
// the start of that stretch. So "T+0 = Now" on the start panel puts the presenter at 17:54:50 show time, and the
// contingents are already marching onto the Padang, with the phone's Contingent 3 stepping off 30 s in.
//
// Each group starts the slice wherever the full plan has it at the cut, so the walks are the full plan's own steps
// and still keep the 25 m rule. The broken sheet is the same plan with one of P&C Contingent 3's steps moved 150 m,
// for showing the import refusing it.
//
//   TZ=UTC node tools/qa/ndp-plan.mjs <NE4 show matrix.xlsx> <NDP 25 Main.kml> .tmp/demo/NE4
//   node tools/demo/ndp-demo-plan.mjs .tmp/demo/NE4/plan.json docs/demo
// writes ndp-ne4-demo.csv, ndp-ne4-demo-broken.csv and ndp-ne4-demo-groups.json (names, headcounts, colours).
import fs from 'node:fs'
import path from 'node:path'

const [planPath, outDir] = process.argv.slice(2)
const full = JSON.parse(fs.readFileSync(planPath, 'utf8'))
fs.mkdirSync(outDir, { recursive: true })

const DOORS = 16 * 3600 // the plan's T+0 is the matrix's Doors Open, 16:00
const CUT = 17 * 3600 + 54 * 60 + 50 - DOORS // 17:54:50: Contingents 1 and 2 already marching, 3 steps off 30 s in
const END = 19 * 3600 + 30 * 60 - DOORS // 19:30, after the contingents march off
const KEEP = [
  'P&C Contingent 1', 'P&C Contingent 2', 'P&C Contingent 3', 'P&C Contingent 4',
  'Red Lions', 'Combined School Bands', 'Choir', 'Mobile Column',
  'Show Hosts', 'Motivators Red', 'Spectators Raffles City R1 A', 'Medical Team 1', 'Quick Response Team 1',
]
const clock = (t) => {
  const s = DOORS + CUT + t
  return [Math.floor(s / 3600), Math.floor((s % 3600) / 60), s % 60].map((n) => String(n).padStart(2, '0')).join(':')
}

// Where every kept group is at the cut: the last position the full plan states for it up to then
const at = new Map()
for (const f of full.frames) {
  if (f.t_s > CUT) break
  for (const g of KEEP) if (f.positions[g]) at.set(g, f.positions[g])
}
const missing = KEEP.filter((g) => !at.has(g))
if (missing.length) throw new Error('No position at the cut for ' + missing.join(', '))

const frames = [{ t_s: 0, note: 'Parade & Ceremony: contingents marching to the Padang (NE4 show matrix, 17:54:50)', positions: Object.fromEntries(at) }]
for (const f of full.frames) {
  if (f.t_s <= CUT || f.t_s > END) continue
  const positions = Object.fromEntries(Object.entries(f.positions).filter(([g]) => KEEP.includes(g)))
  if (Object.keys(positions).length) frames.push({ t_s: f.t_s - CUT, note: f.note, positions })
}

const cell = (v) => (/[",\r\n]/.test(String(v)) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v))
function sheet(list, title) {
  const rows = ['﻿# ' + title, 't_s,note,group,lat,lng,state,verify']
  for (const f of list) {
    let first = true
    for (const [g, p] of Object.entries(f.positions)) {
      rows.push([f.t_s, first ? cell(f.note) : '', cell(g), p.lat, p.lng, p.state, p.verify].join(','))
      first = false
    }
  }
  return rows
}

const title = 'NDP 2025 NE4 (show matrix 17 Jul), Parade & Ceremony to Mobile Column: t_s is seconds after 17:54:50 show time'
const good = sheet(frames, title)
fs.writeFileSync(path.join(outDir, 'ndp-ne4-demo.csv'), good.join('\r\n') + '\r\n')

// The broken sheet: Contingent 3's fifth step on its march to the Padang, 150 m north (0.00136 deg of latitude)
const broken = [...good]
const c3 = broken.map((r, i) => [r, i]).filter(([r]) => r.includes(',P&C Contingent 3,'))
const [row, index] = c3[5]
const parts = row.split(',')
const latCol = parts.length - 4
parts[latCol] = String(Number(parts[latCol]) + 0.00136)
broken[index] = parts.join(',')
fs.writeFileSync(path.join(outDir, 'ndp-ne4-demo-broken.csv'), broken.join('\r\n') + '\r\n')

const groups = full.groups.filter((g) => KEEP.includes(g.name)).map(({ name, category, headcount, colour }) => ({ name, category, headcount, colour }))
fs.writeFileSync(path.join(outDir, 'ndp-ne4-demo-groups.json'), JSON.stringify(groups, null, 2) + '\n')

const cues = frames.filter((f) => f.note).map((f) => `  T+${Math.floor(f.t_s / 60)}:${String(f.t_s % 60).padStart(2, '0')}  ${clock(f.t_s)}  ${f.note.slice(0, 70)}`)
console.log(`${groups.length} groups, ${groups.reduce((s, g) => s + g.headcount, 0)} people, ${frames.length} moments, T+0 = 17:54:50, last T+${Math.round(frames[frames.length - 1].t_s / 60)} min`)
console.log(`broken sheet: file row ${index + 1} (P&C Contingent 3, t_s ${parts[0]}) moved 150 m`)
console.log(cues.filter((c, i, a) => a.findIndex((x) => x.slice(22) === c.slice(22)) === i).join('\n'))
