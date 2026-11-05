// node prompter.mjs <take folder> <run sheet .html>  -> <take>/segments-prompter/NN Name - Title.mp4
// A teleprompter on each speaker's clip, like a newsreader's: the segment's lines across the bottom, each word filling
// with colour as it should be said, and the next line waiting beneath. The timing comes from the take's action log:
// the word that names an action (cues.mjs) lights up the moment that action happens on screen. The words always run at
// an even speaking pace (PACE): when the screen gets to an action before the words do, the picture pauses just before
// that action until the reader catches up; when the screen is slower, the reader waits before the cued word. Where the
// lines need longer than the clip, its last frame holds. These clips are for recording; the final video uses the clean
// ones, retimed to each recorded voice (voiceover.mjs).
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { CUES } from './cues.mjs'
import { segmentStarts, timeline } from './starts.mjs'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')
const FP = require('ffprobe-static').path

const [take, sheet] = process.argv.slice(2).map((p) => path.resolve(p))
const PACE = 60 / 130 // seconds a word: an unhurried 130 words a minute, never faster
const MIN = 0.3 // and a short word after a long one never flashes by quicker than this
const LINE = 8 // words on a line
const dur = (f) => Number(execFileSync(FP, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f], { encoding: 'utf8' }))
const html = fs.readFileSync(sheet, 'utf8').replace(/\r\n/g, '\n')
const decode = (s) => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim()
const lines = {}
for (const m of html.matchAll(/<article class="seg" id="s(\d+)">[\s\S]*?<span class="who"[^>]*>([^<]+)<[\s\S]*?<div class="say"><div class="label">Say<\/div>\s*<p>([\s\S]*?)<\/p>/g)) {
  lines[Number(m[1])] = { who: m[2].trim(), text: decode(m[3]) }
}
const { actions } = timeline(take) // the log, on the video's clock (starts.mjs)
const sec = (s) => { const [m, x] = s.split(':').map(Number); return m * 60 + x }
const starts = segmentStarts(take)
const norm = (w) => w.toLowerCase().replace(/[^a-z0-9'-]/g, '')
const ass = (t) => { const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60; return `${h}:${String(m).padStart(2, '0')}:${s.toFixed(2).padStart(5, '0')}` }
const clean = (w) => w.replace(/[{}\\]/g, '')

const out = path.join(take, 'segments-prompter')
fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(out)
const report = []
for (const clip of fs.readdirSync(path.join(take, 'segments')).filter((f) => /^\d\d .*\.mp4$/.test(f)).sort()) {
  const n = Number(clip.slice(0, 2))
  const say = lines[n]
  if (!say) continue
  const src = path.join(take, 'segments', clip)
  const v = dur(src)
  const words = say.text.split(' ')

  // Anchors: a word index and the moment (in the clip) its action happens
  const clipStart = n === 1 ? 0 : starts[n]
  const acts = actions.filter((x) => x.seg === n).map((x) => ({ ...x, c: x.t - clipStart })).filter((x) => x.c > 0.3 && x.c < v)
  const anchors = []
  let ai = 0
  let wi = 0
  for (const [act, word] of CUES[n] || []) {
    const ax = acts.slice(ai).findIndex((x) => act.test(x.what))
    const wx = words.slice(wi).findIndex((w) => word.test(norm(w)))
    if (ax < 0 || wx < 0) continue
    anchors.push({ i: wi + wx, t: acts[ai + ax].c })
    ai += ax + 1
    wi += wx + 1
  }
  // Each word's start, at an even pace from the previous cued word. A cued word waits for its action; if the action
  // would come first, the picture holds just before it (holds: [moment in the clip, seconds]) until the words get there
  const at = new Array(words.length)
  const holds = []
  let shift = 0 // seconds of hold so far: a moment t of the clip plays at t + shift
  let t = 0.6
  let from = 0
  for (const a of anchors) {
    for (let k = 0; k < a.i - from; k++) at[from + k] = t + k * PACE
    const ready = t + (a.i - from) * PACE
    const lands = a.t + shift
    if (ready > lands) {
      const hold = ready - lands
      const atClip = Math.max(holds.length ? holds[holds.length - 1][0] : 0, a.t - 0.15)
      holds.push([atClip, hold])
      shift += hold
    }
    at[a.i] = a.t + shift
    from = a.i
    t = at[a.i]
  }
  for (let k = 0; k < words.length - from; k++) at[from + k] = t + k * PACE
  for (let k = 1; k < words.length; k++) if (at[k] < at[k - 1] + MIN) at[k] = at[k - 1] + MIN
  const endAt = at[words.length - 1] + PACE + 0.8
  const total = Math.max(v + shift, endAt)

  // Lines of LINE words (a sentence ends a line early); the line being read, and the next one dimmed beneath
  const rows = []
  let row = []
  words.forEach((w, k) => {
    row.push(k)
    if (row.length >= LINE || /[.?!]$/.test(w)) { rows.push(row); row = [] }
  })
  if (row.length) rows.push(row)
  const ev = []
  rows.forEach((r, ri) => {
    const s = at[r[0]] - 0.25
    const e = ri + 1 < rows.length ? at[rows[ri + 1][0]] - 0.25 : endAt
    const kara = r.map((k, j) => {
      const next = j + 1 < r.length ? at[r[j + 1]] : at[k] + PACE
      return `{\\kf${Math.max(1, Math.round((next - at[k]) * 100))}}${clean(words[k])} `
    }).join('')
    ev.push(`Dialogue: 1,${ass(Math.max(0, s))},${ass(e)},Now,,0,0,0,,${kara.trim()}`)
    if (rows[ri + 1]) ev.push(`Dialogue: 0,${ass(Math.max(0, s))},${ass(e)},Next,,0,0,0,,${rows[ri + 1].map((k) => clean(words[k])).join(' ')}`)
  })
  ev.push(`Dialogue: 2,${ass(0)},${ass(total)},Who,,0,0,0,,${clean(say.who)} · ${clip.slice(0, 2)} ${clean(clip.replace(/^\d\d \S+ - /, '').replace(/\.mp4$/, ''))}`)
  const file = `${String(n).padStart(2, '0')}.ass`
  fs.writeFileSync(path.join(out, file), `[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Now,Segoe UI,54,&H006BF3C6,&H00FFFFFF,&H00172A0A,&H00172A0A,1,0,0,0,100,100,0,0,3,14,0,2,120,120,120,1
Style: Next,Segoe UI,40,&H00A0B0A8,&H00A0B0A8,&H00172A0A,&H00172A0A,0,0,0,0,100,100,0,0,3,10,0,2,120,120,48,1
Style: Who,Segoe UI,30,&H00172A0A,&H00172A0A,&H006BF3C6,&H006BF3C6,1,0,0,0,100,100,0,0,3,10,0,7,40,40,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
${ev.join('\n')}
`)
  const hold = Math.max(0, total - v - shift)
  const cuts = [...holds, [v, hold]]
  let graph = ''
  let prev = 0
  cuts.forEach(([c, h], j) => {
    graph += `[0:v]trim=start=${prev.toFixed(3)}:end=${Math.max(prev + 0.04, c).toFixed(3)},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=${h.toFixed(3)}[p${j}];`
    prev = Math.max(prev + 0.04, c)
  })
  graph += cuts.map((_, j) => `[p${j}]`).join('') + `concat=n=${cuts.length}:v=1:a=0,fps=30,ass=${file}[v]`
  execFileSync(FF, ['-y', '-v', 'error', '-i', src, '-filter_complex', graph, '-map', '[v]',
    '-t', total.toFixed(2), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '21', '-pix_fmt', 'yuv420p', '-an', path.join(clip)], { cwd: out })
  fs.rmSync(path.join(out, file))
  report.push(`${clip}: ${words.length} words at ${Math.round(60 / PACE)} a minute, ${anchors.length} on their action${shift > 0.3 ? `, paused ${shift.toFixed(1)} s for the reader` : ''}${hold > 0.5 ? `, last frame held ${hold.toFixed(1)} s` : ''} (${total.toFixed(0)} s)`)
}
console.log(report.join('\n'))
