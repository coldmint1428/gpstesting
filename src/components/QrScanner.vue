<script setup>
// QrScanner - the phone's back camera, read for a QR code. Emits `scan` with the QR's text once per code it sees (the
// parent says when to look again with `paused`), and `error` when the camera cannot be used.
// Beyond the course: the camera (navigator.mediaDevices.getUserMedia) and reading its frames through a <canvas> have no
// Vue or Bootstrap equivalent. Library: jsQR (Apache-2.0) - https://github.com/cozmo/jsQR
import { ref, onMounted, onUnmounted } from 'vue'
import jsQR from 'jsqr'

const props = defineProps({
  paused: { type: Boolean, default: false }, // the parent is checking a code: do not send another yet
})
const emit = defineEmits(['scan', 'error'])

const video = ref(null)
const starting = ref(true)
let stream = null
let frame = 0
let lastText = ''
let lastAt = 0
const canvas = document.createElement('canvas')
const context = canvas.getContext('2d', { willReadFrequently: true })

// Look at the camera about 6 times a second (each look reads the whole frame)
let lastLook = 0
function look(time) {
  frame = requestAnimationFrame(look)
  const v = video.value
  if (props.paused || !v || v.readyState < 2 || time - lastLook < 160) return
  lastLook = time
  // A smaller copy of the frame is enough for a QR filling part of the screen, and much quicker to read
  const scale = Math.min(1, 640 / Math.max(v.videoWidth, v.videoHeight))
  canvas.width = Math.round(v.videoWidth * scale)
  canvas.height = Math.round(v.videoHeight * scale)
  context.drawImage(v, 0, 0, canvas.width, canvas.height)
  const image = context.getImageData(0, 0, canvas.width, canvas.height)
  const found = jsQR(image.data, image.width, image.height, { inversionAttempts: 'dontInvert' })
  if (!found || !found.data) return
  // the same code again within 2 s: already sent
  if (found.data === lastText && Date.now() - lastAt < 2000) return
  lastText = found.data
  lastAt = Date.now()
  emit('scan', found.data)
}

onMounted(async () => {
  try {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      throw new Error('This browser cannot use the camera. Use the app, or the latest Chrome or Safari.')
    }
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false })
    video.value.srcObject = stream
    await video.value.play()
    starting.value = false
    frame = requestAnimationFrame(look)
  } catch (error) {
    starting.value = false
    const denied = error && (error.name === 'NotAllowedError' || error.name === 'SecurityError')
    emit('error', denied ? 'The camera is blocked. Allow the camera for this app in your phone settings, then try again.' : error.message)
  }
})

onUnmounted(() => {
  cancelAnimationFrame(frame)
  if (stream) stream.getTracks().forEach((t) => t.stop())
})
</script>

<template>
  <div class="scanner">
    <video ref="video" class="scanner-video" muted playsinline aria-label="Camera"></video>
    <div class="scanner-frame" aria-hidden="true"></div>
    <p v-if="starting" class="scanner-note">Starting the camera…</p>
  </div>
</template>

<style scoped>
.scanner {
  position: relative;
  width: 100%;
  max-width: 22rem;
  aspect-ratio: 1;
  margin: 0 auto;
  border-radius: 0.75rem;
  overflow: hidden;
  background: #000;
}
.scanner-video {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
/* the square to put the QR in */
.scanner-frame {
  position: absolute;
  inset: 15%;
  border: 3px solid rgba(255, 255, 255, 0.85);
  border-radius: 0.75rem;
  box-shadow: 0 0 0 999px rgba(0, 0, 0, 0.35);
}
.scanner-note {
  position: absolute;
  inset: auto 0 0.5rem;
  margin: 0;
  text-align: center;
  color: #fff;
  font-size: 0.875rem;
}
</style>
