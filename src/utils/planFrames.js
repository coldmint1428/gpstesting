/**
 * Plan frames — the keyframe model.
 *
 * A plan is a list of frames. A frame is a moment in the run (t_s = seconds from T+0)
 * plus a position for each group. Nothing else is stored: no routes, no paths, no
 * activity blocks. Movement is implied by the straight line between neighbouring
 * frames, so tracing a detailed route just means adding frames closer together.
 *
 * Every frame holds every group it knows about. A frame that omits a group means
 * "this group has not moved since the last frame that mentioned it", which is what
 * makes "copy a frame, paste it 5 s later, move one group" cheap.
 *
 * A position also carries two flags (046): `state` is `on_site` or `off_site`, and
 * `verify` is `auto` or `manual`. An off-site statement still exists -- it is how the
 * plan says "this group is not on the map at this moment" -- but it is not a place
 * anybody walked to, so no rule that measures a walk uses it. Both flags are carried
 * forward with the coordinates: a group that went off site stays off site until a
 * frame says otherwise, exactly as it stays where it was.
 *
 * This module is pure: no Vue, no network, no DOM. Everything the board needs to
 * decide "is this allowed" and "where is everyone at time T" lives here.
 */

/**
 * How far one group may walk in one frame step, in metres. The budget for a walk is this times the number of frame
 * steps it spans, which is the cumulative rule (step 12): 3 frames allow 75 m, ten allow 250 m.
 */
export const MAX_FRAME_GAP_M = 25

/** Metres per degree of latitude. Same constant the rest of the app uses. */
const M_PER_DEG = 111320

/** Snap step for dragging frames along the time bar, in seconds. */
export const SNAP_S = 5

/**
 * Planar distance in metres. At the scale of one event (hundreds of metres) the
 * equirectangular approximation is exact enough and stays cheap in a drag loop.
 * @param {{lat:number,lng:number}} a
 * @param {{lat:number,lng:number}} b
 */
export function metresBetween(a, b) {
  const midLat = ((a.lat + b.lat) / 2) * (Math.PI / 180)
  const dx = (b.lng - a.lng) * M_PER_DEG * Math.cos(midLat)
  const dy = (b.lat - a.lat) * M_PER_DEG
  return Math.hypot(dx, dy)
}

/** Kilometres per hour implied by covering `metres` in `seconds`. */
export function kmh(metres, seconds) {
  if (!(seconds > 0)) return Infinity
  return (metres / seconds) * 3.6
}

/**
 * Resolve frames into one ordered track per group, newest definition winning.
 *
 * The two flags (046) travel with the coordinates: a group that went off site stays off site until a frame says
 * otherwise, and a position that carries no flags -- an old row, or the preview's fake api -- is on site and trusted.
 *
 * Every point also carries `index`: the ordinal of its frame in the whole plan (step 12). The 25 m rule is a budget
 * per *frame step*, so the number of frames between two statements is the thing that has to be counted -- and the
 * track itself cannot tell you, because the frames a group was carried through have the same position and may be
 * minutes apart. Seconds cannot stand in for it either: two frames can be one step and an hour apart.
 *
 * @param {Array<{id:string, t_s:number, positions:Object<string,{lat:number,lng:number,state?:string,verify?:string}>}>} frames
 * @returns {Map<string, Array<{index:number, t_s:number, frameId:string, lat:number, lng:number, state:string, verify:string, defined:boolean}>>}
 *   groupId -> points in time order. `defined` is false when the point was carried
 *   forward from an earlier frame rather than stated in this one.
 */
export function resolveTracks(frames) {
  const ordered = [...frames].sort((a, b) => a.t_s - b.t_s)
  const tracks = new Map()
  /** @type {Map<string,{lat:number,lng:number,state:string,verify:string}>} */
  const current = new Map()

  for (let index = 0; index < ordered.length; index += 1) {
    const frame = ordered[index]
    const own = frame.positions || {}
    for (const [groupId, point] of Object.entries(own)) {
      if (Number.isFinite(point?.lat) && Number.isFinite(point?.lng)) {
        current.set(groupId, {
          lat: point.lat,
          lng: point.lng,
          state: point.state === 'off_site' ? 'off_site' : 'on_site',
          verify: point.verify === 'manual' ? 'manual' : 'auto',
        })
      }
    }
    for (const [groupId, point] of current) {
      if (!tracks.has(groupId)) tracks.set(groupId, [])
      tracks.get(groupId).push({
        index,
        t_s: frame.t_s,
        frameId: frame.id,
        lat: point.lat,
        lng: point.lng,
        state: point.state,
        verify: point.verify,
        defined: Object.prototype.hasOwnProperty.call(own, groupId),
      })
    }
  }
  return tracks
}

/**
 * Find every impossible walk: two statements of where a group is, too far apart for the frames between them.
 *
 * **The rule is cumulative**, which is the decision this whole stage is built on: a group may cover 25 m per frame
 * step, so a walk that spans three frames may be 75 m and one that spans ten may be 250 m. The budget therefore
 * comes from the *frame count* between the two statements — `index` from resolveTracks — not from a flat 25 m and
 * not from the seconds between them. A frame is a slot in the strip; ten slots are ten chances to walk.
 *
 * **Only statements count.** A position carried forward from an earlier frame is not a statement of its own, so
 * the pair reported is always (the frame that last said where they were) -> (the frame that says where they are
 * now). Measuring from the carried frame instead is what made a group stated at +0:00 and +10:00 read as breaking
 * at +9:00: a pair nobody can fix, because nothing at +9:00 said anything. It also made the board and the database
 * name different pairs for the same walk (finding 24), which step 12 ends by having both sides follow the same
 * pair. Off-site statements are skipped (046), so an excursion is still invisible and a return is measured from
 * where the group was last on site.
 *
 * @returns {Array<{groupId:string, from:object, to:object, metres:number, seconds:number, kmh:number,
 *   steps:number, budget:number}>} `steps` is how many frame steps the walk had, `budget` what they allow.
 */
export function findGaps(frames, maxM = MAX_FRAME_GAP_M) {
  const gaps = []
  for (const [groupId, points] of resolveTracks(frames)) {
    const stated = points.filter((p) => p.state !== 'off_site' && p.defined)
    for (let i = 1; i < stated.length; i++) {
      const from = stated[i - 1]
      const to = stated[i]
      const steps = Math.max(1, to.index - from.index)
      const budget = maxM * steps
      const metres = metresBetween(from, to)
      if (metres > budget) {
        gaps.push({
          groupId,
          from,
          to,
          metres,
          seconds: to.t_s - from.t_s,
          kmh: kmh(metres, to.t_s - from.t_s),
          steps,
          budget,
        })
      }
    }
  }
  return gaps
}

/**
 * How many frames a stretch's marks reach in from each end. A plan can hold hundreds of frames, and one broken group
 * spanning all of them must not paint every dot on the strip on every pointer move — the mark is there to show how
 * far the stretch reaches, not to count it. The band on the strip is drawn full width whatever this says, so the
 * whole stretch is always visible even when its middle dots are not individually red.
 */
export const MAX_STRETCH_RINGS = 24

/**
 * Everything the board needs to paint warnings, derived once per edit.
 *
 * Three things make this more than a list of gaps (step 12). The marks **cover the stretch**, not just the pair:
 * expansion runs by rings in from both ends of each gap, so the frames a walk had between its two statements are
 * marked too — those are the frames that have to be re-spaced or filled, and they are what "the whole impossible
 * stretch" means. The rings stop at MAX_STRETCH_RINGS for the reason recorded there. And gaps that touch are
 * **merged per group** into one stretch, so a frame dragged 200 m away reads as one stretch through the frames
 * around it rather than as two unrelated breaks that happen to share a frame.
 *
 * @returns {{
 *   gaps: Array<object>,
 *   frameIds: Set<string>,      // frames to mark on the timeline: every frame in every stretch, ring-capped
 *   cells: Set<string>,         // `${groupId}|${frameId}` to mark on the map / lane: the statements at each end
 *   bands: Array<{groupId:string, from_t_s:number, to_t_s:number}>,
 *   stretches: Array<{groupId:string, fromIndex:number, toIndex:number, from_t_s:number, to_t_s:number,
 *     fromFrameId:string, toFrameId:string, steps:number, gaps:Array<object>}>
 * }}
 */
export function annotate(frames, maxM = MAX_FRAME_GAP_M) {
  const gaps = findGaps(frames, maxM)
  const ordered = [...frames].sort((a, b) => a.t_s - b.t_s)
  const frameIds = new Set()
  const cells = new Set()
  const stretches = []

  for (const gap of gaps) {
    cells.add(`${gap.groupId}|${gap.from.frameId}`)
    cells.add(`${gap.groupId}|${gap.to.frameId}`)

    // Mark the stretch by walking in from both ends, one ring at a time, and stop when the rings meet.
    for (let ring = 0; ring <= MAX_STRETCH_RINGS; ring += 1) {
      const left = gap.from.index + ring
      const right = gap.to.index - ring
      if (left > gap.to.index || right < gap.from.index) break
      frameIds.add(ordered[left].id)
      frameIds.add(ordered[right].id)
      if (left >= right) break
    }

    // One stretch per run of touching gaps: a group broken at +1:00→+1:15 and +1:15→+1:30 is one stretch of three
    // frames, and the sentence about it should say so once.
    const last = stretches[stretches.length - 1]
    if (last && last.groupId === gap.groupId && gap.from.index <= last.toIndex) {
      last.toIndex = gap.to.index
      last.to_t_s = gap.to.t_s
      last.toFrameId = gap.to.frameId
      last.steps = last.toIndex - last.fromIndex
      last.gaps.push(gap)
    } else {
      stretches.push({
        groupId: gap.groupId,
        fromIndex: gap.from.index,
        toIndex: gap.to.index,
        from_t_s: gap.from.t_s,
        to_t_s: gap.to.t_s,
        fromFrameId: gap.from.frameId,
        toFrameId: gap.to.frameId,
        steps: gap.steps,
        gaps: [gap],
      })
    }
  }

  // Bands are drawn from the merged stretches, so a stretch broken at two neighbouring hops is one band, not two
  // overlapping ones. Still one band per group: two groups walking the same impossible stretch are two lanes.
  const bands = stretches.map((s) => ({ groupId: s.groupId, from_t_s: s.from_t_s, to_t_s: s.to_t_s }))
  return { gaps, frameIds, cells, bands, stretches }
}

/**
 * The words for one impossible walk, without the group's name: "198 m between +1:00 and +1:15 (limit 25 m)".
 *
 * One sentence, one place. The board's warning row and the refusal in front of an import both read from here, because
 * the step's own proof is that they are the *same* sentence: a sheet refused for a 100 m step has to say what the
 * strip already says about that step, not a second wording of it that can drift.
 *
 * @param {object} gap  one element of findGaps()/annotate().gaps
 */
export function gapDetail(gap) {
  const steps = gap.steps > 1 ? `, ${gap.steps} steps` : ''
  const metres = Math.round(gap.metres)
  const budget = Math.round(gap.budget)
  return `${metres} m between ${formatOffset(gap.from.t_s)} and ${formatOffset(gap.to.t_s)} (limit ${budget} m${steps})`
}

/**
 * Where a group is at an arbitrary time, interpolating between the frames that
 * bracket it. This is what the live view and the "play" scrubber both read.
 *
 * @returns {{lat:number,lng:number}|null} null before the first frame or after the last.
 */
export function positionAt(track, t_s) {
  if (!track || !track.length) return null
  if (t_s <= track[0].t_s) return { lat: track[0].lat, lng: track[0].lng }
  const last = track[track.length - 1]
  if (t_s >= last.t_s) return { lat: last.lat, lng: last.lng }

  for (let i = 1; i < track.length; i++) {
    const to = track[i]
    if (to.t_s < t_s) continue
    const from = track[i - 1]
    const span = to.t_s - from.t_s
    if (span <= 0) return { lat: to.lat, lng: to.lng }
    const k = (t_s - from.t_s) / span
    return { lat: from.lat + (to.lat - from.lat) * k, lng: from.lng + (to.lng - from.lng) * k }
  }
  return { lat: last.lat, lng: last.lng }
}

/**
 * Where every group stands at one frame: what that frame states, plus what it inherits from earlier frames.
 *
 * This is what "copy this frame" has to mean. Copying only the frame's own statements would drop every group
 * that was carried forward into it, and pasting would then reproduce a subset of where people actually were.
 *
 * The flags come with it (046): a pasted frame has to say the same thing about being off site, or copying a
 * moment and pasting it would quietly put a group back on the map.
 *
 * @param {Map<string, Array<{t_s:number, frameId:string, lat:number, lng:number, state:string, verify:string, defined:boolean}>>} tracks
 *   the result of resolveTracks()
 * @param {string} frameId
 * @returns {Object<string,{lat:number,lng:number,state:string,verify:string}>} groupId -> position, ready to paste into a new frame.
 */
export function snapshotAt(tracks, frameId) {
  const out = {}
  for (const [groupId, points] of tracks) {
    const point = points.find((p) => p.frameId === frameId)
    if (point) out[groupId] = { lat: point.lat, lng: point.lng, state: point.state, verify: point.verify }
  }
  return out
}

/**
 * Build a `positions` payload for frame_save: the frame's own statements, plus the points this edit changes.
 *
 * `positions` is replaced wholesale when a write sends it, so a payload built only from "what I changed" deletes
 * every other group the frame states — the trap step 10 names, and the one step 8 proved at the database ("a map
 * naming one group left 3 positions, expected 1"). Every flag write goes through here, so the full map is the only
 * shape the board can send.
 *
 * The frame's OWN map is the base, not the resolved one: a group that is merely carried into this frame is not a
 * statement of this frame, and turning it into one is a different edit. Both flags are written explicitly, so the
 * write never depends on the server's "omitted means unchanged" rule (046).
 *
 * @param {{positions?: Object<string,{lat:number,lng:number,state?:string,verify?:string}>}|null} frame
 * @param {Object<string,{lat:number,lng:number,state?:string,verify?:string}>} changes
 * @returns {Object<string,{lat:number,lng:number,state:string,verify:string}>}
 */
export function restatedPositions(frame, changes = {}) {
  const out = {}
  const put = (groupId, point) => {
    out[groupId] = {
      lat: point.lat,
      lng: point.lng,
      state: point.state === 'off_site' ? 'off_site' : 'on_site',
      verify: point.verify === 'manual' ? 'manual' : 'auto',
    }
  }
  for (const [groupId, point] of Object.entries(frame?.positions || {})) put(groupId, point)
  for (const [groupId, point] of Object.entries(changes)) put(groupId, point)
  return out
}

/**
 * Round a time to the drag grid.
 */
export function snap(t_s, step = SNAP_S) {
  if (!(step > 0)) return Math.round(t_s)
  return Math.round(t_s / step) * step
}

/** `+0:05:30` / `+1:12:00` — the label on a frame. */
export function formatOffset(t_s) {
  const sign = t_s < 0 ? '-' : '+'
  const total = Math.abs(Math.round(t_s))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const mm = h > 0 ? String(m).padStart(2, '0') : String(m)
  return `${sign}${h > 0 ? `${h}:${mm}` : mm}:${String(s).padStart(2, '0')}`
}

/** `+1:12` — the short form for the axis. */
export function formatOffsetShort(t_s) {
  const sign = t_s < 0 ? '-' : '+'
  const total = Math.abs(Math.round(t_s))
  const h = Math.floor(total / 3600)
  const m = Math.round((total % 3600) / 60)
  return h > 0 ? `${sign}${h}:${String(m).padStart(2, '0')}` : `${sign}${m}m`
}

/** Read `+1:12:30`, `1:12`, `90s`, `5m` into seconds, or null. */
export function parseOffset(text) {
  const raw = String(text ?? '').trim().replace(/^\+/, '')
  if (!raw) return null
  if (/^\d+s$/i.test(raw)) return Number(raw.slice(0, -1))
  if (/^\d+m$/i.test(raw)) return Number(raw.slice(0, -1)) * 60
  const parts = raw.split(':').map(Number)
  if (parts.some((n) => !Number.isFinite(n) || n < 0)) return null
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2]
  if (parts.length === 2) return parts[0] * 60 + parts[1]
  if (parts.length === 1) return parts[0] * 60
  return null
}

/** Track extent, for sizing the bar. Always starts at zero. */
export function spanOf(frames) {
  let end = 0
  for (const frame of frames) end = Math.max(end, frame.t_s)
  return { start: 0, end }
}
