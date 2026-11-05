// node split.mjs <run folder>  -> <run folder>/segments/NN Speaker - Title.mp4, one per segment of planova-demo-merged.mp4
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const FF = require('ffmpeg-static')
import { segmentStarts } from './starts.mjs'

// Who voices each segment (docs/demo/planova-demo-script.html)
const WHO = ['Komin', 'rui', 'Hazel', 'Linus', 'Linus', 'Kenneth', 'Ern', 'Ern', 'Komin', 'Hazel', 'rui', 'Ern', 'rui', 'Kenneth', 'Kenneth', 'Komin'] // the 16 segments of the run sheet (5 Nov)

const dir = path.resolve(process.argv[2])
const video = path.join(dir, 'planova-demo-merged.mp4')
const sec = (s) => { const [m, x] = s.split(':').map(Number); return m * 60 + x }
const lines = fs.readFileSync(path.join(dir, 'cues-merged.txt'), 'utf8').split('\n')
const marks = lines.map((l) => l.match(/^(\d+:\d+)\s+segment (\d+): (.+)$/)).filter(Boolean).map((m) => ({ t: sec(m[1]), n: Number(m[2]), title: m[3] }))
const end = sec(lines.find((l) => /\send$/.test(l)).split(/\s/)[0])
// The exact starts (starts.mjs), where the take's log has them
const exact = segmentStarts(dir)
for (const m of marks) if (exact[m.n] != null) m.t = exact[m.n]
const out = path.join(dir, 'segments')
fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(out)
marks.forEach((m, i) => {
  const from = m.n === 1 ? 0 : m.t // segment 1 also takes the opening seconds before it; a retake starts on its own segment
  const to = marks[i + 1] ? marks[i + 1].t - 0.1 : end + 2
  const name = `${String(m.n).padStart(2, '0')} ${WHO[m.n - 1]} - ${m.title}`.replace(/[<>:"/\\|?*]/g, '') + '.mp4'
  execFileSync(FF, ['-y', '-v', 'error', '-ss', from.toFixed(2), '-i', video, '-t', (to - from).toFixed(2),
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(out, name)])
  console.log(`${name}  (${(to - from).toFixed(1)} s)`)
})
