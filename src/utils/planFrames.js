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
 * anybody walked to. Both flags are carried
 * forward with the coordinates: a group that went off site stays off site until a
 * frame says otherwise, exactly as it stays where it was.
 *
 * This module is pure: no Vue, no network, no DOM. Everything the board needs to
 * decide "where is everyone at time T" lives here. There is no distance or speed limit
 * between frames (091): how far and how fast a group moves is the planner's call.
 */

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
 * Every point also carries `index`: the ordinal of its frame in the whole plan.
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
