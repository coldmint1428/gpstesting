// The NDP 25 venue's named posts, from the real NDP 25 Main map (KML), as Planova areas for the demo event.
//
//   node tools/demo/ndp-kml-areas.mjs "<NDP 25 Main.kml>"  -> docs/demo/ndp25-areas.json
//
// The KML has no polygons: its posts are points (control and casing stations, access control points, medical posts,
// quick-response teams) and its routes are lines. Planova's areas are shapes, so each post near the Padang becomes a
// small square on its own coordinates: an access control point is an Entrance, every other post a Zone. The gates,
// spectator and parking markers further out (G, P, W, S, B, F, M) are left out, as are the unnamed outlines.
import fs from 'node:fs'

const kmlPath = process.argv[2]
if (!kmlPath) throw new Error('usage: node tools/demo/ndp-kml-areas.mjs <NDP 25 Main.kml>')
const kml = fs.readFileSync(kmlPath, 'utf8')

// The venue the demo plays on: the Padang, the Civic District and the Esplanade
const BOX = { south: 1.286, north: 1.2965, west: 103.849, east: 103.859 }
// [pattern, kind, half a side in metres, what the post is]
const POSTS = [
  [/^ACP\b/, 'entrance', 10, 'Access control point'],
  [/^PCS\b/, 'zone', 14, 'Control station'],
  [/^VCS\b/, 'zone', 14, 'Control station'],
  [/^DCS\b/, 'zone', 14, 'Control station'],
  [/Medical Post/, 'zone', 14, 'Medical post'],
  [/^QRT\b/, 'zone', 14, 'Quick response team'],
]

const areas = []
for (const m of kml.matchAll(/<Placemark[^>]*>([\s\S]*?)<\/Placemark>/g)) {
  const body = m[1]
  if (!/<Point>/.test(body)) continue
  const name = ((body.match(/<name>([\s\S]*?)<\/name>/) || [])[1] || '').trim().replace(/\s*\?$/, '')
  const post = POSTS.find(([re]) => re.test(name))
  if (!post) continue
  const [lng, lat] = (body.match(/<coordinates>\s*([^<\s]+)/) || [])[1].split(',').map(Number)
  if (lat < BOX.south || lat > BOX.north || lng < BOX.west || lng > BOX.east) continue
  const [, kind, half, what] = post
  const dLat = half / 110574
  const dLng = half / (111320 * Math.cos((lat * Math.PI) / 180))
  const r = (v) => Math.round(v * 1e6) / 1e6
  areas.push({
    name,
    kind,
    code: name.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 24),
    what,
    points: [[r(lat + dLat), r(lng - dLng)], [r(lat + dLat), r(lng + dLng)], [r(lat - dLat), r(lng + dLng)], [r(lat - dLat), r(lng - dLng)]],
  })
}
areas.sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true }))

// The KML's closed outlines are all "Untitled Path". The small ones near the Padang are kept (the few that wrap a whole
// district are not), duplicates dropped, and each is given a name of the kind an NDP map uses. These names are ours,
// not the KML's: the outlines beside the War Memorial Park read as the contingents' holding area and casing pens, and
// the one by the Fullerton as an assembly area.
const OUR_NAMES = {
  holding: ['War Memorial Holding Area', 'Casing Pen A', 'Casing Pen B', 'Casing Pen C', 'Marshalling Point', 'Water Point'],
  south: ['Fullerton Assembly Area'],
}
const shapes = []
for (const m of kml.matchAll(/<Placemark[^>]*>([\s\S]*?)<\/Placemark>/g)) {
  const body = m[1]
  if (!/<LineString>/.test(body)) continue
  const c = (body.match(/<coordinates>([\s\S]*?)<\/coordinates>/) || [])[1].trim().split(/\s+/).map((s) => s.split(',').map(Number))
  const [a, b] = [c[0], c[c.length - 1]]
  if (c.length < 4 || Math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 110574) > 15) continue // not closed
  let area2 = 0
  for (let i = 0; i < c.length - 1; i++) area2 += c[i][0] * 111320 * (c[i + 1][1] * 110574) - c[i + 1][0] * 111320 * (c[i][1] * 110574)
  const m2 = Math.abs(area2 / 2)
  const lat = c.reduce((s, q) => s + q[1], 0) / c.length
  const lng = c.reduce((s, q) => s + q[0], 0) / c.length
  if (m2 > 20000 || lat < BOX.south || lat > BOX.north || lng < BOX.west || lng > BOX.east) continue
  if (shapes.some((s) => Math.hypot((s.lat - lat) * 110574, (s.lng - lng) * 111320) < 5)) continue // a copy
  shapes.push({ lat, lng, m2, points: c.slice(0, -1).map(([x, y]) => [Math.round(y * 1e6) / 1e6, Math.round(x * 1e6) / 1e6]) })
}
shapes.sort((p, q) => q.m2 - p.m2)
const used = { holding: 0, south: 0 }
for (const s of shapes) {
  const group = s.lat < 1.2905 ? 'south' : 'holding'
  const name = OUR_NAMES[group][used[group]++]
  if (!name) continue
  areas.push({
    name,
    kind: 'zone',
    code: name.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 24),
    what: 'An unnamed outline on the NDP 25 map, named by us',
    points: s.points,
  })
}
const out = 'docs/demo/ndp25-areas.json'
fs.writeFileSync(out, JSON.stringify({ source: 'NDP 25 Main.kml', note: 'Named posts near the Padang, each a small square on its own coordinates', areas }, null, 2) + '\n')
console.log(`${areas.length} areas -> ${out}: ${areas.map((a) => a.name).join(', ')}`)
