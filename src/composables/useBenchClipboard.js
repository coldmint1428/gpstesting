// The bench's clipboard: one floor plan or one area, held for the length of the session.
//
// Deliberately NOT the system clipboard. Pasting a shape means pasting COORDINATES and a NAME,
// and the system clipboard only carries text -- which would either be unreadable JSON that any
// other application could clobber between the copy and the paste, or a text format nobody can
// see. Keeping it here means a copy always pastes back into this bench exactly what was copied,
// whatever else the planner does with Ctrl+C in between.
//
// In memory, per tab, like the undo stack: a floor plan image lives inside the plan, so copying
// one to local storage would write the image a second time to no purpose -- the paste only has
// to survive until the planner uses it.
import { computed, ref } from 'vue'

const clip = ref(null) // { kind: 'plan' | 'area', item }

// How far a pasted copy lands from the original, in metres. Far enough to be seen as its own
// shape sitting next to it, near enough that it is obviously the copy.
export const PASTE_OFFSET_M = 25

// Shift one coordinate by `metres` east and south -- the same convention the rest of the bench
// uses (see utils/floorPlan.js): a degree of longitude is shorter than a degree of latitude, and
// at Singapore's latitude the difference is large enough to see.
export function offsetLatLng(latlng, metres) {
  const [lat, lng] = latlng
  const north = metres / 111320
  const east = metres / (111320 * Math.cos((lat * Math.PI) / 180))
  return [lat - north, lng + east]
}

// "Level 1" -> "Level 1 copy"; pressed again, "Level 1 copy 2". `taken` is what is already in
// use, so a paste can never silently produce two rows with the same name.
export function copyName(name, taken) {
  const said = String(name || '').trim()
  const stem = said || 'Untitled'
  const used = new Set((taken || []).map((one) => String(one || '').trim()))
  const first = stem + ' copy'
  if (!used.has(first)) return first
  let n = 2
  while (used.has(stem + ' copy ' + n)) n += 1
  return stem + ' copy ' + n
}

// The zone code for a copy: the original's code with the next free number (ABC -> ABC_2, ABC_2 ->
// ABC_3). The database refuses a code that is taken, so a copy must never carry its original's.
export function copyCode(code, taken) {
  if (!code) return undefined
  const stem = String(code).replace(/_\d+$/, '')
  const used = new Set((taken || []).map((one) => String(one || '').toUpperCase()))
  let n = 2
  while (used.has(stem + '_' + n)) n += 1
  const suffix = '_' + n
  return stem.slice(0, 40 - suffix.length) + suffix
}

export function useBenchClipboard() {
  const plan = computed(() => (clip.value && clip.value.kind === 'plan' ? clip.value.item : null))
  const area = computed(() => (clip.value && clip.value.kind === 'area' ? clip.value.item : null))

  function copyPlan(item) {
    clip.value = { kind: 'plan', item: { ...item } }
  }

  function copyArea(item) {
    clip.value = {
      kind: 'area',
      item: { ...item, points: Array.isArray(item.points) ? item.points.map((p) => [p[0], p[1]]) : [] },
    }
  }

  function clear() {
    clip.value = null
  }

  return { plan, area, copyPlan, copyArea, clear }
}
