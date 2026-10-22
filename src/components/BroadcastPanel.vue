<script setup>
// BroadcastPanel - "Message everyone" for root and planners (032): one message to everyone, every group, all ICs, the
// staff, one sector or one category, with a push and a banner that stays until each person presses Got it. Quick
// messages cover the moments a show cannot wait for (lightning, hold, evacuate); "Shelter" and "Hold" can also hold
// the show, "Resume" can resume it. Under the form: the last day's messages, how many have read each, and who has not
// (with their group's radio channel), so the radio is used only for those.
//
// Website: a card on the Live page. Phone: a button that opens the same form in a bottom sheet.
import { computed, onUnmounted, ref, watch } from 'vue'
import BottomSheet from './BottomSheet.vue'
import { AUDIENCES, audienceText } from '../composables/useBroadcasts'
import { askConfirm, toast } from '../composables/useNotify'
import { formatTimeSeconds } from '../utils/time'

const props = defineProps({
  broadcasts: { type: Object, required: true }, // useBroadcasts()
  groups: { type: Array, default: () => [] },
  show: { type: Object, default: null }, // useShow(), to hold / resume with the message
  canRun: { type: Boolean, default: false },
  native: { type: Boolean, default: false },
})

const QUICK = [
  { key: 'shelter', label: '⚡ Lightning: shelter', urgent: true, also: 'hold', body: 'Lightning alert: take shelter now and stay there until we say it is safe.' },
  { key: 'hold', label: 'Hold in place', urgent: true, also: 'hold', body: 'Hold in place. Do not move until the next message.' },
  { key: 'resume', label: 'All clear: resume', urgent: false, also: 'resume', body: 'All clear. Go to your next position now: check your next move in the app.' },
  { key: 'rain', label: 'Wet weather plan', urgent: false, body: 'The wet weather plan is now in effect. Your next move in the app is updated.' },
  { key: 'late', label: 'Show running late', urgent: false, body: 'The show is running about 5 minutes late. Your times in the app are updated.' },
  { key: 'evacuate', label: 'Evacuate', urgent: true, body: 'Evacuate now: walk calmly to DISPERSAL and follow the marshals.' },
]

const open = ref(false)
const audience = ref('everyone')
const value = ref('')
const body = ref('')
const urgent = ref(false)
const quick = ref('')
const alsoShow = ref(false)
const sending = ref(false)
const formError = ref('')

const sectors = computed(() => [...new Set(props.groups.map((g) => g.sector).filter(Boolean))].sort())
const categories = computed(() => [...new Set(props.groups.map((g) => g.category).filter(Boolean))].sort())
const values = computed(() => (audience.value === 'sector' ? sectors.value : audience.value === 'category' ? categories.value : []))
watch(audience, () => {
  value.value = values.value[0] || ''
})

// Hold / resume the show with the message (only while a show is running, and only what makes sense now)
const held = computed(() => !!(props.show && props.show.board.value && props.show.board.value.state === 'held'))
const running = computed(() => !!(props.show && props.show.board.value))
const quickPick = computed(() => QUICK.find((q) => q.key === quick.value) || null)
const alsoWhat = computed(() => {
  if (!props.canRun || !running.value || !quickPick.value) return ''
  if (quickPick.value.also === 'hold' && !held.value) return 'hold'
  if (quickPick.value.also === 'resume' && held.value) return 'resume'
  return ''
})

function useQuick(q) {
  quick.value = q.key
  body.value = q.body
  urgent.value = q.urgent
  alsoShow.value = !!q.also
  formError.value = ''
}

async function send() {
  formError.value = ''
  const text = body.value.trim()
  if (!text) return (formError.value = 'Write the message first, or pick a quick message.')
  if ((audience.value === 'sector' || audience.value === 'category') && !value.value)
    return (formError.value = 'No group has a ' + audience.value + ' yet: set it in Members → Group details.')
  sending.value = true
  const dry = await props.broadcasts.send({ audience: audience.value, value: value.value, body: text, urgent: urgent.value, dry: true })
  sending.value = false
  if (dry.error) return (formError.value = dry.error)
  if (!dry.recipients) return (formError.value = 'Nobody would get this message: no one matches ' + audienceText(audience.value, value.value) + '.')
  const doAlso = alsoShow.value ? alsoWhat.value : ''
  const ok = await askConfirm({
    title: 'Send to ' + dry.recipients + (dry.recipients === 1 ? ' person' : ' people') + '?',
    message:
      (urgent.value ? 'URGENT · ' : '') + '"' + text + '" goes to ' + audienceText(audience.value, value.value) +
      ' as a push and a banner that stays until they press Got it.' +
      (doAlso === 'hold' ? ' The show will be put on hold.' : doAlso === 'resume' ? ' The show will resume.' : ''),
    confirmText: 'Send',
    danger: urgent.value,
  })
  if (!ok) return
  sending.value = true
  const res = await props.broadcasts.send({ audience: audience.value, value: value.value, body: text, urgent: urgent.value })
  sending.value = false
  if (res.error) return (formError.value = res.error)
  toast('Sent to ' + res.recipients + (res.recipients === 1 ? ' person.' : ' people.'), 'success', 4000)
  if (doAlso === 'hold') {
    const err = await props.show.hold()
    if (err) toast('Message sent, but the show could not be held: ' + err, 'danger', 8000)
  } else if (doAlso === 'resume') {
    const err = await props.show.resume()
    if (err) toast('Message sent, but the show could not resume: ' + err, 'danger', 8000)
  }
  body.value = ''
  quick.value = ''
  urgent.value = false
  alsoShow.value = false
  if (props.native) open.value = false
  watchStatus(res.id)
}

// ---------- Who has read it ----------
const statuses = ref({}) // id -> { total, seen, acked, waiting }
const expanded = ref(null)
const recent = computed(() => props.broadcasts.sent.value.slice(0, 5))
async function refreshStatus() {
  for (const b of recent.value) {
    if (b.cleared && statuses.value[b.id]) continue
    const s = await props.broadcasts.status(b.id)
    if (!s.error) statuses.value = { ...statuses.value, [b.id]: s }
  }
}
let timer = null
function watchStatus() {
  refreshStatus()
}
watch(recent, refreshStatus, { immediate: true })
timer = setInterval(() => {
  if (document.visibilityState === 'visible' && recent.value.some((b) => !b.cleared)) refreshStatus()
}, 5000)
onUnmounted(() => clearInterval(timer))

async function clearOne(b) {
  const ok = await askConfirm({
    title: 'Take this message down?',
    message: '"' + b.body + '" disappears from everyone\'s screen. It stays in this list as a record.',
    confirmText: 'Take down',
  })
  if (!ok) return
  const err = await props.broadcasts.clear(b.id)
  if (err) toast(err, 'danger', 8000)
}
</script>

<template>
  <section class="card bc-panel" data-testid="broadcast-panel">
    <div class="card-body d-grid gap-2">
      <div class="d-flex flex-wrap align-items-center gap-2">
        <h3 class="h6 mb-0 flex-grow-1">Message everyone</h3>
        <button
          type="button"
          class="btn btn-sm"
          :class="open ? 'btn-outline-secondary' : 'btn-primary'"
          data-testid="broadcast-open"
          @click="open = !open"
        >
          {{ open && !native ? 'Close' : 'Write a message' }}
        </button>
      </div>
      <p v-if="!recent.length && !open" class="small text-muted mb-0">
        One message to every group, a sector or the staff at once: a push and a banner until they press Got it.
      </p>

      <!-- The form: inline on the website, in a bottom sheet on the phone -->
      <component :is="native ? BottomSheet : 'div'" v-bind="native ? { open, title: 'Message everyone' } : {}" @close="open = false">
        <form v-if="native || open" class="d-grid gap-2" data-testid="broadcast-form" @submit.prevent="send">
          <div>
            <div class="small fw-semibold mb-1">Quick messages</div>
            <div class="d-flex flex-wrap gap-1" role="group" aria-label="Quick messages">
              <button
                v-for="q in QUICK"
                :key="q.key"
                type="button"
                class="btn btn-sm rounded-pill"
                :class="quick === q.key ? (q.urgent ? 'btn-danger' : 'btn-dark') : q.urgent ? 'btn-outline-danger' : 'btn-outline-secondary'"
                :data-testid="'broadcast-quick-' + q.key"
                @click="useQuick(q)"
              >
                {{ q.label }}
              </button>
            </div>
          </div>
          <div class="row g-2">
            <div :class="values.length || audience === 'sector' || audience === 'category' ? 'col-12 col-sm-6' : 'col-12'">
              <label class="form-label small fw-semibold mb-1" for="bc-audience">Who gets it</label>
              <select id="bc-audience" v-model="audience" class="form-select" data-testid="broadcast-audience">
                <option v-for="a in AUDIENCES" :key="a.value" :value="a.value">{{ a.label }}</option>
              </select>
            </div>
            <div v-if="audience === 'sector' || audience === 'category'" class="col-12 col-sm-6">
              <label class="form-label small fw-semibold mb-1" for="bc-value">{{ audience === 'sector' ? 'Sector' : 'Category' }}</label>
              <select id="bc-value" v-model="value" class="form-select" :disabled="!values.length" data-testid="broadcast-value">
                <option v-if="!values.length" value="">None set in Group details</option>
                <option v-for="v in values" :key="v" :value="v">{{ v }}</option>
              </select>
            </div>
          </div>
          <div>
            <label class="form-label small fw-semibold mb-1" for="bc-body">Message</label>
            <textarea
              id="bc-body"
              v-model="body"
              class="form-control"
              rows="3"
              maxlength="300"
              placeholder="e.g. Lightning alert: take shelter now."
              data-testid="broadcast-body-input"
              @input="quick = ''"
            ></textarea>
            <div class="form-text text-end">{{ body.length }} / 300</div>
          </div>
          <div class="d-flex flex-wrap gap-3">
            <div class="form-check">
              <input id="bc-urgent" v-model="urgent" class="form-check-input" type="checkbox" data-testid="broadcast-urgent" />
              <label class="form-check-label" for="bc-urgent">Urgent (red)</label>
            </div>
            <div v-if="alsoWhat" class="form-check">
              <input id="bc-also" v-model="alsoShow" class="form-check-input" type="checkbox" data-testid="broadcast-also" />
              <label class="form-check-label" for="bc-also">{{ alsoWhat === 'hold' ? 'Also hold the show' : 'Also resume the show' }}</label>
            </div>
          </div>
          <div v-if="formError" class="small text-danger" role="alert" data-testid="broadcast-error">{{ formError }}</div>
          <button type="submit" class="btn" :class="urgent ? 'btn-danger' : 'btn-primary'" :disabled="sending || broadcasts.busy.value" data-testid="broadcast-send">
            {{ sending ? 'Checking…' : 'Send' }}
          </button>
        </form>
      </component>

      <!-- The last day's messages: who has read them -->
      <ul v-if="recent.length" class="list-unstyled mb-0 d-grid gap-2" data-testid="broadcast-sent">
        <li v-for="b in recent" :key="b.id" class="bc-item" :class="{ 'opacity-75': b.cleared }">
          <div class="d-flex align-items-start gap-2">
            <span class="flex-grow-1 min-w-0 small">
              <span v-if="b.urgent" class="badge text-bg-danger me-1">Urgent</span>
              <strong>{{ formatTimeSeconds(b.at) }}</strong> · to {{ audienceText(b.audience, b.value) }}
              <span v-if="b.cleared" class="text-muted"> · taken down</span>
              <span class="d-block bc-text">{{ b.body }}</span>
              <span v-if="statuses[b.id]" class="d-block" data-testid="broadcast-count">
                <strong>Got it: {{ statuses[b.id].acked }} of {{ statuses[b.id].total }}</strong>
                <span class="text-muted"> · seen by {{ statuses[b.id].seen }}</span>
                <button
                  v-if="statuses[b.id].waiting.length"
                  type="button"
                  class="btn btn-link btn-sm p-0 ms-1 align-baseline"
                  :data-testid="'broadcast-who-' + b.id"
                  @click="expanded = expanded === b.id ? null : b.id"
                >
                  {{ expanded === b.id ? 'Hide' : 'Who has not (' + statuses[b.id].waiting.length + ')' }}
                </button>
              </span>
            </span>
            <button v-if="!b.cleared" type="button" class="btn btn-sm btn-outline-secondary flex-shrink-0" :data-testid="'broadcast-clear-' + b.id" @click="clearOne(b)">
              Take down
            </button>
          </div>
          <ul v-if="expanded === b.id && statuses[b.id]" class="small mb-0 mt-1 ps-3" data-testid="broadcast-waiting">
            <li v-for="(w, i) in statuses[b.id].waiting" :key="i">
              {{ w.name }}<span v-if="w.group" class="text-muted"> · {{ w.group }}{{ w.ic ? ' (IC)' : '' }}</span>
              <span v-if="w.radio" class="text-muted"> · radio {{ w.radio }}</span>
              <span class="text-muted"> · {{ w.seen ? 'seen, not confirmed' : 'not seen' }}</span>
            </li>
          </ul>
        </li>
      </ul>
    </div>
  </section>
</template>

<style scoped>
.bc-item {
  border-top: 1px solid var(--bs-border-color);
  padding-top: 8px;
}
.bc-text {
  overflow-wrap: anywhere;
}
.min-w-0 {
  min-width: 0;
}
</style>
