// Unit tests: how the live map cleans readings and where it draws a person (2 Nov).
// The readings are the real ones an IC's Android phone sent indoors in "Banana Party": a GPS fix (±13-19 m) and a
// Wi-Fi / cell fix (always 1.298275, 103.848980, ±100 m, 120 m away) in turn. The marker went back and forth between
// the two, and after Stop it kept moving for 12 s while its label already said "Stopped".
import { describe, it, expect } from 'vitest'
import { newTrack, addReading, advance, positionAt, metres, LAG_MS } from '../liveMotion'

const T0 = Date.parse('2026-11-02T03:04:57Z')
const at = (s) => T0 + s * 1000
const GOOD = { lat: 1.297435, lng: 103.849695 }
const COARSE = { lat: 1.298275, lng: 103.84898 }

// [seconds after T0, place, accuracy] -- the order the phone sent them
const BANANA_PARTY = [
  [0, GOOD, 17],
  [10.8, COARSE, 100],
  [21, { lat: 1.297435, lng: 103.849705 }, 15],
  [35, COARSE, 100],
  [45.2, { lat: 1.297453, lng: 103.849702 }, 13],
  [59.1, COARSE, 100],
  [69.2, { lat: 1.297453, lng: 103.849698 }, 16],
  [82.4, COARSE, 100],
  [92.5, { lat: 1.297421, lng: 103.849724 }, 19],
]

function trackOf(rows) {
  const track = newTrack()
  for (const [s, p, accuracy, source = 'gps'] of rows) addReading(track, { t: at(s), lat: p.lat, lng: p.lng, accuracy, source })
  return track
}

describe('coarse fixes between good ones', () => {
  it('keeps only the GPS fixes when the phone alternates GPS and Wi-Fi', () => {
    const track = trackOf(BANANA_PARTY)
    expect(track.points.every((p) => p.accuracy < 50)).toBe(true)
    expect(track.points).toHaveLength(5)
  })

  it('never draws the marker near the coarse point while the share runs', () => {
    const track = trackOf(BANANA_PARTY)
    for (let s = 0; s <= 92; s += 0.5) {
      const pos = positionAt(track, at(s))
      expect(metres(pos, GOOD)).toBeLessThan(20) // the coarse point is 120 m away
    }
  })

  it('takes a coarse fix once the good ones are over a minute old (GPS lost indoors)', () => {
    const track = trackOf([
      [0, GOOD, 15],
      [70, COARSE, 100],
    ])
    expect(track.points).toHaveLength(2)
    expect(track.points[1].lat).toBe(COARSE.lat)
  })

  it('takes a fix that is only a little worse (±40 m after ±15 m)', () => {
    const track = trackOf([
      [0, GOOD, 15],
      [10, { lat: 1.2976, lng: 103.8497 }, 40],
    ])
    expect(track.points).toHaveLength(2)
  })
})

describe('after Stop', () => {
  it('draws the person at their Stop straight away, not 12 s behind', () => {
    const track = trackOf([...BANANA_PARTY, [99.6, { lat: 1.297421, lng: 103.849724 }, 19, 'stop']])
    // The viewer's clock right after the Stop row arrived: without the rule the playhead would be 12 s back
    const nowMs = at(100)
    advance(track, nowMs - 1000, 0)
    const t = advance(track, nowMs, 1000)
    expect(t).toBe(at(99.6))
    expect(positionAt(track, t)).toMatchObject({ lat: 1.297421, lng: 103.849724 })
  })

  it('still draws a sharing person 12 s in the past (the smoothing is unchanged)', () => {
    const track = trackOf(BANANA_PARTY)
    track.delays.push(0)
    const t = advance(track, at(80), 0)
    expect(t).toBe(at(80) - LAG_MS)
  })
})
