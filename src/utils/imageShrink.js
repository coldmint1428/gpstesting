// Shrink an uploaded floor plan before it goes near the database.
//
// The image lives INSIDE the layout row (as a base64 data URL), so its size is part of
// every page load and of the 4 MB cap enforced by public.save_bench(). 512 KB is the
// ceiling we aim for.
//
// PNG comes first: a floor plan is line art, and PNG keeps it crisp and keeps the
// background transparent -- which matters because the plan is overlaid translucent on
// the map. A JPEG on white is the last resort, because it loses transparency and softens
// fine text.

export const MAX_IMAGE_BYTES = 512 * 1024

// Tried in order; the first size that fits wins.
const LONG_EDGE_STEPS = [2000, 1600, 1280, 1024, 800]
const JPEG_QUALITIES = [0.85, 0.7, 0.55, 0.4]

function fitInside(width, height, longEdge) {
  const scale = Math.min(1, longEdge / Math.max(width, height))
  return {
    w: Math.max(1, Math.round(width * scale)),
    h: Math.max(1, Math.round(height * scale)),
  }
}

async function loadSource(file) {
  if (typeof createImageBitmap === 'function') {
    try {
      return await createImageBitmap(file)
    } catch {
      // Some formats/scans fail here but still load through an <img>; try that instead.
    }
  }

  const url = URL.createObjectURL(file)
  try {
    return await new Promise((resolve, reject) => {
      const el = new Image()
      el.onload = () => resolve(el)
      el.onerror = () => reject(new Error('That file could not be read as an image.'))
      el.src = url
    })
  } finally {
    URL.revokeObjectURL(url)
  }
}

function drawTo(width, height, source, background) {
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d')
  if (background) {
    ctx.fillStyle = background
    ctx.fillRect(0, 0, width, height)
  }
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(source, 0, 0, width, height)
  return canvas
}

function toBlob(canvas, type, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality))
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error || new Error('Could not read the shrunk image.'))
    reader.readAsDataURL(blob)
  })
}

// Returns { dataUrl, bytes, type, width, height } -- dataUrl is what gets stored.
// Throws with a message meant for the planner if the image cannot be made small enough.
export async function shrinkToUnder(file, maxBytes = MAX_IMAGE_BYTES) {
  if (!file) throw new Error('Choose an image file first.')

  const source = await loadSource(file)
  const srcW = source.width || source.naturalWidth
  const srcH = source.height || source.naturalHeight
  if (!srcW || !srcH) throw new Error('That image has no readable size.')

  // 1. PNG, keeping transparency and sharp edges.
  for (const longEdge of LONG_EDGE_STEPS) {
    const { w, h } = fitInside(srcW, srcH, longEdge)
    const blob = await toBlob(drawTo(w, h, source), 'image/png')
    if (blob && blob.size <= maxBytes) {
      return {
        dataUrl: await blobToDataUrl(blob),
        bytes: blob.size,
        type: 'image/png',
        width: w,
        height: h,
      }
    }
  }

  // 2. JPEG on white -- smaller, but opaque and softer.
  for (const longEdge of LONG_EDGE_STEPS) {
    const { w, h } = fitInside(srcW, srcH, longEdge)
    for (const quality of JPEG_QUALITIES) {
      const blob = await toBlob(drawTo(w, h, source, '#ffffff'), 'image/jpeg', quality)
      if (blob && blob.size <= maxBytes) {
        return {
          dataUrl: await blobToDataUrl(blob),
          bytes: blob.size,
          type: 'image/jpeg',
          width: w,
          height: h,
        }
      }
    }
  }

  throw new Error(
    'That image could not be shrunk below ' +
      Math.round(maxBytes / 1024) +
      ' KB. Try a smaller or simpler scan.',
  )
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return '-'
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}
