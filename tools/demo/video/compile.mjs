// node compile.mjs <take folder> [words.json]  -> <take>/Planova - IS216 G11.mp4
// The finished pitch video from the voiced clips (voiceover.mjs): a title card, each segment with the speaker's name
// and topic sliding in at its start, the testing segment as an animated slide timed to the narration, an end card,
// and a soft crossfade between every piece. No teleprompter text: these are the clean clips.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')
const FP = require('ffprobe-static').path

const [take, wordsFile] = process.argv.slice(2).map((p) => p && path.resolve(p))
const voiced = path.join(take, 'voiced')
const work = path.join(take, 'compile')
fs.rmSync(work, { recursive: true, force: true })
fs.mkdirSync(work)
const dur = (f) => Number(execFileSync(FP, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f], { encoding: 'utf8' }))
const run = (args) => execFileSync(FF, ['-y', '-v', 'error', ...args], { cwd: work })
const FONT = "fontfile='C\\:/Windows/Fonts/seguisb.ttf'"
const BOLD = "fontfile='C\\:/Windows/Fonts/seguibl.ttf'"
const INK = '0x0b3d2e'
const LIME = '0xc6f36b'
let tn = 0
const text = (s) => { const f = `t${tn++}.txt`; fs.writeFileSync(path.join(work, f), s); return `textfile=${f}` }
const fade = (a, b, c, d) => `alpha='if(lt(t,${a}),0,if(lt(t,${b}),(t-${a})/${b - a},if(lt(t,${c}),1,if(lt(t,${d}),(${d}-t)/${d - c},0))))'`
const ENC = ['-r', '30', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2']

// ---------- the title card ----------
const title = 'title.mp4'
run(['-f', 'lavfi', '-i', `color=c=${INK}:s=1920x1080:d=4.5:r=30`, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '4.5', '-vf', [
  `drawtext=${BOLD}:${text('planova')}:fontsize=170:fontcolor=${LIME}:x=(w-tw)/2:y=(h-th)/2-80:${fade(0.3, 1.0, 3.9, 4.4)}`,
  `drawtext=${FONT}:${text('Plan every group. Run it live. See it all again.')}:fontsize=46:fontcolor=white:x=(w-tw)/2:y=(h)/2+70:${fade(0.9, 1.6, 3.9, 4.4)}`,
  `drawtext=${FONT}:${text('IS216 Web Application Development II  ·  G11  ·  Group 5')}:fontsize=28:fontcolor=0xb9cfc4:x=(w-tw)/2:y=h-120:${fade(1.3, 2.0, 3.9, 4.4)}`,
].join(','), ...ENC, title])

// ---------- each segment, with its speaker and topic in the lower third ----------
const pieces = [title]
const clips = fs.readdirSync(voiced).filter((f) => /^\d\d .*\.mp4$/.test(f)).sort()
const words = wordsFile && fs.existsSync(wordsFile) ? JSON.parse(fs.readFileSync(wordsFile, 'utf8')) : {}
for (const clip of clips) {
  const nn = clip.slice(0, 2)
  const [, who, topic] = clip.match(/^\d\d (\S+) - (.+)\.mp4$/)
  const src = path.join(voiced, clip)
  const d = dur(src)
  const out = `seg-${nn}.mp4`
  const lower = [
    `drawtext=${BOLD}:${text(who)}:fontsize=46:fontcolor=white:box=1:boxcolor=${INK}@0.94:boxborderw=22:x=72:y=h-210:${fade(0.4, 0.8, 4.2, 4.6)}`,
    `drawtext=${FONT}:${text(topic)}:fontsize=34:fontcolor=${INK}:box=1:boxcolor=${LIME}@0.97:boxborderw=16:x=72:y=h-128:${fade(0.55, 0.95, 4.2, 4.6)}`,
  ]
  if (nn === '15') {
    // The testing segment: the numbers appear as they are said (the words' times when there is a voice-over)
    const said = (words['15']?.words || []).map((w) => ({ w: w.w.toLowerCase().replace(/[^a-z0-9,]/g, ''), s: w.s }))
    const when = (re, k) => said.find((w) => re.test(w.w))?.s ?? 2 + (k * (d - 6)) / 5
    const rows = [
      ['71', 'end-to-end tests, every role in its own browser', /^seventy|^71/],
      ['114', 'unit tests', /^hundred|^114/],
      ['954', 'database checks on every rule and permission', /^nine|^954|^950/],
      ['320 px', 'every page checked on a small phone', /^320|^three|^pixel/],
      ['1,000', 'virtual phones on a whole NE4 night', /^thousand|^1,000|^1000/],
    ]
    const draw = [`drawtext=${BOLD}:${text('How we tested it')}:fontsize=64:fontcolor=${LIME}:x=160:y=150:${fade(0.3, 0.9, d - 0.6, d)}`]
    rows.forEach(([big, label, re], k) => {
      const t = Math.max(1, Math.min(d - 2, when(re, k)))
      const y = 300 + k * 140
      draw.push(`drawtext=${BOLD}:${text(big)}:fontsize=84:fontcolor=white:x=160:y=${y}:${fade(t, t + 0.5, d - 0.6, d)}`)
      draw.push(`drawtext=${FONT}:${text(label)}:fontsize=40:fontcolor=0xb9cfc4:x=520:y=${y + 26}:${fade(t + 0.15, t + 0.65, d - 0.6, d)}`)
    })
    run(['-f', 'lavfi', '-i', `color=c=${INK}:s=1920x1080:d=${d.toFixed(2)}:r=30`, '-i', src, '-map', '0:v', '-map', '1:a', '-t', d.toFixed(2),
      '-vf', [...draw, ...lower].join(','), ...ENC, out])
  } else {
    run(['-i', src, '-vf', `scale=1920:1080,setsar=1,${lower.join(',')}`, ...ENC, out])
  }
  pieces.push(out)
}

// ---------- the end card ----------
const end = 'end.mp4'
run(['-f', 'lavfi', '-i', `color=c=${INK}:s=1920x1080:d=6:r=30`, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '6', '-vf', [
  `drawtext=${BOLD}:${text('planova')}:fontsize=150:fontcolor=${LIME}:x=(w-tw)/2:y=300:${fade(0.3, 1.0, 5.4, 6)}`,
  `drawtext=${FONT}:${text('gpstesting.vercel.app')}:fontsize=48:fontcolor=white:x=(w-tw)/2:y=500:${fade(0.7, 1.4, 5.4, 6)}`,
  `drawtext=${FONT}:${text('Komin  ·  rui  ·  Hazel  ·  Linus  ·  Ern  ·  Kenneth')}:fontsize=38:fontcolor=0xb9cfc4:x=(w-tw)/2:y=640:${fade(1.1, 1.8, 5.4, 6)}`,
  `drawtext=${FONT}:${text('Thank you')}:fontsize=40:fontcolor=white:x=(w-tw)/2:y=760:${fade(1.6, 2.3, 5.4, 6)}`,
].join(','), ...ENC, end])
pieces.push(end)

// ---------- a soft crossfade between every piece ----------
const X = 0.4
const lens = pieces.map((p) => dur(path.join(work, p)))
let vf = ''
let af = ''
let at = 0
let v = '[0:v]'
let a = '[0:a]'
for (let i = 1; i < pieces.length; i++) {
  at += lens[i - 1] - X
  vf += `${v}[${i}:v]xfade=transition=fade:duration=${X}:offset=${at.toFixed(3)}[v${i}];`
  af += `${a}[${i}:a]acrossfade=d=${X}:c1=tri:c2=tri[a${i}];`
  v = `[v${i}]`
  a = `[a${i}]`
  at -= 0 // offsets are on the joined timeline, which is shorter by X at every join
}
const final = path.join(take, 'Planova - IS216 G11.mp4')
execFileSync(FF, ['-y', '-v', 'error', ...pieces.flatMap((p) => ['-i', p]), '-filter_complex', vf + af.slice(0, -1),
  '-map', v, '-map', a, '-r', '30', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
  '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', final], { cwd: work })
const d = dur(final)
console.log(`${path.basename(final)}: ${Math.floor(d / 60)}:${String(Math.round(d % 60)).padStart(2, '0')} (${pieces.length} pieces)${d > 720 ? '  OVER 12:00' : ''}`)
