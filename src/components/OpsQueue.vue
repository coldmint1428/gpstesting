<script setup>
// OpsQueue - the groups that need attention during the live show (merger Stage 7): late, no signal, at risk, the most
// urgent first. "I'll handle it" tells the other planners who has it; Acknowledge hides it until it gets worse;
// Snooze hides it for 2 minutes; Message sends the group's admins and ICs a line on their event page (and a push).
// A group that pressed "Tell planner: delayed" on its phone (Stage 8) is listed too, with what it said.
// Radio (029): each group shows its channel / call sign; what is heard on the radio goes in straight away: "In
// position" counts the arrival at once (GPS needs the IC inside for the stay time; undo within 5 min), "Held up"
// passes a delay on to every planner.
import { ref, computed } from 'vue'
import { toast } from '../composables/useNotify'
import { mmss, sgClock } from '../composables/useShow'
import { statusOf, statusText } from '../utils/opsStatus'

const props = defineProps({
  ops: { type: Object, required: true }, // useOps()
  now: { type: Number, required: true }, // the show's clock (server time)
})
const emit = defineEmits(['select']) // a group was tapped: show it on the map

const SHOWN = 5
const showAll = ref(false)
const queue = computed(() => props.ops.queue.value)
const visible = computed(() => (showAll.value ? queue.value : queue.value.slice(0, SHOWN)))
const busy = computed(() => props.ops.busy.value)

const groupName = (r) => {
  const g = props.ops.groupOf(r.group_id)
  return g ? g.name : 'A group'
}
const zoneCode = (r) => {
  const z = props.ops.zoneOf(r.zone_id)
  return z ? z.code : '?'
}
const secsTo = (at) => (at ? Math.round((new Date(at).getTime() - props.now) / 1000) : null)

// "Due 18:04:27 (in 1:40) · 160 m · walking 1.2 m/s" / "1 of 2 ICs heard · 1 inside"
function detail(r) {
  const out = []
  const due = secsTo(r.deadline)
  out.push('Due ' + sgClock(r.deadline) + (due != null ? (due >= 0 ? ' (in ' + mmss(due) + ')' : ' (' + mmss(-due) + ' ago)') : ''))
  if (r.status === 'no_signal') {
    out.push(
      r.sharing === 0
        ? 'no IC heard in the last 2 min' + (r.inside ? ' (' + r.inside + ' inside)' : '')
        : 'only ' + r.sharing + ' of the ' + r.required + ' ICs needed heard' + (r.inside ? ' · ' + r.inside + ' inside' : ''),
    )
  } else {
    if (r.remaining_m != null) out.push(Math.round(r.remaining_m) + ' m' + (r.basis === 'route' ? ' by route' : ''))
    out.push(r.moving && r.speed_mps != null ? 'moving ' + Number(r.speed_mps).toFixed(1) + ' m/s' : 'not moving yet')
    if (!r.moving && r.leave_by) {
      const lb = secsTo(r.leave_by)
      out.push(lb > 0 ? 'leave by ' + sgClock(r.leave_by) : 'should have left ' + mmss(-lb) + ' ago')
    }
  }
  if (r.no_signal && r.status !== 'no_signal') out.push(r.no_signal + ' IC' + (r.no_signal === 1 ? '' : 's') + ' without signal (not blocking)')
  return out.join(' · ')
}

async function report(promise, okText) {
  const res = await promise
  if (res.error) toast(res.error, 'danger', 8000)
  else if (okText) toast(typeof okText === 'function' ? okText(res.data) : okText, 'success', 3000)
}
const handle = (r) => report(props.ops.handle(r), (d) => (d === 'released' ? 'You let go of ' : 'You are handling ') + groupName(r) + '.')
const ack = (r) => report(props.ops.ack(r), 'Acknowledged: ' + groupName(r) + ' comes back if it gets worse.')
const snooze = (r) => report(props.ops.snooze(r, 120), groupName(r) + ' snoozed for 2 minutes.')

// Message the group's admins and ICs (a small form under the item)
const writing = ref(null) // group id
const text = ref('')
function openMessage(r) {
  writing.value = writing.value === r.group_id ? null : r.group_id
  text.value = 'Please head to ' + zoneCode(r) + ' now: due ' + sgClock(r.deadline) + '.'
}
// ---------- Radio ----------
const lastRadio = ref(null) // { r, at }: the last "in position" from here, for Undo (5 min)
async function inPosition(r) {
  const res = await props.ops.inPosition(r)
  if (res.error) return toast(res.error, 'danger', 8000)
  lastRadio.value = { r, at: Date.now() }
  toast(groupName(r) + ' in position at ' + zoneCode(r) + ' (radio).', 'success', 4000)
}
async function undoRadio() {
  const res = await props.ops.inPosition(lastRadio.value.r, true)
  if (res.error) return toast(res.error, 'danger', 8000)
  toast(groupName(lastRadio.value.r) + ' is not in position after all: back in the queue.', 'warning', 4000)
  lastRadio.value = null
}
const canUndo = computed(() => lastRadio.value && props.now - lastRadio.value.at < 300000)
const heldFor = ref(null) // group id: the "held up" form is open
const heldNote = ref('')
function openHeld(r) {
  heldFor.value = heldFor.value === r.group_id ? null : r.group_id
  heldNote.value = ''
}
async function sendHeld(r) {
  const res = await props.ops.radioDelay(r, heldNote.value)
  if (res.error) return toast(res.error, 'danger', 8000)
  heldFor.value = null
}

async function send(r) {
  const res = await props.ops.message(r.group_id, text.value)
  if (res.error) return toast(res.error, 'danger', 8000)
  toast('Message sent to ' + groupName(r) + '.', 'success', 3000)
  writing.value = null
}
</script>

<template>
  <div class="card ops-queue mb-3" data-testid="ops-queue">
    <div class="card-body py-2 d-flex align-items-baseline">
      <span class="small text-muted text-uppercase fw-semibold flex-grow-1">Needs attention · {{ queue.length }}</span>
      <button v-if="canUndo" type="button" class="btn btn-link btn-sm p-0 me-2" data-testid="ops-radio-undo" @click="undoRadio">
        Undo: {{ groupName(lastRadio.r) }} in position
      </button>
      <span class="small text-muted">most urgent first</span>
    </div>
    <p v-if="!queue.length" class="small text-muted px-3 pb-2 mb-0" data-testid="ops-queue-empty">
      {{ ops.loaded.value ? 'No group needs attention.' : 'Loading…' }}
      <template v-if="ops.hidden.value"> ({{ ops.hidden.value }} acknowledged or snoozed)</template>
    </p>
    <ul class="list-unstyled mb-0">
      <li
        v-for="r in visible"
        :key="r.movement_id + r.group_id"
        class="ops-item border-top px-3 py-2"
        :class="statusOf(r.status).cls + '-bg'"
        :data-testid="'ops-item-' + groupName(r)"
      >
        <div class="d-flex justify-content-between gap-2">
          <button type="button" class="btn btn-link p-0 text-start fw-semibold ops-name" :class="statusOf(r.status).cls" @click="emit('select', r.group_id)">
            {{ statusOf(r.status).symbol }} {{ groupName(r) }} → {{ zoneCode(r) }}
          </button>
          <span class="ops-num fw-bold text-nowrap" :class="statusOf(r.status).cls" data-testid="ops-item-status">
            {{ r.status === 'late' ? '+' + mmss(r.late_s || 0) : r.status === 'at_risk' ? r.spare_s + ' s spare' : statusText(r) }}
          </span>
        </div>
        <div class="small">{{ detail(r) }}</div>
        <div v-if="r.radio" class="small text-muted" data-testid="ops-radio">📻 {{ r.radio }}</div>
        <div v-if="r.delay_at" class="small fw-semibold text-danger" data-testid="ops-delay">
          ⚑ {{ r.delay_by || 'The group' }} reported a delay at {{ sgClock(r.delay_at) }}<template v-if="r.delay_note">: "{{ r.delay_note }}"</template>
        </div>
        <div v-if="r.handled_by" class="small fw-semibold" data-testid="ops-handled">Handled by {{ r.handled_mine ? 'you' : r.handled_by }}</div>
        <div class="d-flex flex-wrap gap-1 mt-1">
          <button
            type="button"
            class="btn btn-sm"
            :class="r.handled_mine ? 'btn-outline-dark' : 'btn-dark'"
            :disabled="!!busy || (!!r.handled_by && !r.handled_mine)"
            data-testid="ops-handle"
            @click="handle(r)"
          >
            {{ r.handled_mine ? 'Let go' : "I'll handle it" }}
          </button>
          <button type="button" class="btn btn-sm btn-outline-dark" :disabled="!!busy" data-testid="ops-message" @click="openMessage(r)">Message admin</button>
          <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="!!busy" data-testid="ops-ack" @click="ack(r)">Acknowledge</button>
          <button type="button" class="btn btn-sm btn-outline-secondary" :disabled="!!busy" data-testid="ops-snooze" @click="snooze(r)">Snooze 2 min</button>
          <button type="button" class="btn btn-sm btn-outline-success" :disabled="!!busy" title="Heard on the radio: counts at once" data-testid="ops-in-position" @click="inPosition(r)">
            ✓ In position (radio)
          </button>
          <button type="button" class="btn btn-sm btn-outline-danger" :disabled="!!busy" title="Heard on the radio: every planner sees it" data-testid="ops-held" @click="openHeld(r)">
            Held up (radio)
          </button>
        </div>
        <form v-if="heldFor === r.group_id" class="d-flex gap-1 mt-2" @submit.prevent="sendHeld(r)">
          <input v-model="heldNote" class="form-control form-control-sm" maxlength="200" placeholder="What did they say? (optional)" aria-label="Why the group is held up" data-testid="ops-held-note" />
          <button type="submit" class="btn btn-sm btn-danger" :disabled="!!busy" data-testid="ops-held-send">Tell planners</button>
        </form>
        <form v-if="writing === r.group_id" class="d-flex gap-1 mt-2" @submit.prevent="send(r)">
          <input v-model="text" class="form-control form-control-sm" maxlength="300" aria-label="Message to the group" data-testid="ops-message-text" />
          <button type="submit" class="btn btn-sm btn-primary" :disabled="!!busy || !text.trim()" data-testid="ops-message-send">Send</button>
        </form>
      </li>
    </ul>
    <button v-if="queue.length > SHOWN" type="button" class="btn btn-link btn-sm border-top rounded-0" data-testid="ops-show-all" @click="showAll = !showAll">
      {{ showAll ? 'Show fewer' : 'Show all ' + queue.length + ' →' }}
    </button>
  </div>
</template>

<style scoped>
.ops-num {
  font-variant-numeric: tabular-nums;
}
.ops-name {
  text-decoration: none;
}
</style>
