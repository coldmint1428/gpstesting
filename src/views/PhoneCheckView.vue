<script setup>
// "Set up sharing" - the steps a phone needs before it can share its location, one screen at a time
// (like the location set-up of other live-location apps). The ONLY way in is pressing Share my location (on
// the event page, the GPS details page, or the push's Start sharing) when something is missing:
//
//   ?event=&group=&share=1  when the steps are done, sharing starts by itself.
//   (without share=1 it just reports the phone as set up -- no page links here that way)
//
// Only the steps that are missing are shown. Each has ONE button that opens the exact screen (apps may not
// change these settings themselves). Back in the app the step is checked again: done -> tick and next step;
// not done -> exactly where to tap. Required steps cannot be skipped; recommended ones can ("Skip for now").
// Layout is plain on purpose: it waits for the Figma design.
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { usePhoneReadiness } from '../composables/usePhoneReadiness'
import { useLocationTracker } from '../composables/useLocationTracker'
import { clearStartReminder } from '../composables/useStartReminders'
import { clearPushReminders } from '../composables/usePushNotifications'

const route = useRoute()
const router = useRouter()
const readiness = usePhoneReadiness()
const tracker = useLocationTracker()

const eventId = computed(() => String(route.query.event || ''))
const groupId = computed(() => String(route.query.group || ''))
const wantsToShare = computed(() => route.query.share === '1' && Boolean(eventId.value && groupId.value))

const items = ref([]) // every check, as last read
const steps = ref([]) // keys of the steps this visit has to go through (fixed at the first check)
const skipped = ref(new Set())
const tried = ref(new Set()) // steps whose button was pressed (then the tap hint is shown big)
const loaded = ref(false)
const busy = ref(false)
const justDone = ref('') // a step that has just become ticked (shown for a moment)
const starting = ref(false)
const startError = ref('')

let timer = null
let started = false

const byKey = computed(() => Object.fromEntries(items.value.map((i) => [i.key, i])))
const pending = computed(() =>
  steps.value.map((k) => byKey.value[k]).filter((i) => i && !i.ok && !skipped.value.has(i.key)),
)
const current = computed(() => pending.value[0] || null)
const stepNumber = computed(() => (current.value ? steps.value.indexOf(current.value.key) + 1 : steps.value.length))
// Line icons in place of the steps' emoji (the rest of the app draws icons, it never uses emoji)
const STEP_ICONS = {
  '📍': 'M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11zM12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z',
  '🎯': 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM12 12h.01',
  '🛰️': 'M13 7l4-4 4 4-4 4zM3 17l4-4 4 4-4 4zM9 9l6 6M16 13a5 5 0 0 1-5 5',
  '🔔': 'M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9M10.3 21a1.94 1.94 0 0 0 3.4 0',
  '🔋': 'M3 7h15a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM22 11v2M6 10v4M10 10v4',
  '⚡': 'M13 2 4 14h7l-1 8 9-12h-7z',
}
const stepIcon = computed(() => (current.value && STEP_ICONS[current.value.icon]) || STEP_ICONS['📍'])
// The bar counts the step you are on as started, so it never sits at an empty 0% (a head start keeps people going)
const progressPct = computed(() => Math.min(100, ((stepNumber.value - 0.5) / Math.max(1, steps.value.length)) * 100))
const requiredOk = computed(() => items.value.every((i) => !i.required || i.ok))
const done = computed(() => loaded.value && !current.value)
const skippedItems = computed(() => items.value.filter((i) => !i.ok && skipped.value.has(i.key)))

async function recheck() {
  const before = current.value ? current.value.key : ''
  const result = await readiness.check()
  items.value = result.items
  if (!loaded.value) {
    // The steps for this visit: what is missing now, required ones first.
    steps.value = result.items.filter((i) => !i.ok).sort((a, b) => Number(b.required) - Number(a.required)).map((i) => i.key)
    loaded.value = true
  }
  if (before && byKey.value[before] && byKey.value[before].ok) {
    justDone.value = before
    setTimeout(() => (justDone.value = ''), 1500)
  }
  if (done.value && wantsToShare.value && requiredOk.value) setTimeout(startSharing, 900)
}

async function doStep(item) {
  busy.value = true
  tried.value = new Set(tried.value).add(item.key)
  await readiness.fix(item)
  busy.value = false
  setTimeout(recheck, 500) // a system prompt was answered; a settings page is re-checked on return
}

function skip(item) {
  skipped.value = new Set(skipped.value).add(item.key)
  if (done.value && wantsToShare.value && requiredOk.value) setTimeout(startSharing, 600)
}

async function startSharing() {
  if (started || !wantsToShare.value) return
  started = true
  starting.value = true
  await tracker.start(eventId.value, groupId.value)
  starting.value = false
  if (!tracker.isTracking.value) {
    startError.value = tracker.errorMsg.value || 'Sharing could not start. Try again from the event page.'
    started = false
    return
  }
  clearStartReminder(eventId.value)
  clearPushReminders()
  router.replace({ name: 'event', params: { id: eventId.value } })
}

function leave() {
  if (eventId.value) router.replace({ name: 'event', params: { id: eventId.value } })
  else router.back()
}

function onVisible() {
  if (document.visibilityState === 'visible') setTimeout(recheck, 400)
}

onMounted(() => {
  recheck()
  document.addEventListener('visibilitychange', onVisible)
  // A quick-settings switch (Location, Power saving) does not leave the app, so look again now and then
  timer = setInterval(() => {
    if (document.visibilityState === 'visible' && !busy.value && !starting.value) recheck()
  }, 3000)
})
onUnmounted(() => {
  clearInterval(timer)
  document.removeEventListener('visibilitychange', onVisible)
})
</script>

<template>
  <main class="kp-page kp-page-sm pv-has-tabs" data-testid="phone-check">
    <!-- Not the phone app: nothing to set up here -->
    <div v-if="!readiness.isNative" class="kp-card kp-setup">
      <h1>Set up sharing</h1>
      <p class="kp-sub mb-3">This is for the phone app. In a browser, just allow location when asked.</p>
      <button class="btn btn-outline-secondary" data-testid="check-back" @click="leave">Back to event</button>
    </div>

    <p v-else-if="!loaded" class="kp-empty">Checking your phone…</p>

    <!-- One step -->
    <section v-else-if="current" class="kp-card kp-setup" :data-testid="'step-' + current.key">
      <div class="kp-inline mb-2" style="justify-content: space-between">
        <span class="small text-muted" data-testid="step-count">Step {{ stepNumber }} of {{ steps.length }}</span>
        <button class="btn btn-sm btn-ghost" data-testid="check-back" @click="leave">Not now</button>
      </div>
      <div class="kp-progress" role="progressbar" :aria-valuenow="stepNumber - 1" :aria-valuemax="steps.length"><span :style="{ width: progressPct + '%' }"></span></div>

      <div class="kp-setup-icon" aria-hidden="true"><svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path :d="stepIcon" /></svg></div>
      <h1>{{ current.title }}</h1>
      <p class="kp-sub">{{ current.body }}</p>
      <span v-if="!current.required" class="kp-chip mt-2">Recommended</span>

      <div v-if="tried.has(current.key)" class="alert alert-info small text-start mt-3" role="status" data-testid="step-hint">
        <strong>Not set yet.</strong> {{ current.tapHint }}
      </div>
      <p v-else class="kp-note mt-3">{{ current.tapHint }}</p>

      <div class="d-grid gap-2 mt-3">
        <button v-if="current.action" class="btn btn-primary btn-lg" :disabled="busy" data-testid="step-action" @click="doStep(current)">
          {{ current.action }}
        </button>
        <button v-if="!current.required" class="btn btn-ghost" data-testid="step-skip" @click="skip(current)">Skip for now</button>
      </div>
    </section>

    <!-- All steps done (or skipped) -->
    <section v-else class="kp-card kp-setup" data-testid="setup-done">
      <div class="kp-setup-icon" aria-hidden="true">✓</div>
      <template v-if="wantsToShare">
        <h1>You're ready</h1>
        <p v-if="!startError" class="kp-sub" data-testid="setup-starting">Starting to share your location…</p>
        <div v-else class="alert alert-danger small text-start" role="alert">{{ startError }}</div>
      </template>
      <template v-else>
        <h1>{{ steps.length ? "You're all set" : 'Your phone is ready' }}</h1>
        <p class="kp-sub">Tap <strong>Share my location</strong> when the event starts.</p>
      </template>

      <ul class="kp-list text-start mt-3" data-testid="setup-summary">
        <li v-for="item in items" :key="item.key" class="kp-row py-2" :data-testid="'summary-' + item.key">
          <span :class="item.ok ? 'text-success' : 'text-warning'">{{ item.ok ? '✓' : '!' }}</span>
          <span class="me-auto">{{ item.label }}</span>
          <span v-if="!item.ok" class="small text-muted">Skipped</span>
        </li>
      </ul>
      <p v-if="skippedItems.length" class="kp-note">Skipped items make sharing less reliable.</p>

      <div class="d-grid gap-2 mt-3">
        <button v-if="wantsToShare && startError" class="btn btn-success btn-lg" @click="startSharing">Try again</button>
        <button v-if="!wantsToShare || startError" class="btn btn-outline-secondary" data-testid="check-back" @click="leave">Back to event</button>
      </div>
    </section>

    <!-- A step just ticked -->
    <div v-if="justDone" class="kp-done-toast" role="status" data-testid="step-done">✓ Done</div>
  </main>
</template>
