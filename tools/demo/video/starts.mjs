// When each segment starts on the merged video's clock, and the take's actions on that same clock.
//
// The action log gives the moments to the hundredth of a second, but on the run's clock; the browser's recorder
// drifts against it unevenly (ahead in one part of a take, behind in another), so a moment from the log can be a
// second or two off on screen. Almost every segment opens a page as it starts, and a new page is a scene change in
// the video: each segment's start is snapped to the biggest scene change near where the log puts it, and that
// segment's actions move by the same amount. cues-merged.txt (whole seconds) is only the fallback for old takes.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')

const SNAP = 3 // look this far either side of the logged start for the first scene change
const NEAR = 1.5 // and after that, this far either side of where the drift so far puts it
const LEAD = 0.15 // and cut this long before the change, so the clip opens on the old page for a moment

function scenes(take) {
  const cache = path.join(take, 'scenes.json')
  const video = path.join(take, 'planova-demo-merged.mp4')
  if (fs.existsSync(cache) && fs.statSync(cache).mtimeMs > fs.statSync(video).mtimeMs) return JSON.parse(fs.readFileSync(cache, 'utf8'))
  const log = spawnSync(FF, ['-v', 'info', '-i', video, '-vf', 'scale=480:-1,scdet=threshold=2', '-an', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 64 << 20 }).stderr
  const out = [...log.matchAll(/lavfi\.scd\.score:\s*([\d.]+),\s*lavfi\.scd\.time:\s*([\d.]+)/g)].map((m) => ({ t: Number(m[2]), score: Number(m[1]) }))
  fs.writeFileSync(cache, JSON.stringify(out))
  return out
}

export function timeline(take) {
  const logFile = path.join(take, 'actions-merged.json')
  const actions = fs.existsSync(logFile) ? JSON.parse(fs.readFileSync(logFile, 'utf8')) : []
  const starts = {}
  for (const x of actions) if (x.what === 'segment start' && starts[x.seg] == null) starts[x.seg] = x.t
  if (!Object.keys(starts).length) {
    const sec = (s) => { const [m, x] = s.split(':').map(Number); return m * 60 + x }
    for (const l of fs.readFileSync(path.join(take, 'cues-merged.txt'), 'utf8').split('\n')) {
      const m = l.match(/^(\d+:\d+)\s+segment (\d+):/)
      if (m) starts[Number(m[2])] = sec(m[1])
    }
    return { starts, actions, shift: {} }
  }
  // A take with the corner clock (markers.json) is already exact: nothing to snap
  if (fs.existsSync(path.join(take, 'markers.json'))) return { starts, actions, shift: {} }
  const changes = fs.existsSync(path.join(take, 'planova-demo-merged.mp4')) ? scenes(take) : []
  const shift = {}
  let drift = 0 // the drift changes slowly: each start is looked for where the last one's drift puts it
  for (const [seg, t] of Object.entries(starts).sort((a, b) => a[1] - b[1])) {
    const n = Number(seg)
    // Only a segment that opens a page as it starts has a scene change to snap to
    const opens = actions.some((x) => x.seg === n && x.what.startsWith('open ') && x.t - t < 1.5)
    if (n === 1) continue
    if (!opens) { if (drift) { shift[n] = drift; starts[n] = t + drift } ; continue } // no page to snap to: carry the drift
    const within = Object.keys(shift).length ? NEAR : SNAP
    const near = changes.filter((c) => Math.abs(c.t - (t + drift)) <= within)
    if (!near.length) { if (drift) { shift[n] = drift; starts[n] = t + drift } ; continue }
    const best = near.reduce((a, c) => (c.score > a.score ? c : a))
    shift[n] = best.t - LEAD - t
    starts[n] = best.t - LEAD
    drift = shift[n]
  }
  const moved = actions.map((x) => (shift[x.seg] ? { ...x, t: Math.round((x.t + shift[x.seg]) * 100) / 100 } : x))
  return { starts, actions: moved, shift }
}

export const segmentStarts = (take) => timeline(take).starts
