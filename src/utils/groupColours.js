// Group colours (Planova 2 "Harbour & Signal"). Cool Okabe–Ito hues only: warm colours mean live (marigold), late
// (amber) and danger (red) everywhere in the app, so a group is never orange or red. Five hues; a sixth group repeats
// the first, and the map always shows the group's code, so colour is never the only cue.
export const GROUP_PALETTE = ['#0072B2', '#56B4E9', '#009E73', '#CC79A7', '#6A4C93']

// The colour a new group gets: the next one in the palette (it can still be changed)
export function nextGroupColour(groups) {
  return GROUP_PALETTE[(groups ? groups.length : 0) % GROUP_PALETTE.length]
}

function luminance(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '')
  if (!m) return 0.2
  const c = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255)
  const f = (x) => (x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4))
  return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
}

// Text on a group-coloured dot: white or ink, whichever contrasts more (white fails on sky, green and pink)
export function textOn(hex) {
  const l = luminance(hex)
  return 1.05 / (l + 0.05) >= (l + 0.05) / (0.0137 + 0.05) ? '#FFFFFF' : '#14201B'
}
