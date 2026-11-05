// node voiceover.mjs <take folder> <audio folder> <words.json>
//   -> <take>/voiced/NN ....mp4, <take>/planova-demo-voiced.mp4 (all 16) and <take>/planova-demo-voiced-preview.mp4
//      (only the segments with a voice-over yet), plus <take>/voiced/alignment.txt (which word met which action)
//
// Word by word: each segment has cues, an action from the take's log (actions-merged.json) and the word in the
// narration that names it. The voice is transcribed with a time for every word (words.json, faster-whisper), so each
// cue gives a moment in the clip and a moment in the voice. The clip is cut at those moments and each piece played
// faster or slower so it ends exactly on its word; a piece too short to stretch holds its last frame instead.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')
const FP = require('ffprobe-static').path
import { CUES } from './cues.mjs'
import { segmentStarts, timeline } from './starts.mjs'

// [segment]: [action in the log, word that names it], in the order they happen. Words are matched loosely (the
// transcript mishears names), each after the one before.
const MAX_FAST = 2.5 // a piece plays at most this much faster than recorded
const MAX_SLOW = 2.5 // and at most this much slower; past that, its last frame holds

const [take, audioDir, wordsFile] = process.argv.slice(2).map((p) => path.resolve(p))
const dur = (f) => Number(execFileSync(FP, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f], { encoding: 'utf8' }))
const words = JSON.parse(fs.readFileSync(wordsFile, 'utf8'))
const { actions } = timeline(take) // the log, on the video's clock (starts.mjs)
const sec = (s) => { const [m, x] = s.split(':').map(Number); return m * 60 + x }
const starts = segmentStarts(take)
const clips = fs.readdirSync(path.join(take, 'segments')).filter((f) => /^\d\d .*\.mp4$/.test(f)).sort()
const audio = Object.fromEntries(fs.readdirSync(audioDir).filter((f) => /^\d\d\b/.test(f)).map((f) => [f.slice(0, 2), path.join(audioDir, f)]))
const out = path.join(take, 'voiced')
fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(out)
const report = []
const norm = (w) => w.toLowerCase().replace(/[^a-z0-9'-]/g, '')

const voiced = []
const all = []
for (const clip of clips) {
  const nn = clip.slice(0, 2)
  const n = Number(nn)
  const src = path.join(take, 'segments', clip)
  const dst = path.join(out, clip)
  const v = dur(src)
  if (!audio[nn]) {
    execFileSync(FF, ['-y', '-v', 'error', '-i', src, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-shortest', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', dst])
    report.push(`${clip}: no voice-over yet`)
    all.push(dst)
    continue
  }
  // The voice, trimmed of its leading silence and levelled; the transcript's times move by what was trimmed
  const wav = path.join(out, nn + '.wav')
  const lead = Number((execFileSync(FF, ['-hide_banner', '-i', audio[nn], '-af', 'silencedetect=n=-40dB:d=0.05', '-f', 'null', '-'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).toString().match(/silence_end: ([\d.]+)/) || [])[1] || 0)
  const trimmed = (execFileSync(FF, ['-hide_banner', '-i', audio[nn], '-af', 'silencedetect=n=-40dB:d=0.05', '-f', 'null', '-'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) || '')
  void trimmed
  const cutLead = words[nn]?.words?.[0] ? Math.max(0, Math.min(words[nn].words[0].s - 0.15, lead || words[nn].words[0].s - 0.15)) : 0
  execFileSync(FF, ['-y', '-v', 'error', '-ss', cutLead.toFixed(2), '-i', audio[nn], '-af', 'highpass=f=80,afftdn=nf=-25,acompressor=threshold=-20dB:ratio=3:attack=10:release=150:makeup=2,loudnorm=I=-16:TP=-1.5:LRA=9,aresample=48000', '-ac', '2', wav])
  const a = dur(wav)
  const said = (words[nn]?.words || []).map((w) => ({ w: norm(w.w), s: w.s - cutLead }))

  // Anchors: (time in the clip, time in the voice), in order, from 0 to the ends
  const clipStart = starts[n] ?? 0
  const segActions = actions.filter((x) => x.seg === n).map((x) => ({ ...x, c: x.t - clipStart })).filter((x) => x.c > 0.2 && x.c < v - 0.2)
  const anchors = [{ c: 0, a: 0, why: 'start' }]
  let ai = 0
  let wi = 0
  for (const [act, word] of CUES[n] || []) {
    const ax = segActions.slice(ai).findIndex((x) => act.test(x.what))
    const wx = said.slice(wi).findIndex((w) => word.test(w.w))
    if (ax < 0 || wx < 0) { report.push(`   ${clip}: no match for ${act} / ${word}`); continue }
    const A = segActions[ai + ax]
    const W = said[wi + wx]
    const prev = anchors[anchors.length - 1]
    if (A.c - prev.c < 0.3 || W.s - prev.a < 0.3) continue
    anchors.push({ c: A.c, a: W.s, why: `"${W.w}" on ${A.what}` })
    ai += ax + 1
    wi += wx + 1
  }
  anchors.push({ c: v, a: a + 0.3, why: 'end' })

  // Each piece between two anchors, played to fit
  const parts = []
  let filters = ''
  anchors.slice(0, -1).forEach((p, i) => {
    const q = anchors[i + 1]
    const dc = q.c - p.c
    const da = q.a - p.a
    let f = da / dc // > 1: slower
    let take = dc
    let hold = 0
    if (f > MAX_SLOW) { hold = da - dc * MAX_SLOW; f = MAX_SLOW }
    if (f < 1 / MAX_FAST) { f = 1 / MAX_FAST; take = da / f } // drop the rest of this piece
    filters += `[0:v]trim=start=${p.c.toFixed(3)}:duration=${take.toFixed(3)},setpts=(PTS-STARTPTS)*${f.toFixed(4)},tpad=stop_mode=clone:stop_duration=${hold.toFixed(3)}[p${i}];`
    parts.push(`[p${i}]`)
    report.push(`   ${clip}: ${p.c.toFixed(1)}-${q.c.toFixed(1)} s of screen -> ${p.a.toFixed(1)}-${q.a.toFixed(1)} s of voice (${f > 1 ? 'slowed' : 'sped up'} ${Math.abs(Math.round((f - 1) * 100))}%${hold > 0.05 ? `, held ${hold.toFixed(1)} s` : ''})${q.why !== 'end' ? '  ' + q.why : ''}`)
  })
  const total = anchors[anchors.length - 1].a
  execFileSync(FF, ['-y', '-v', 'error', '-i', src, '-i', wav, '-filter_complex',
    `${filters}${parts.join('')}concat=n=${parts.length}:v=1:a=0,fps=30[v];[1:a]apad[a]`,
    '-map', '[v]', '-map', '[a]', '-t', total.toFixed(2),
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k', dst])
  fs.rmSync(wav)
  report.unshift(`${clip}: ${anchors.length - 2} words matched to actions, ${total.toFixed(1)} s`)
  voiced.push(dst)
  all.push(dst)
}
const join = (list, name) => {
  const txt = path.join(out, name + '.txt')
  fs.writeFileSync(txt, list.map((f) => `file '${f.replace(/\\/g, '/').replace(/'/g, "'\\''")}'`).join('\n'))
  const file = path.join(take, name + '.mp4')
  execFileSync(FF, ['-y', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', txt,
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', file])
  fs.rmSync(txt)
  const d = dur(file)
  report.push(`${name}.mp4: ${Math.floor(d / 60)}:${String(Math.round(d % 60)).padStart(2, '0')}`)
}
if (voiced.length) join(voiced, 'planova-demo-voiced-preview')
join(all, 'planova-demo-voiced')
fs.writeFileSync(path.join(out, 'alignment.txt'), report.join('\n') + '\n')
console.log(report.join('\n'))
