// A miniature outline of a drawn area, for the list beside the map.
//
// The list used to show a square or a triangle chosen by the area's TYPE. Two "No-Go"
// areas then looked identical in the list even though they were different shapes on the
// map. This draws the area's own outline instead, so a row is recognisable as the polygon
// it belongs to -- the colour still carries the type.
//
// The maths is deliberately tiny: it is a thumbnail, not a projection. Latitude is only
// used to squash longitude by cos(lat), so the little shape has the same proportions as
// the one on the map rather than being stretched sideways.

// Returns the `points` attribute for an SVG <polygon>, or '' if there is nothing to draw.
// The result is fitted, aspect ratio intact, into a size x size box inset by `pad`.
export function outlinePoints(points, size = 30, pad = 3) {
  if (!Array.isArray(points) || points.length < 3) return ''

  const lat0 = points.reduce((sum, p) => sum + p[0], 0) / points.length
  const squash = Math.cos((lat0 * Math.PI) / 180)

  const xs = points.map((p) => p[1] * squash)
  const ys = points.map((p) => -p[0]) // SVG y grows downwards; north belongs at the top

  const minX = Math.min(...xs)
  const minY = Math.min(...ys)
  const spanX = Math.max(...xs) - minX
  const spanY = Math.max(...ys) - minY

  const box = size - pad * 2
  // A degenerate ring (all points in a line, or one repeated point) would divide by zero.
  const scale = box / Math.max(spanX, spanY, 1e-9)
  const offX = pad + (box - spanX * scale) / 2
  const offY = pad + (box - spanY * scale) / 2

  return points
    .map((_, i) => {
      const x = offX + (xs[i] - minX) * scale
      const y = offY + (ys[i] - minY) * scale
      return x.toFixed(2) + ',' + y.toFixed(2)
    })
    .join(' ')
}
