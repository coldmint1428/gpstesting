<script setup>
// Ways to invite people: event code, invite link, QR code, WhatsApp / Telegram share.
// Library: qrcode (MIT) - https://github.com/soldair/node-qrcode
import { ref, computed, watch } from 'vue'
import QRCode from 'qrcode'

const props = defineProps({
  eventName: { type: String, required: true },
  joinCode: { type: String, required: true },
})

const qrDataUrl = ref('')
const copied = ref(false)

// The public address of the app. In the phone app window.location is "https://localhost",
// which other people can't open, so we prefer VITE_PUBLIC_APP_URL (e.g. the Vercel link).
const appUrl = (import.meta.env.VITE_PUBLIC_APP_URL || window.location.origin).replace(/\/$/, '')
const isLocalhost = /localhost|127\.0\.0\.1/.test(appUrl)

const inviteLink = computed(() => appUrl + '/join/' + props.joinCode)
const message = computed(
  () => 'Join "' + props.eventName + '" on Event Tracker. Code: ' + props.joinCode + ' - ' + inviteLink.value,
)
const whatsappUrl = computed(() => 'https://wa.me/?text=' + encodeURIComponent(message.value))
const telegramUrl = computed(
  () =>
    'https://t.me/share/url?url=' +
    encodeURIComponent(inviteLink.value) +
    '&text=' +
    encodeURIComponent('Join "' + props.eventName + '" on Event Tracker. Code: ' + props.joinCode),
)

// Re-draw the QR code whenever the link changes
watch(
  inviteLink,
  async (link) => {
    qrDataUrl.value = await QRCode.toDataURL(link, { width: 220, margin: 1 })
  },
  { immediate: true },
)

async function copyLink() {
  try {
    await navigator.clipboard.writeText(inviteLink.value)
    copied.value = true
    setTimeout(() => (copied.value = false), 2000)
  } catch {
    // Clipboard is blocked on http pages: the link is still visible to copy by hand
  }
}
</script>

<template>
  <div class="row g-3">
    <div class="col-12 col-md-6">
      <div class="card h-100">
        <div class="card-body">
          <h2 class="h6">Event code</h2>
          <p class="display-6 font-monospace mb-1" data-testid="join-code-display">{{ joinCode }}</p>
          <p class="small text-muted">People enter this on the Events page after creating an account.</p>

          <h2 class="h6 mt-3">Invite link</h2>
          <div class="input-group mb-2">
            <input class="form-control form-control-sm" :value="inviteLink" readonly aria-label="Invite link" data-testid="invite-link" />
            <button class="btn btn-outline-secondary btn-sm" type="button" @click="copyLink">
              {{ copied ? 'Copied!' : 'Copy' }}
            </button>
          </div>
          <div class="d-flex flex-wrap gap-2">
            <a :href="whatsappUrl" target="_blank" rel="noopener" class="btn btn-success btn-sm" data-testid="share-whatsapp">
              Share on WhatsApp
            </a>
            <a :href="telegramUrl" target="_blank" rel="noopener" class="btn btn-primary btn-sm" data-testid="share-telegram">
              Share on Telegram
            </a>
          </div>
          <p v-if="isLocalhost" class="small text-warning-emphasis mt-2 mb-0">
            This link points to localhost, so it only works on this computer. Set VITE_PUBLIC_APP_URL to your
            public https link (e.g. Vercel) to share it.
          </p>
        </div>
      </div>
    </div>
    <div class="col-12 col-md-6">
      <div class="card h-100">
        <div class="card-body text-center">
          <h2 class="h6">Scan to join</h2>
          <img v-if="qrDataUrl" :src="qrDataUrl" alt="QR code for the invite link" class="img-fluid" width="220" height="220" data-testid="invite-qr" />
        </div>
      </div>
    </div>
  </div>
</template>
