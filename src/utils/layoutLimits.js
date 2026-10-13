// How big the bench canvas is allowed to be.
//
// The authority is public.save_bench() in 005_layouts.sql, which refuses a canvas over
// 4 MB with the SQLSTATE 54000 (program_limit_exceeded). The check lives there rather than
// in the table's CHECK constraint because pg_column_size/octet_length are not immutable, so
// they cannot back a constraint.
//
// Knowing the same number here buys two things the database cannot give us:
//  - the planner is told BEFORE they add a floor plan that puts the canvas over the cap,
//    instead of losing the save afterwards;
//  - a refused save can say "remove or hide a floor plan" rather than repeating an error
//    code.
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

export const LAYOUT_TOO_LARGE_MESSAGE =
  'That is too much for one bench (4 MB maximum). Remove or hide a floor plan first.'
