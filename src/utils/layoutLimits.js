// How big the bench canvas is allowed to be.
//
// The authority is public.save_bench() in 005_layouts.sql, which refuses a canvas over
// 4 MB with the SQLSTATE 54000 (program_limit_exceeded). The check lives there rather than
// in the table's CHECK constraint because pg_column_size/octet_length are not immutable, so
// they cannot back a constraint.
//
// Knowing the same number here buys three things the database cannot give us:
//  - the planner is told BEFORE they add a floor plan that puts the canvas over the cap,
//    instead of losing the save afterwards;
//  - a refused save can say "remove or hide a floor plan" rather than repeating an error
//    code;
//  - the bench can say how full the canvas is WHILE it is being worked on -- the ring in the
//    floor plans card -- which is the one use that happens between saves rather than at one, and
//    so the one use that has to be cheap (see documentBytes below).
//
// Keep this in step with save_bench(): if the cap moves there, it moves here too.

// Mirrors `octet_length(p_data::text) > 4194304` in public.save_bench().
export const MAX_LAYOUT_BYTES = 4194304

// The database measures the UTF-8 bytes of the JSON text, so this must too: TextEncoder
// counts bytes, while String#length would count UTF-16 code units and under-report any
// non-ASCII character (a floor plan name, for instance) as half its real size.
const encoder = new TextEncoder()

// `jsonText` must be the JSON text that will actually be sent, so measure the same string
// the save serialises rather than serialising a second time.
export function layoutBytes(jsonText) {
  return encoder.encode(jsonText).length
}

export function isLayoutTooLarge(jsonText) {
  return layoutBytes(jsonText) > MAX_LAYOUT_BYTES
}

// The SAME number as layoutBytes(JSON.stringify(doc)) -- not an estimate -- worked out without
// serialising the whole document, and keeping the parts it has already measured.
//
// WHY. The size ring on the page hangs off the document, so anything that changes the document
// recomputes it. That was fine while a change meant a click; it stopped being fine when a change
// came twenty times a second from somebody else's drag (live frames -- see
// composables/useBenchFrames.js), because measuring the canvas meant serialising every floor plan
// image in it. Measured on a canvas with one 700 KB picture and thirty areas: 1.70 ms and 758 KB of
// garbage per frame, 34 ms of every second spent on a number that had not moved by more than a few
// bytes. This does the same arithmetic in pieces, and measures the pictures once instead of twenty
// times a second: 0.04 ms for that canvas with an area being dragged, and 0.01 ms with a floor plan
// being dragged.
//
// The objects are never mutated -- the page replaces them on every change and useDocHistory's
// snapshots depend on that -- so an object's length can be remembered against the object itself.
// Nothing here has to be invalidated: a change means a different object.
//
// JSON is a concatenation of its parts, so the length of the whole is the sum of the lengths of the
// pieces plus the punctuation between them. The pieces are held by identity -- an object, or the
// text of a string -- and anything this does not take apart (a number, a boolean, a value that is
// not plain data at all) is handed to JSON.stringify and counted exactly. A field added later can
// cost speed at worst, never accuracy.
const byteCache = new WeakMap()

function measuredBytes(value) {
  const text = JSON.stringify(value)
  return text === undefined ? 0 : layoutBytes(text)
}

// A floor plan's picture is the one heavy string a canvas holds (a shrunk image is up to 512 KB of
// base64), and a plan is REPLACED on every frame of a drag -- so measuring the plan object itself
// would mean escaping its picture twenty times a second, which is the cost all of this exists to
// avoid. A string cannot be a WeakMap key, so the pictures are held by their text in a small map
// instead, oldest first out; a canvas holds a handful of pictures, not thousands.
const stringCache = new Map()
const STRING_CACHE_MAX = 16

function stringBytes(text) {
  const known = stringCache.get(text)
  if (known !== undefined) return known

  const size = measuredBytes(text) // the string AS JSON: quotes and any escapes included
  if (stringCache.size >= STRING_CACHE_MAX) {
    stringCache.delete(stringCache.keys().next().value) // the oldest
  }
  stringCache.set(text, size)
  return size
}

// An object's length: its own shape, with its string members measured separately. The strings are
// blanked out of the copy that is serialised -- `""` costs two bytes, hence the subtraction -- and
// each one is then added from the cache. Nothing else is recursed into, so an object that is not a
// picture is still measured in one pass, which is what keeps a dragged area (two hundred
// coordinates, replaced sixty times a second) cheaper than it was before any of this.
function objectBytes(value) {
  const keys = Object.keys(value)
  let copy = null
  let extra = 0

  for (const key of keys) {
    const member = value[key]
    if (typeof member !== 'string') continue
    if (!copy) copy = { ...value }
    extra += stringBytes(member) - 2 // the `""` the copy will write in its place
    copy[key] = ''
  }

  return measuredBytes(copy || value) + extra
}

// One member of an array, or of the document itself. `undefined` is not a value JSON can write: in
// an array it becomes null, and as a member of an object it is not written at all (handled above).
function memberBytes(value) {
  if (value === undefined || value === null) return 4 // "null"
  if (typeof value !== 'object') return measuredBytes(value)

  let known = byteCache.get(value)
  if (known === undefined) {
    known = objectBytes(value)
    byteCache.set(value, known)
  }
  return known
}

function arrayBytes(items) {
  if (items.length === 0) return 2 // []
  let total = 2 // [ and ]
  for (let index = 0; index < items.length; index += 1) {
    if (index) total += 1 // the comma between two members
    total += memberBytes(items[index])
  }
  return total
}

// How many bytes save_bench() will count for this document, without building it. Written for the
// one shape a canvas has -- an object whose values are null, a small object, or an array of objects
// -- and anything else is serialised, which is always right.
export function documentBytes(doc) {
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return measuredBytes(doc)

  // A member whose value is undefined is not written at all, comma and all.
  const keys = Object.keys(doc).filter((key) => doc[key] !== undefined)
  if (keys.length === 0) return 2 // {}

  let total = 2 // { and }
  for (let index = 0; index < keys.length; index += 1) {
    if (index) total += 1
    const key = keys[index]
    total += layoutBytes(JSON.stringify(key)) + 1 // "key":
    const value = doc[key]
    total += Array.isArray(value) ? arrayBytes(value) : memberBytes(value)
  }
  return total
}

export const LAYOUT_TOO_LARGE_MESSAGE =
  'That is too much for one bench (4 MB maximum). Remove or hide a floor plan first.'
