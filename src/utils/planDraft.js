// What a live draft may say about a badge, and what may be done with one.
//
// A draft is how one planner watches another drag a badge on the plan board: the browser that is moving it publishes
// where it is going, about twenty times a second, straight to the other browsers (Realtime broadcast -- see
// composables/usePlanStream.js). It never reaches the database, and the database is the only thing that decides where
// a badge stands (081, 082), so a draft is a hint in the strongest sense: any signed-in page can publish one, and the
// page that receives it still has to draw it. Everything in this file exists because of that.
//
// TWO RULES MAKE AN UNTRUSTWORTHY STREAM SAFE TO DRAW.
//
// 1. A DRAFT MAY ONLY CARRY A PLACE. The patch is exactly `{ lat, lng }`: not the group, not the frame, not the
//    moment, and not the state or the confirmation flag. A draft is therefore a preview of a drag and never a
//    statement about anything else. The same function filters what is sent and what is drawn, so the two sides cannot
//    drift apart -- and a patch that is present but unusable takes the whole draft down with it, rather than moving a
//    badge to half a place.
//
// 2. A DRAFT MAY NOT DRAW A PLACE THE PLAN COULD NOT HOLD. The box is public.point_in_sg() (005_layouts.sql) -- the
//    same one 082 enforces on the write -- and it comes from utils/geo.js rather than a second copy of the numbers. A
//    draft whose place leaves the box is dropped, and the badge on this screen stays where the plan has it until the
//    planner who owns it writes their own change.
//
// THE CELL IS A STRING ON THE WIRE. One message carries one badge, and the badge is named by `frame|group` (see
// `draftCell`): a frame id is a uuid and a group id is one too, so neither contains a separator, and a received value
// that is not exactly two non-empty parts is not a badge this app has.
import { inSingapore } from './geo'

/** The cell a draft is about, as it travels: `frame|group`. */
export function draftCell(frameId, groupId) {
  if (!frameId || !groupId) return ''
  return `${frameId}|${groupId}`
}

/** The other direction: `frame|group` -> `{ frame, group }`, or null when it does not name one badge. */
export function draftWhere(cell) {
  if (typeof cell !== 'string') return null
  const cut = cell.indexOf('|')
  if (cut <= 0 || cut === cell.length - 1) return null
  const frame = cell.slice(0, cut)
  const group = cell.slice(cut + 1)
  if (!frame || !group || group.includes('|')) return null
  return { frame, group }
}

/**
 * A draft's patch, cleaned: `{ lat, lng }` with both inside Singapore, or null when the draft says nothing this app
 * can draw. Used on the way OUT as well as on the way in -- one list of fields for both directions is what stops a
 * future patch from quietly turning every drag into a message about things a drag does not change.
 */
export function draftPatch(patch) {
  if (!patch || typeof patch !== 'object') return null
  const lat = patch.lat
  const lng = patch.lng
  if (!inSingapore([lat, lng])) return null
  return { lat, lng }
}
