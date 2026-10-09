// The five area types, and everything the page derives from them.
//
// A type decides an area's colour and icon -- there is no colour picker, because the
// type IS the meaning. That keeps the map and the list from ever disagreeing.
//
// IMPORTANT: the same five values are listed in supabase/migrations/005_layouts.sql
// (inside public.area_ok). Adding a type here without adding it there means saves start
// failing with "The layout data is not valid".

export const AREA_KINDS = [
  { value: 'zone', label: 'Zone', colour: '#6c757d', icon: 'square' },
  { value: 'no_go', label: 'No-Go', colour: '#dc3545', icon: 'square' },
  { value: 'obstacle', label: 'Obstacle', colour: '#fd7e14', icon: 'square' },
  { value: 'stage', label: 'Stage', colour: '#6f42c1', icon: 'square' },
  { value: 'entrance', label: 'Entrance', colour: '#198754', icon: 'triangle' },
]

export const AREA_NAME_MAX = 50
export const AREA_MIN_POINTS = 3
export const AREA_MAX_POINTS = 200

const BY_VALUE = Object.fromEntries(AREA_KINDS.map((k) => [k.value, k]))

// A kind this build does not know about (saved by a newer one) falls back to Zone
// instead of crashing.
export function areaKind(value) {
  return BY_VALUE[value] || BY_VALUE.zone
}

export function areaColour(value) {
  return areaKind(value).colour
}

export function areaLabel(value) {
  return areaKind(value).label
}

// Leaflet path options for one saved area.
export function areaStyle(value, { dimmed = false } = {}) {
  const kind = areaKind(value)
  return {
    color: kind.colour,
    weight: dimmed ? 1 : 2,
    opacity: dimmed ? 0.5 : 1,
    fillColor: kind.colour,
    fillOpacity: dimmed ? 0.06 : 0.18,
    // No-Go reads as a warning even in a still screenshot.
    dashArray: kind.value === 'no_go' ? '6 4' : null,
  }
}

// Leaflet tooltips take HTML. The name is user-typed, so it is escaped by the caller
// (utils/people.js) -- this only adds the colour.
export function areaTooltipHtml(value, escapedName) {
  return '<span style="font-weight:600;color:' + areaColour(value) + '">' + escapedName + '</span>'
}

export function isValidAreaName(name) {
  const trimmed = String(name == null ? '' : name).trim()
  return trimmed.length >= 1 && trimmed.length <= AREA_NAME_MAX
}
