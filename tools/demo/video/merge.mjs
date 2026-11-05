// node merge.mjs <run folder> [--keep-freezes]  -> <run folder>/planova-demo-merged.mp4
// Laptop screen at 1920x1080 with the real phone's screen inset bottom-right. Then any stretch where the whole
// picture stands still for more than HOLD seconds is cut down to HOLD seconds.
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { CUES } from './cues.mjs'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')
const FP = require('ffprobe-static').path

const dir = path.resolve(process.argv[2])
const KEEP = process.argv.includes('--keep-freezes')
const HOLD = 1.5 // seconds of a still screen that stay in
const LIMIT = 180 // adb screenrecord --time-limit
const probe = (f) => JSON.parse(execFileSync(FP, ['-v', 'error', '-show_entries', 'format=duration:format_tags=creation_time:stream=width,height', '-of', 'json', f], { encoding: 'utf8' }))
const files = fs.readdirSync(dir)

const laptop = files.filter((f) => f.endsWith('.webm')).map((f) => path.join(dir, f)).find((f) => probe(f).streams[0].width === 1920)
let lapDur = Number(probe(laptop).format.duration)
const end = fs.readFileSync(path.join(dir, 'cues.txt'), 'utf8').trim().split('\n').at(-1).match(/(\d+):(\d+)\s+end/)
const runLen = Number(end[1]) * 60 + Number(end[2])

// Phone clips: a still screen writes no frames, so a clip's length is not the time it covered. Each clip's
// creation_time is when it was saved (its end); every clip but the last ran the full time limit.
const clips = files.filter((f) => /^phone-.*\.mp4$/.test(f)).sort().map((f) => path.join(dir, f))
  .map((f) => { try { const p = probe(f); return { f, dur: Number(p.format.duration), end: Date.parse(p.format.tags.creation_time) / 1000 } } catch { return null } })
  .filter(Boolean)
clips.forEach((c, i) => { c.start = i < clips.length - 1 ? c.end - LIMIT : clips[i - 1] ? clips[i - 1].end + 1 : c.end - c.dur })
// Each clip covers until the next one starts (its last frame held); the last one until it ends
clips.forEach((c, i) => { c.span = clips[i + 1] ? clips[i + 1].start - c.start : Math.max(c.dur, c.end - c.start) })
// The run's 0:00 is when the first clip started recording; the laptop video started (lapDur - runLen) before it
// Where the run's 0:00 falls in the laptop video: noted by the recorder (timing.json); older takes, estimated
const timingFile = path.join(dir, 'timing.json')
const timing = fs.existsSync(timingFile) ? JSON.parse(fs.readFileSync(timingFile, 'utf8')) : null
let offset = timing ? -timing.laptopVideoAt : Math.max(0, lapDur - runLen)
// Playwright's recorder stretches its video (more frames than real time), and not evenly. The laptop video is squeezed
// back to the run's real clock: first from when its page opened and closed, then measured from the video itself.
// Every page the script opened (the action log's "open" entries) is a big change on screen, so each is matched to
// the nearest scene change in the video, and a straight line fitted through those pairs gives the exact mapping.
let lapReal = timing?.laptopClosedAt != null ? timing.laptopClosedAt - timing.laptopVideoAt : runLen + 1 + offset
let stretch = lapDur / lapReal
const RENDER = 0.4 // a page is on screen about this long after its navigation is logged
const opened = (fs.existsSync(path.join(dir, 'actions.json')) ? JSON.parse(fs.readFileSync(path.join(dir, 'actions.json'), 'utf8')) : [])
  .filter((x) => x.what.startsWith('open ')).map((x) => x.t + RENDER)
  .filter((t, i, all) => i === 0 || t - all[i - 1] > 1.5)
if (opened.length >= 6) {
  const scd = spawnSync(FF, ['-v', 'info', '-i', laptop, '-vf', 'scale=480:-1,scdet=threshold=12', '-an', '-f', 'null', '-'], { encoding: 'utf8' }).stderr
  const changes = [...scd.matchAll(/lavfi\.scd\.time:\s*([\d.]+)/g)].map((m) => Number(m[1]))
  let a = stretch * offset
  let b = stretch
  for (const window of [4, 2.5, 1.5, 1]) {
    const pairs = []
    for (const r of opened) {
      const pred = a + b * r
      let best = null
      for (const c of changes) if (Math.abs(c - pred) <= window && (best == null || Math.abs(c - pred) < Math.abs(best - pred))) best = c
      if (best != null) pairs.push([r, best])
    }
    if (pairs.length < 6) break
    const n = pairs.length
    const mr = pairs.reduce((s, p) => s + p[0], 0) / n
    const mv = pairs.reduce((s, p) => s + p[1], 0) / n
    b = pairs.reduce((s, p) => s + (p[0] - mr) * (p[1] - mv), 0) / pairs.reduce((s, p) => s + (p[0] - mr) ** 2, 0)
    a = mv - b * mr
    console.log(`clock fit (±${window} s): ${n} of ${opened.length} pages matched, video = ${a.toFixed(2)} + ${b.toFixed(4)} × run`)
  }
  stretch = b
  offset = a / b
  lapReal = lapDur / b
}
lapDur = lapReal

// ---------- the take's own clock, read from the video (director.mjs: the corner square) ----------
// Every logged action turned a 6 px square in the laptop window's top-left corner a colour that names it (red = 15 x
// segment, green = 40 + 53 x action number, modulo 200). Reading that square frame by frame gives the frame each
// action happened on, so the laptop video is warped back onto the run's clock exactly, however unevenly the recorder
// drifted. Takes from before the square fall back to the fitted clock above.
const RAW_FPS = 30
let warp = `(PTS-STARTPTS)/${stretch.toFixed(5)}` // the setpts expression that puts the laptop video on the run's clock
let marked = 0
const logged = fs.existsSync(path.join(dir, 'actions.json')) ? JSON.parse(fs.readFileSync(path.join(dir, 'actions.json'), 'utf8')) : []
if (logged.length && logged[0].k != null) {
  // The square's middle, its brightness frame by frame
  const px = execFileSync(FF, ['-v', 'error', '-i', laptop, '-vf', `fps=${RAW_FPS},crop=4:4:4:4,scale=1:1:flags=area,format=gray`, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], { maxBuffer: 1 << 28 })
  const frames = px.length
  const knots = [] // [run time, raw video time]
  let i = 0
  let drift = stretch * offset // raw video time = drift + stretch x run time, near enough to know where to look
  for (const x of logged) {
    const want = 16 + 16 * (x.k % 14)
    const pred = (drift + stretch * x.t) * RAW_FPS
    const from = Math.max(i, Math.floor(pred - 3 * RAW_FPS))
    const to = Math.min(frames - 1, Math.ceil(pred + 3 * RAW_FPS))
    let j = -1
    for (let n = from; n <= to; n++) if (Math.abs(px[n] - want) <= 5 && (n === 0 || Math.abs(px[n - 1] - want) > 5)) { j = n; break }
    if (j < 0) continue // shown for less than a frame, or not at all: the next action picks the clock up
    knots.push([x.t, j / RAW_FPS])
    drift = j / RAW_FPS - stretch * x.t
    i = j
  }
  // Keep the knots in step (each later than the one before on both clocks), and few enough for one expression
  const clean = []
  for (const k of knots) if (!clean.length || (k[0] > clean[clean.length - 1][0] + 0.3 && k[1] > clean[clean.length - 1][1] + 0.05)) clean.push(k)
  const keep = clean.length > 90 ? clean.filter((_, n) => n % Math.ceil(clean.length / 90) === 0 || n === clean.length - 1) : clean
  marked = knots.length
  if (keep.length >= 4) {
    // Raw video time T -> run time, a straight line between knots (and the first and last slopes carried on)
    const seg = (a, b) => `${a[0].toFixed(3)}+(T-${a[1].toFixed(3)})*${((b[0] - a[0]) / (b[1] - a[1])).toFixed(6)}`
    let expr = seg(keep[keep.length - 2], keep[keep.length - 1])
    for (let n = keep.length - 2; n >= 1; n--) expr = `if(lt(T,${keep[n][1].toFixed(3)}),${seg(keep[n - 1], keep[n])},${expr})`
    warp = `(${expr}+${offset.toFixed(3)})/TB`
    const lastRaw = Number(probe(laptop).format.duration)
    const toRun = (T) => { let a = keep[0], b = keep[1]; for (let n = 1; n < keep.length; n++) { a = keep[n - 1]; b = keep[n]; if (T < b[1]) break } return a[0] + (T - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) }
    lapDur = toRun(lastRaw) + offset
    fs.writeFileSync(path.join(dir, 'markers.json'), JSON.stringify({ seen: knots.length, of: logged.length, knots: keep }))
  }
  console.log(`corner clock: ${knots.length} of ${logged.length} actions seen in the video`)
}
const icOffset = timing ? offset + timing.icVideoAt : 0
const icFile = files.filter((f) => f.endsWith('.webm')).map((f) => path.join(dir, f)).find((f) => f !== laptop)
const icReal = timing?.icClosedAt != null ? timing.icClosedAt - timing.icVideoAt : lapReal - (timing ? timing.icVideoAt - timing.laptopVideoAt : 0)
const icStretch = icFile ? Number(probe(icFile).format.duration) / icReal : 1 // the IC window's video starts this long after the laptop's
console.log(`laptop ${lapDur.toFixed(1)} s of real time (recorded ${stretch.toFixed(3)}x), run ${runLen} s, phone at +${offset.toFixed(1)} s: ` + clips.map((c) => `${path.basename(c.f)} ${(c.start - clips[0].start).toFixed(0)}s+${c.span.toFixed(0)}s`).join(', '))

const H = 640
// The zoom: on each narrated click (cues.mjs) the laptop picture eases in towards it, holds, and eases back out,
// the way a launch video follows the action. Built on the laptop layer, before the phone goes on top.
const ZOOM = 0.26
const zoomAt = []
const actionsLog = fs.existsSync(path.join(dir, 'actions.json')) ? JSON.parse(fs.readFileSync(path.join(dir, 'actions.json'), 'utf8')) : []
for (const [seg, cues] of Object.entries(CUES)) {
  const segActs = actionsLog.filter((x) => x.seg === Number(seg) && x.x != null)
  for (const [act] of cues) {
    const hit = segActs.find((x) => act.test(x.what) && !zoomAt.some((z) => z.x0 === x))
    if (hit) zoomAt.push({ x0: hit, t: hit.t + offset, x: hit.x, y: hit.y })
  }
}
zoomAt.sort((a, b) => a.t - b.t)
// No two zooms overlap: one ends before the next starts
const bumps = []
for (const z of zoomAt) {
  const a = z.t - 0.7, b = z.t - 0.05, c = z.t + 1.6, d = z.t + 2.3
  if (bumps.length && a < bumps[bumps.length - 1].d) continue
  bumps.push({ a, b, c, d, x: z.x, y: z.y })
}
const S = (u) => `(3*pow(${u},2)-2*pow(${u},3))`
const env = (z) => `if(lt(it,${z.a.toFixed(2)}),0,if(lt(it,${z.b.toFixed(2)}),${S(`(it-${z.a.toFixed(2)})/${(z.b - z.a).toFixed(2)}`)},if(lt(it,${z.c.toFixed(2)}),1,if(lt(it,${z.d.toFixed(2)}),1-${S(`(it-${z.c.toFixed(2)})/${(z.d - z.c).toFixed(2)}`)},0))))`
const sum = (f) => bumps.length ? bumps.map(f).join('+') : '0'
const E = `(${sum(env)})`
const CX = bumps.length ? `((${sum((z) => `${env(z)}*${z.x}`)})+(1-${E})*960)` : '960'
const CY = bumps.length ? `((${sum((z) => `${env(z)}*${z.y}`)})+(1-${E})*540)` : '540'
const UP = 1.5 // the picture is worked on at 1.5x so the pan has no visible steps
const zoomFilter = bumps.length
  ? `scale=${1920 * UP}:${1080 * UP},zoompan=z='1+${ZOOM}*${E}':x='max(0,min(iw-iw/zoom,(${CX})*${UP}-iw/zoom/2))':y='max(0,min(ih-ih/zoom,(${CY})*${UP}-ih/zoom/2))':d=1:s=1920x1080:fps=30,`
  : ''
console.log(`${bumps.length} zooms on the narrated clicks`)
// When each inset shows: the real phone from segment 8 (attendance) on, except segment 10, which is the IC's phone
// window; segments 1-7 are the laptop alone (the phone has nothing to show before the event starts)
const cueRows = fs.readFileSync(path.join(dir, 'cues.txt'), 'utf8').split('\n').map((l) => l.match(/^(\d+):(\d+)\s+(?:segment (\d+)|end)/)).filter(Boolean)
  .map((m) => ({ t: Number(m[1]) * 60 + Number(m[2]) + offset, n: m[3] ? Number(m[3]) : null }))
const span = (n) => { const i = cueRows.findIndex((r) => r.n === n); return i < 0 ? null : [cueRows[i].t, (cueRows[i + 1] || { t: lapDur }).t] }
const when = (list) => list.map(span).filter(Boolean).map(([a, b]) => `between(t,${a.toFixed(2)},${b.toFixed(2)})`).join('+') || '0'
const PHONE_SEGS = [9, 11, 12, 13, 14]
const IC_SEGS = [8, 10]
const icVideo = files.filter((f) => f.endsWith('.webm')).map((f) => path.join(dir, f)).find((f) => f !== laptop)
const merged = path.join(dir, KEEP ? 'planova-demo-merged.mp4' : 'merged-untrimmed.mp4')
const parts = clips.map((c, i) => `[${i + 1}:v]setpts=PTS-STARTPTS,fps=30,scale=-2:${H},setsar=1,tpad=stop_mode=clone:stop_duration=${LIMIT},trim=duration=${c.span.toFixed(2)},setpts=PTS-STARTPTS[p${i}];`).join('')
execFileSync(FF, ['-y', '-v', 'error',
  '-i', laptop, ...clips.flatMap((c) => ['-i', c.f]), ...(icVideo ? ['-i', icVideo] : []),
  '-filter_complex',
  `[0:v]setpts='${warp}',fps=30,scale=1920:1080,drawbox=x=0:y=0:w=14:h=14:color=0xeef1ea:t=fill,${zoomFilter}setsar=1[bg];${parts}` +
  (clips.length ? `${clips.map((_, i) => `[p${i}]`).join('')}concat=n=${clips.length}:v=1:a=0,pad=iw+12:ih+12:6:6:color=0x1f2a24,setpts=PTS-STARTPTS+${offset.toFixed(2)}/TB[ph];` : '') +
  (icVideo ? `[${clips.length + 1}:v]setpts=(PTS-STARTPTS)/${icStretch.toFixed(5)},fps=30,scale=-2:${H},setsar=1,pad=iw+12:ih+12:6:6:color=0x1f2a24,setpts=PTS-STARTPTS+${icOffset.toFixed(2)}/TB[icw];` : '') +
  (clips.length ? `[bg][ph]overlay=W-w-24:H-h-24:eof_action=pass:enable='${when(PHONE_SEGS)}'[v1];` : '[bg]null[v1];') + // a take without the USB phone (--phone left off)
  (icVideo ? `[v1][icw]overlay=W-w-24:H-h-24:eof_action=pass:enable='${when(IC_SEGS)}'[v]` : '[v1]null[v]'),
  '-map', '[v]', '-t', lapDur.toFixed(2), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', merged])
if (KEEP) process.exit(console.log(merged))

// Find where the whole picture (laptop and phone together) stands still
const det = spawnSync(FF, ['-v', 'info', '-i', merged, '-vf', 'freezedetect=n=0.001:d=' + (HOLD + 0.5), '-an', '-f', 'null', '-'], { encoding: 'utf8' }).stderr
const starts = [...det.matchAll(/freeze_start: ([\d.]+)/g)].map((m) => Number(m[1]))
const ends = [...det.matchAll(/freeze_end: ([\d.]+)/g)].map((m) => Number(m[1]))
const cuts = starts.map((s, i) => [s + HOLD, ends[i] ?? lapDur]).filter(([a, b]) => b - a > 0.3)
const cut = cuts.reduce((t, [a, b]) => t + b - a, 0)
console.log(`${cuts.length} still stretches, ${cut.toFixed(0)} s cut: ` + cuts.map(([a, b]) => `${a.toFixed(0)}-${b.toFixed(0)}`).join(' '))

const out = path.join(dir, 'planova-demo-merged.mp4')
const drop = cuts.map(([a, b]) => `between(t,${a.toFixed(2)},${b.toFixed(2)})`).join('+') || '0'
execFileSync(FF, ['-y', '-v', 'error', '-i', merged, '-vf', `select='not(${drop})',setpts=N/FRAME_RATE/TB`,
  '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out])
fs.rmSync(merged)
// Where each segment now starts, for the narration
let cues = fs.readFileSync(path.join(dir, 'cues.txt'), 'utf8').split('\n').map((l) => {
  const m = l.match(/^(\d+):(\d+)(\s.*)$/)
  if (!m) return l
  const t = Number(m[1]) * 60 + Number(m[2]) + offset
  const t2 = t - cuts.reduce((s, [a, b]) => s + Math.max(0, Math.min(t, b) - a), 0)
  const r = Math.round(t2)
  return `${Math.floor(r / 60)}:${String(r % 60).padStart(2, '0')}${m[3]}`
})
fs.writeFileSync(path.join(dir, 'cues-merged.txt'), cues.join('\n'))
// The action log, on the merged video's clock: the same shift and cuts as the cues, unrounded
const actionsFile = path.join(dir, 'actions.json')
if (fs.existsSync(actionsFile)) {
  const mapped = JSON.parse(fs.readFileSync(actionsFile, 'utf8')).map((x) => {
    const t = x.t + offset
    const t2 = t - cuts.reduce((sum, [a, b]) => sum + Math.max(0, Math.min(t, b) - a), 0)
    return { ...x, t: Math.round(t2 * 100) / 100 }
  })
  fs.writeFileSync(path.join(dir, 'actions-merged.json'), JSON.stringify(mapped, null, 1))
}
console.log(out)
