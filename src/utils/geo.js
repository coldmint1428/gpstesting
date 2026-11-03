// The one box this app calls "on the map".
//
// `public.point_in_sg()` in 005_layouts.sql is the rule the database enforces, and this is the same four numbers on the
// client side: two utilities need them (utils/benchFrame.js for a frame's geometry, utils/planDraft.js for a live
// draft), and two copies of a box is exactly the kind of thing that drifts. It is a plain constant and a plain
// function so either side can import it without pulling in the other.
export const SG = { minLat: 1.1, maxLat: 1.5, minLng: 103.5, maxLng: 104.2 }

function isNumber(value) {
  return typeof value === 'number' && Number.isFinite(value)
}

// Exactly two finite numbers inside Singapore -- the same four tests point_in_sg() makes, including "exactly two
// members": a third would be a value the database refuses.
export function inSingapore(point) {
  if (!Array.isArray(point) || point.length !== 2) return false
  if (!isNumber(point[0]) || !isNumber(point[1])) return false
  return (
    point[0] >= SG.minLat &&
    point[0] <= SG.maxLat &&
    point[1] >= SG.minLng &&
    point[1] <= SG.maxLng
  )
}
