<script setup>
// Ways to invite people: event code, invite link, QR code, WhatsApp / Telegram share.
// Library: qrcode (MIT) - https://github.com/soldair/node-qrcode
import { ref, computed, watch } from 'vue'
import QRCode from 'qrcode'
import { Capacitor } from '@capacitor/core'
import { toast } from '../composables/useNotify'

const props = defineProps({
  eventName: { type: String, required: true },
  joinCode: { type: String, required: true },
})

const qrDataUrl = ref('')
const copied = ref(false)

// The public address of the app. In the phone app window.location is "https://localhost",
// which other people can't open, so we prefer VITE_PUBLIC_APP_URL (e.g. the Vercel link).
// The phone app never falls back to its own address: a build made without the variable (a
// local .env that leaves it blank) still shares links people can open -- the deployed site.
// Nor does the website on a laptop (npm run dev, http://localhost:5173): VITE_PUBLIC_APP_URL set on Vercel only
// reaches Vercel's own builds, and the deployed site reads the same database, so its link works for a local event.
const DEPLOYED_URL = 'https://gpstesting.vercel.app'
const ownOrigin = window.location.origin
const appUrl = (
  import.meta.env.VITE_PUBLIC_APP_URL ||
  (Capacitor.isNativePlatform() || /localhost|127\.0\.0\.1/.test(ownOrigin) ? DEPLOYED_URL : ownOrigin)
).replace(/\/$/, '')
const isLocalhost = /localhost|127\.0\.0\.1/.test(appUrl)

const inviteLink = computed(() => appUrl + '/join/' + props.joinCode)
const message = computed(
  () => 'Join "' + props.eventName + '" on Planova. Code: ' + props.joinCode + ' - ' + inviteLink.value,
)
const whatsappUrl = computed(() => 'https://wa.me/?text=' + encodeURIComponent(message.value))
const telegramUrl = computed(
  () =>
    'https://t.me/share/url?url=' +
    encodeURIComponent(inviteLink.value) +
    '&text=' +
    encodeURIComponent('Join "' + props.eventName + '" on Planova. Code: ' + props.joinCode),
)

// Re-draw the QR code whenever the link changes
watch(
  inviteLink,
  async (link) => {
    qrDataUrl.value = await QRCode.toDataURL(link, { width: 220, margin: 1 })
  },
  { immediate: true },
)

async function copyCode() {
  try {
    await navigator.clipboard.writeText(props.joinCode)
    toast('Event code copied.', 'success', 2500)
  } catch {
    toast('Could not copy the code.', 'danger', 4000)
  }
}

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
  <section class="k ov2-inv" aria-label="Invite people">
    <div style="min-width: 0">
      <span class="ey" style="color: var(--lime)">Invite people</span>
      <div class="mut2">Event code</div>
      <div class="row" style="gap: 6px">
        <span class="ov2-code U" data-testid="join-code-display">{{ joinCode }}</span>
        <button type="button" class="ib" aria-label="Copy event code" data-testid="copy-code" @click="copyCode"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 9h11v11H9zM5 15H4V4h11v1"></path></svg></button>
      </div>
      <div class="mut2" style="margin-top: 20px">Invite link</div>
      <div class="ov2-link">
        <span data-testid="invite-link">{{ inviteLink }}</span>
        <button type="button" class="kb kb-lime kb-sm" @click="copyLink">{{ copied ? 'Copied!' : 'Copy' }}</button>
      </div>
      <div class="row" style="margin-top: 14px; gap: 8px; flex-wrap: wrap">
        <a :href="whatsappUrl" target="_blank" rel="noopener" class="kb kb-sm ov2-share" data-testid="share-whatsapp">WhatsApp</a>
        <a :href="telegramUrl" target="_blank" rel="noopener" class="kb kb-sm ov2-share" data-testid="share-telegram">Telegram</a>
      </div>
      <p v-if="isLocalhost" class="kp-invite-warn mt-2">This link only works on this computer. Set VITE_PUBLIC_APP_URL to share it.</p>
    </div>
    <div class="ov2-qr">
      <img v-if="qrDataUrl" :src="qrDataUrl" alt="QR code for the invite link" width="132" height="132" data-testid="invite-qr" />
      <a v-if="qrDataUrl" class="link" :href="qrDataUrl" :download="'planova-' + joinCode + '.png'" data-testid="save-qr">Save QR</a>
    </div>
    <p class="ov2-foot">People enter the code on their Events page, or scan the QR to join.</p>
  </section>
</template>
