// Save a file the page made (an Excel export, a CSV): a normal download in a browser; in the phone app,
// Android's own "Save to..." screen (android/.../SaveFilePlugin.java), because a download link does nothing
// inside the app's WebView. Returns true when saved, false when the person cancelled the Save screen.
import { Capacitor, registerPlugin } from '@capacitor/core'

const SaveFile = registerPlugin('SaveFile')

function toBase64(bytes) {
  let binary = ''
  const chunk = 0x8000 // String.fromCharCode in slices: a large file at once overflows the call stack
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
  return btoa(binary)
}

// A name every phone and laptop accepts: no / \ : * ? " < > |
export function safeFileName(name) {
  return String(name).replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 120) || 'file'
}

export async function saveFile(data, fileName, mimeType) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data)
  const name = safeFileName(fileName)
  if (Capacitor.isNativePlatform()) {
    // Android picks the icon and app by the bare type: "text/csv", not "text/csv;charset=utf-8"
    const { saved } = await SaveFile.save({ name, mimeType: String(mimeType).split(';')[0].trim(), base64: toBase64(bytes) })
    return saved
  }
  const url = URL.createObjectURL(new Blob([bytes], { type: mimeType }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
  return true
}

export const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
