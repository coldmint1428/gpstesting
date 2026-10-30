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
  <main class="container py-3 setup pv-has-tabs" data-testid="phone-check">
    <!-- Not the phone app: nothing to set up here -->
    <template v-if="!readiness.isNative">
      <h1 class="h4">Set up sharing</h1>
      <p class="text-muted">These steps are for the phone app. In a browser, just allow location when asked.</p>
      <button class="btn btn-outline-secondary" data-testid="check-back" @click="leave">Back to the event</button>
    </template>

    <p v-else-if="!loaded" class="text-muted text-center mt-5">Checking your phone…</p>

    <!-- One step -->
    <section v-else-if="current" class="text-center" :data-testid="'step-' + current.key">
      <div class="d-flex justify-content-between align-items-center small text-muted mb-2">
        <span data-testid="step-count">Step {{ stepNumber }} of {{ steps.length }}</span>
        <button class="btn btn-link btn-sm text-muted p-0" data-testid="check-back" @click="leave">Not now</button>
      </div>
      <div class="progress mb-4" role="progressbar" :aria-valuenow="stepNumber - 1" :aria-valuemax="steps.length" style="height: 6px">
        <div class="progress-bar bg-success" :style="{ width: ((stepNumber - 1) / steps.length) * 100 + '%' }"></div>
      </div>

      <div class="step-icon mb-3" aria-hidden="true">{{ current.icon }}</div>
      <h1 class="h4 mb-2">{{ current.title }}</h1>
      <p class="text-muted mb-1">{{ current.body }}</p>
      <p v-if="!current.required" class="small text-muted mb-3">Recommended</p>

      <div
        v-if="tried.has(current.key)"
        class="alert alert-info small text-start mt-3"
        role="status"
        data-testid="step-hint"
      >
        <strong>Not set yet.</strong> {{ current.tapHint }}
      </div>
      <p v-else class="small text-muted mt-3">{{ current.tapHint }}</p>

      <div class="d-grid gap-2 mt-3">
        <button
          v-if="current.action"
          class="btn btn-primary btn-lg"
          :disabled="busy"
          data-testid="step-action"
          @click="doStep(current)"
        >
          {{ current.action }}
        </button>
        <button
          v-if="!current.required"
          class="btn btn-link text-muted"
          data-testid="step-skip"
          @click="skip(current)"
        >
          Skip for now
        </button>
      </div>
    </section>

    <!-- All steps done (or skipped) -->
    <section v-else class="text-center mt-4" data-testid="setup-done">
      <div class="step-icon mb-3 text-success" aria-hidden="true">✓</div>
      <template v-if="wantsToShare">
        <h1 class="h4 mb-2">You're ready</h1>
        <p v-if="!startError" class="text-muted" data-testid="setup-starting">Starting to share your location…</p>
        <div v-else class="alert alert-danger small text-start" role="alert">{{ startError }}</div>
      </template>
      <template v-else>
        <h1 class="h4 mb-2">{{ steps.length ? "You're all set" : 'Your phone is ready' }}</h1>
        <p class="text-muted">When the event starts, tap <strong>Share my location</strong> (or Start sharing in the notification).</p>
      </template>

      <ul class="list-unstyled small text-start d-inline-block mt-2" data-testid="setup-summary">
        <li v-for="item in items" :key="item.key" :data-testid="'summary-' + item.key">
          <span :class="item.ok ? 'text-success' : 'text-warning'">{{ item.ok ? '✓' : '!' }}</span>
          {{ item.label }}<span v-if="!item.ok" class="text-muted"> (skipped)</span>
        </li>
      </ul>
      <p v-if="skippedItems.length" class="small text-muted">Skipped items make sharing less reliable. They will be asked again next time.</p>

      <div class="d-grid gap-2 mt-2">
        <button v-if="wantsToShare && startError" class="btn btn-success btn-lg" @click="startSharing">Try again</button>
        <button v-if="!wantsToShare || startError" class="btn btn-outline-secondary" data-testid="check-back" @click="leave">Back to the event</button>
      </div>
    </section>

    <!-- A step just ticked -->
    <div v-if="justDone" class="done-toast" role="status" data-testid="step-done">✓ Done</div>
  </main>
</template>

<style scoped>
.setup {
  max-width: 480px;
}
.step-icon {
  font-size: 3.5rem;
  line-height: 1;
}
.done-toast {
  position: fixed;
  left: 50%;
  bottom: 2rem;
  transform: translateX(-50%);
  background: var(--status-success-fg);
  color: #fff;
  padding: 0.4rem 1rem;
  border-radius: 999px;
  font-weight: 600;
}
</style>
