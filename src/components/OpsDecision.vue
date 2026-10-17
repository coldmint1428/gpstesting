<script setup>
// OpsDecision - a decision the show is waiting for (merger Stage 7), above the map:
//   * an "Auto when ready" cue holds because groups have not arrived: GO anyway / Keep holding / Message group admins
//   * an anchor is at risk: take 30 s off the running cue / skip the next cue / OK
// Root and planners decide; marshals see what is waiting. "OK" and "Keep holding" hide it on this screen only (Keep
// holding is told to the other planners); it comes back when it gets worse.
import { ref, computed } from 'vue'
import { askConfirm, toast } from '../composables/useNotify'
import { mmss, sgClock } from '../composables/useShow'

const props = defineProps({
  show: { type: Object, required: true }, // useShow()
  ops: { type: Object, default: null }, // useOps()
  groups: { type: Array, required: true },
  canRun: { type: Boolean, default: false },
})

const b = computed(() => props.show.board.value)
const next = computed(() => props.show.next.value)
const running = computed(() => props.show.running.value)
const now = computed(() => props.show.now.value)
const busy = ref(false)

// ---------- A cue waiting for its groups ----------
const keptCue = ref(null) // the cue this screen chose to keep holding
const holding = computed(() => {
  const n = next.value
  if (!n || running.value || n.wait_kind !== 'groups' || keptCue.value === n.cue_id) return null
  const names = n.missing || []
  return {
    cue: n,
    names,
    groupIds: names.map((name) => (props.groups.find((g) => g.name === name) || {}).id).filter(Boolean),
    waiting: n.waiting_since ? Math.round((now.value - new Date(n.waiting_since).getTime()) / 1000) : 0,
  }
})

async function goAnyway() {
  const h = holding.value
  const ok = await askConfirm({
    title: 'GO anyway: ' + h.cue.code + ' ' + h.cue.title + '?',
    message: 'It starts now without ' + h.names.slice(0, 5).join(', ') + (h.names.length > 5 ? ' and ' + (h.names.length - 5) + ' more' : '') + '.',
    confirmText: 'GO anyway',
  })
  if (!ok) return
  busy.value = true
  const err = await props.show.go(h.cue.cue_id)
  busy.value = false
  if (err) toast(err, 'danger', 8000)
}
async function keepHolding() {
  const h = holding.value
  busy.value = true
  const res = await props.ops.keepHolding(h.cue.cue_id)
  busy.value = false
  if (res.error) return toast(res.error, 'danger', 8000)
  keptCue.value = h.cue.cue_id
}

const writing = ref(false)
const text = ref('')
function openMessage() {
  writing.value = !writing.value
  text.value = holding.value ? holding.value.cue.code + ' ' + holding.value.cue.title + ' is waiting for your group: please get everyone into place now.' : ''
}
async function sendAll() {
  const h = holding.value
  if (!h || !h.groupIds.length) return
  busy.value = true
  let failed = ''
  for (const id of h.groupIds) {
    const res = await props.ops.message(id, text.value)
    if (res.error) failed = res.error
  }
  busy.value = false
  if (failed) return toast(failed, 'danger', 8000)
  toast('Message sent to ' + h.groupIds.length + (h.groupIds.length === 1 ? ' group.' : ' groups.'), 'success', 3000)
  writing.value = false
}

// ---------- An anchor at risk ----------
const okRisk = ref({}) // anchor cue id -> the risk (s) this screen said OK to
const risk = computed(() => {
  const a = b.value && b.value.anchor
  if (!a || !(a.risk_s > 0)) return null
  if (okRisk.value[a.cue_id] != null && a.risk_s < okRisk.value[a.cue_id] + 10) return null
  const skippable = props.show.upcoming.value.find((c) => c.type !== 'anchor' && c.pos < (props.show.cues.value.find((x) => x.cue_id === a.cue_id) || {}).pos)
  return { anchor: a, skippable }
})
async function takeOff30() {
  busy.value = true
  const err = await props.show.addTime(-30)
  busy.value = false
  if (err) toast(err, 'danger', 8000)
}
async function skipNext() {
  const c = risk.value.skippable
  const ok = await askConfirm({ title: 'Skip ' + c.code + ' "' + c.title + '"?', message: 'It will not run, which gains ' + mmss(c.length_s) + '.', confirmText: 'Skip', danger: true })
  if (!ok) return
  busy.value = true
  const err = await props.show.skip(c.cue_id)
  busy.value = false
  if (err) toast(err, 'danger', 8000)
}
function riskOk() {
  okRisk.value = { ...okRisk.value, [risk.value.anchor.cue_id]: risk.value.anchor.risk_s }
}
</script>

<template>
  <div v-if="holding || risk" class="d-grid gap-2 mb-2">
    <div v-if="holding" class="alert alert-warning py-2 mb-0" role="alert" data-testid="decision-holding">
      <div>
        <strong>{{ holding.cue.code }} {{ holding.cue.title }}</strong> is holding ({{ mmss(holding.waiting) }}): waiting for
        {{ holding.names.slice(0, 6).join(', ') }}<template v-if="holding.names.length > 6"> and {{ holding.names.length - 6 }} more</template>.
      </div>
      <div v-if="canRun" class="d-flex flex-wrap gap-2 mt-2">
        <button type="button" class="btn btn-sm btn-success" :disabled="busy" data-testid="decision-go" @click="goAnyway">GO anyway</button>
        <button type="button" class="btn btn-sm btn-outline-dark" :disabled="busy" data-testid="decision-keep" @click="keepHolding">Keep holding</button>
        <button
          v-if="holding.groupIds.length"
          type="button"
          class="btn btn-sm btn-outline-dark"
          :disabled="busy"
          data-testid="decision-message"
          @click="openMessage"
        >
          Message group admin{{ holding.groupIds.length > 1 ? 's' : '' }}
        </button>
      </div>
      <form v-if="writing" class="d-flex gap-1 mt-2" @submit.prevent="sendAll">
        <input v-model="text" class="form-control form-control-sm" maxlength="300" aria-label="Message to the groups" data-testid="decision-message-text" />
        <button type="submit" class="btn btn-sm btn-primary" :disabled="busy || !text.trim()" data-testid="decision-message-send">Send</button>
      </form>
    </div>

    <div v-if="risk" class="alert alert-danger py-2 mb-0" role="alert" data-testid="decision-anchor">
      <div>
        <strong>⚓ {{ risk.anchor.code }} {{ risk.anchor.title }} at {{ sgClock(risk.anchor.at) }} is at risk:</strong>
        the show is projected to run {{ mmss(risk.anchor.risk_s) }} into it. It starts on its time and cuts whatever is still running.
      </div>
      <div v-if="canRun" class="d-flex flex-wrap gap-2 mt-2">
        <button v-if="running" type="button" class="btn btn-sm btn-outline-dark" :disabled="busy" data-testid="decision-minus30" @click="takeOff30">
          −30 s on {{ running.code }}
        </button>
        <button v-if="risk.skippable" type="button" class="btn btn-sm btn-outline-dark" :disabled="busy" data-testid="decision-skip" @click="skipNext">
          Skip {{ risk.skippable.code }} ({{ mmss(risk.skippable.length_s) }})
        </button>
        <button type="button" class="btn btn-sm btn-outline-secondary" data-testid="decision-ok" @click="riskOk">OK</button>
      </div>
    </div>
  </div>
</template>
