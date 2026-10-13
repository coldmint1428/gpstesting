// What does one lock actually cost, on the side this browser owns?
//
// The save is `JSON.stringify(layout)` -> the same string is measured, then handed to
// supabase-js, which serialises the body again. Everything below is that path, on a
// synthetic canvas of the shape the bench really stores.

function makePlan(i, imageBytes) {
  // A data URL of roughly `imageBytes`: base64 is 4/3 of the raw bytes, plus the header.
  const raw = Math.ceil((imageBytes * 3) / 4)
  return {
    id: 'p' + i,
    name: 'Level ' + i,
    image: 'data:image/png;base64,' + 'A'.repeat(raw),
    centre: [1.3, 103.8],
    width: 0.002,
    height: 0.0015,
    rotation: 0,
    opacity: 0.7,
  }
}

function makeArea(i, points) {
  const ring = []
  for (let p = 0; p < points; p++) {
    const a = (p / points) * Math.PI * 2
    ring.push([1.3 + Math.sin(a) * 0.002, 103.8 + Math.cos(a) * 0.002])
  }
  return { id: 'a' + i, name: 'Area ' + i, kind: 'zone', points: ring }
}

function time(label, fn, runs = 5) {
  fn() // warm
  const t0 = process.hrtime.bigint()
  for (let i = 0; i < runs; i++) fn()
  const t1 = process.hrtime.bigint()
  const ms = Number(t1 - t0) / 1e6 / runs
  console.log(label.padEnd(52), ms.toFixed(1).padStart(8) + ' ms')
  return ms
}

function scenario(name, doc) {
  const text = JSON.stringify(doc)
  console.log('\n== ' + name + ' ==')
  console.log('body'.padEnd(52), (text.length / 1048576).toFixed(2).padStart(8) + ' MB')

  // 1. The computed that builds the payload (PolygonTestView.canvasText).
  const stringify = time('JSON.stringify(layout)  [canvasText]', () => JSON.stringify(doc))

  // 2. layoutBytes(): how the 4 MB check counts it.
  const bytes = time('layoutBytes(text)', () => Buffer.byteLength(text, 'utf8'))

  // 3. saveNow() parses the string back into a plain object before the RPC.
  const parse = time('JSON.parse(text)  [saveNow]', () => JSON.parse(text))

  // 4. supabase-js builds the request body: the payload is embedded in a JSON envelope.
  const envelope = time('JSON.stringify({ p_data })  [request body]', () =>
    JSON.stringify({ p_token: '00000000-0000-0000-0000-000000000000', p_data: doc }),
  )

  // 5. deep watch on props.areas fires during the save -> Vue walks the whole array.
  const areas = doc.polygons
  const walk = time('deep-walk of polygons  [watch(reactive)]', () => {
    let seen = 0
    const visit = (v) => {
      if (Array.isArray(v)) for (const x of v) visit(x)
      else if (v && typeof v === 'object') for (const k in v) visit(v[k])
      else seen++
    }
    visit(areas)
    return seen
  })

  const clientTotal = stringify + bytes + parse + envelope + walk
  console.log('-'.repeat(62))
  console.log('client-side total'.padEnd(52), clientTotal.toFixed(1).padStart(8) + ' ms')
  console.log(
    'upload at 1 Mbps / 10 Mbps / 50 Mbps'.padEnd(52),
    [(text.length * 8) / 1e6, (text.length * 8) / 1e7, (text.length * 8) / 5e7]
      .map((s) => s.toFixed(1))
      .join(' s / ') + ' s',
  )
  return { text: text.length, clientTotal }
}

// The bench as it is likely to be used: a handful of floors, a few dozen shapes.
scenario('small: 3 plans (500 KB each) + 40 areas x 20 points', {
  version: 1,
  view: { lat: 1.3, lng: 103.8, zoom: 17 },
  floorPlans: [0, 1, 2].map((i) => makePlan(i, 500 * 1024)),
  polygons: Array.from({ length: 40 }, (_, i) => makeArea(i, 20)),
})

scenario('busy: 10 plans (500 KB each) + 500 areas x 200 points', {
  version: 1,
  view: { lat: 1.3, lng: 103.8, zoom: 17 },
  floorPlans: Array.from({ length: 10 }, (_, i) => makePlan(i, 500 * 1024)),
  polygons: Array.from({ length: 500 }, (_, i) => makeArea(i, 200)),
})

scenario('worst case: 20 plans at the 512 KB image ceiling', {
  version: 1,
  view: { lat: 1.3, lng: 103.8, zoom: 17 },
  floorPlans: Array.from({ length: 20 }, (_, i) => makePlan(i, 512 * 1024)),
  polygons: Array.from({ length: 500 }, (_, i) => makeArea(i, 200)),
})
