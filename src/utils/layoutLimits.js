// How big the bench is allowed to be, and what a shape costs.
//
// THE AUTHORITY IS THE DATABASE: public.layout_bytes() in 017_object_rows.sql measures the bench as the
// sum of the JSON text of every shape plus every picture, save_object() refuses a write that would push
// it past 4 MB, and every reply carries the number -- so the page can SHOW the size without working it
// out. That number is what the ring in the floor plans card draws, and it is the number the planner is
// held to, byte for byte.
//
// What is left here is the one thing the database cannot answer before it is asked: would THIS floor
// plan fit? A picture that cannot be stored should be refused before it is added rather than being taken
// back off the canvas afterwards -- and the page is the only side that knows both the bench's size and
// which pictures are already on it.

// Mirrors `v_bytes > 4194304` in public.save_object() and public.delete_object().
export const MAX_LAYOUT_BYTES = 4194304

// The database measures the UTF-8 bytes of the JSON text, so this must too: TextEncoder counts bytes,
// while String#length would count UTF-16 code units and under-report any non-ASCII character (a floor
// plan name, for instance) as half its real size.
const encoder = new TextEncoder()

export function layoutBytes(jsonText) {
  return encoder.encode(jsonText).length
}

// A shape as its ROW holds it: everything except the picture, which is a row in layout_images that the
// shape only points at (see 017_object_rows.sql). This is the split, client side.
export function withoutImage(shape) {
  if (!shape) return shape
  const { image, ...rest } = shape
  return rest
}

export function shapeRowBytes(shape) {
  return layoutBytes(JSON.stringify(withoutImage(shape)))
}

// What a shape would ADD to the bench, as the database counts it: the shape without its picture, plus
// the picture itself -- unless the bench already has that exact picture, which is the whole point of
// storing pictures under the md5 of the image: a copy of a floor plan costs its placement and nothing
// else, and a picture that is only being moved costs nothing at all.
//
// THE MARGIN IS FOR THE TWO JSON WRITERS. `jsonb` prints a space after every colon and every comma, and
// JSON.stringify does not, so the database's number is always a little larger than this one; a picture
// that gets past this check is refused by save_object() and taken back off the canvas (see useBenchDoc),
// so being a shade generous here is the right way to be wrong.
export function addedBytes(shape, plans) {
  const row = shapeRowBytes(shape)
  const shared = Array.isArray(plans) && plans.some((plan) => plan.image && plan.image === shape.image)
  const picture = shape.image && !shared ? layoutBytes(JSON.stringify(shape.image)) - 2 : 0
  return row + picture + Math.ceil((row + picture) / 100) + 64
}

export const LAYOUT_TOO_LARGE_MESSAGE =
  'That is too much for one bench (4 MB maximum). Remove or hide a floor plan first.'
