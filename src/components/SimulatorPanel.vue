<script setup>
// SimulatorPanel - the root's controls for a SIMULATION event (merger Stage 3, migration 022).
//
// Set up N virtual groups (each 1-3 virtual ICs that walk from 200-600 m away to one of the event's zones),
// choose how they behave, then Start / Pause / Reset. The server moves them every 10 s and their readings go
// through the same path as a real phone, so the live map, zone presence and No-Go alerts all react to them.
// Virtual ICs are fake accounts that cannot sign in; Reset deletes them and everything they sent.
//
// Rehearsal (merger Stage 7): "Plan their movements" gives every virtual group a movement to the zone it walks to in a
// Draft run sheet version, due at a cue. While a show runs that version, groups with a movement follow the plan
// instead: they wait, leave a minute before their leave-by time ("2 min late" a minute after it) and walk at the
// movement's pace, one movement after another.
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { askConfirm, toast } from '../composables/useNotify'

const props = defineProps({
  eventId: { type: String, required: true },
})
const emit = defineEmits(['changed']) // groups / members changed: the event page reloads them

const scripts = ref([]) // presets: { key, label, description }
const run = ref(null) // { status, ticks, readings, started_at }
const groupCount = ref(0)
const icCount = ref(0)
const byScript = ref({}) // script -> number of groups
const busy = ref(false)

const groups = ref(20)
const icsMin = ref(2)
const icsMax = ref(3)
const mix = ref({ on_time: 80, late_2min: 10, stops_halfway: 0, loses_signal: 5, wrong_zone: 5 })
const mixTotal = computed(() => Object.values(mix.value).reduce((a, b) => a + (Number(b) || 0), 0))

const status = computed(() => (run.value ? run.value.status : groupCount.value ? 'ready' : 'empty'))
const statusText = computed(
  () =>
    ({
      empty: 'No virtual groups yet',
      ready: 'Ready to start',
      running: 'Running: moving every 10 s',
      paused: 'Paused',
    })[status.value],
)

let timer = null
let channel = null

async function load() {
  const [s, r, g, ics] = await Promise.all([
    supabase.from('sim_scripts').select('key, label, description').order('sort'),
    supabase.from('sim_runs').select('status, ticks, readings, started_at').eq('event_id', props.eventId).maybeSingle(),
    supabase.from('sim_groups').select('script').eq('event_id', props.eventId),
    supabase
      .from('group_members')
      .select('user_id, profiles!inner (is_simulated)', { count: 'exact', head: true })
      .eq('event_id', props.eventId)
      .eq('profiles.is_simulated', true),
  ])
  if (!s.error) scripts.value = s.data || []
  if (!r.error) run.value = r.data
  if (!g.error) {
    groupCount.value = (g.data || []).length
    const counts = {}
    for (const row of g.data || []) counts[row.script] = (counts[row.script] || 0) + 1
    byScript.value = counts
  }
  if (!ics.error) icCount.value = ics.count || 0
}

// ---------- Plan their movements (Stage 7) ----------
const drafts = ref([]) // Draft versions of this event
const planSheet = ref('')
const planCues = ref([])
const planCue = ref('')
async function loadDrafts() {
  const { data } = await supabase.from('run_sheets').select('id, name, status').eq('event_id', props.eventId).eq('status', 'draft').order('created_at')
  drafts.value = data || []
  if (!drafts.value.some((d) => d.id === planSheet.value)) planSheet.value = drafts.value.length ? drafts.value[0].id : ''
}
watch(planSheet, async (id) => {
  planCues.value = []
  planCue.value = ''
  if (!id) return
  const { data } = await supabase.from('cues').select('id, code, title, start_time').eq('run_sheet_id', id).order('position')
  planCues.value = data || []
  if (planCues.value.length) planCue.value = planCues.value[0].id
})
async function planMovements() {
  const sheet = drafts.value.find((d) => d.id === planSheet.value)
  const cue = planCues.value.find((c) => c.id === planCue.value)
  if (!sheet || !cue) return
  await call('sim_plan_movements', { p_sheet: sheet.id, p_cue: cue.id }, (n) =>
    n + ' movements added to "' + sheet.name + '" (due at ' + cue.code + '). Mark it Ready, then start the event with it.')
}

async function call(fn, args, done) {
  busy.value = true
  const { data, error } = await supabase.rpc(fn, { p_event: props.eventId, ...args })
  busy.value = false
  if (error) {
    toast(error.message, 'danger', 8000)
    return null
  }
  if (done) toast(typeof done === 'function' ? done(data) : done, 'success')
  await load()
  emit('changed')
  return data
}

async function setUp() {
  if (mixTotal.value <= 0) return toast('Give at least one behaviour a share above 0 %.', 'warning')
  await call(
    'sim_setup',
    { p_groups: Number(groups.value), p_ics_min: Number(icsMin.value), p_ics_max: Number(icsMax.value), p_mix: mix.value },
    (n) => n + ' virtual groups added.',
  )
}

const start = () => call('sim_start', {}, 'Simulation running. The event is live.')
const pause = () => call('sim_pause', {}, 'Simulation paused.')

async function reset() {
  const ok = await askConfirm({
    title: 'Reset the simulation?',
    message:
      'Deletes all ' + groupCount.value + ' virtual groups, their ' + icCount.value +
      ' virtual ICs and everything they sent. Real people and zones stay.',
    confirmText: 'Reset',
    danger: true,
  })
  if (ok) await call('sim_reset', {}, (n) => 'Simulation reset: ' + n + ' virtual ICs removed.')
}

onMounted(() => {
  load()
  loadDrafts()
  // The counters move every tick; Realtime tells us when the run row changes, a slow poll covers the rest.
  channel = supabase
    .channel('sim-run-' + props.eventId + '-' + Math.random().toString(36).slice(2))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'sim_runs', filter: 'event_id=eq.' + props.eventId }, (p) => {
      if (p.new && p.new.status) run.value = p.new
      else run.value = null
    })
    .subscribe()
  timer = setInterval(load, 30000)
})

onUnmounted(() => {
  clearInterval(timer)
  if (channel) supabase.removeChannel(channel)
})
</script>

<template>
  <div class="d-grid gap-3" data-testid="simulator-panel">
    <div class="card">
      <div class="card-body d-flex flex-wrap align-items-center gap-3">
        <span
          class="badge"
          :class="{ 'text-bg-success': status === 'running', 'text-bg-warning': status === 'paused', 'text-bg-secondary': status === 'ready' || status === 'empty' }"
          data-testid="sim-status"
        >{{ statusText }}</span>
        <span class="small text-muted sim-nums">
          {{ groupCount }} groups · {{ icCount }} virtual ICs
          <template v-if="run"> · {{ run.ticks }} ticks · {{ run.readings }} readings</template>
        </span>
        <div class="ms-auto d-flex flex-wrap gap-2">
          <button v-if="status !== 'running'" class="btn btn-success btn-sm" :disabled="busy || !groupCount" data-testid="sim-start" @click="start">
            Start
          </button>
          <button v-else class="btn btn-warning btn-sm" :disabled="busy" data-testid="sim-pause" @click="pause">Pause</button>
          <button class="btn btn-outline-danger btn-sm" :disabled="busy || !groupCount" data-testid="sim-reset" @click="reset">Reset</button>
        </div>
      </div>
      <div v-if="groupCount" class="card-body pt-0 small text-muted">
        <span v-for="s in scripts" :key="s.key" class="me-3">{{ s.label }}: <strong>{{ byScript[s.key] || 0 }}</strong></span>
      </div>
    </div>

    <form class="card" @submit.prevent="setUp">
      <div class="card-body d-grid gap-3">
        <div>
          <h2 class="h6 mb-1">Add virtual groups</h2>
          <p class="small text-muted mb-0">
            Each group walks from a random spot 200–600 m away to one of this event's zones (Zones tab) at 1.0–1.5 m/s.
            Its virtual ICs send a reading every 10 s with 5–15 m of GPS noise. Virtual ICs are fake accounts that cannot sign in;
            Reset removes them.
          </p>
        </div>
        <div class="d-flex flex-wrap gap-3">
          <label class="form-label mb-0 small">Groups
            <input id="sim-groups" v-model.number="groups" type="number" min="1" max="150" class="form-control form-control-sm sim-num" required />
          </label>
          <label class="form-label mb-0 small">ICs per group, from
            <input id="sim-ics-min" v-model.number="icsMin" type="number" min="1" max="3" class="form-control form-control-sm sim-num" />
          </label>
          <label class="form-label mb-0 small">to
            <input id="sim-ics-max" v-model.number="icsMax" type="number" min="1" max="3" class="form-control form-control-sm sim-num" />
          </label>
        </div>
        <div>
          <div class="small fw-semibold mb-1">Behaviour mix (%) <span class="text-muted fw-normal">· total {{ mixTotal }} %</span></div>
          <div class="d-grid gap-2">
            <label v-for="s in scripts" :key="s.key" class="d-flex flex-wrap align-items-center gap-2 small">
              <input :id="'sim-mix-' + s.key" v-model.number="mix[s.key]" type="number" min="0" max="100" class="form-control form-control-sm sim-num" />
              <strong>{{ s.label }}</strong>
              <span class="text-muted">{{ s.description }}</span>
            </label>
          </div>
          <div class="form-text">"Wrong zone" needs a No-Go zone in the Zones tab; without one those groups walk to a normal zone.</div>
        </div>
        <div>
          <button class="btn btn-primary btn-sm" type="submit" :disabled="busy || status === 'running'" data-testid="sim-setup">
            Add {{ groups }} groups
          </button>
          <span v-if="status === 'running'" class="small text-muted ms-2">Pause to add more.</span>
        </div>
      </div>
    </form>

    <form class="card" data-testid="sim-plan" @submit.prevent="planMovements">
      <div class="card-body d-grid gap-2">
        <div>
          <h2 class="h6 mb-1">Plan their movements (rehearsal)</h2>
          <p class="small text-muted mb-0">
            Gives every virtual group without one a movement to the zone it walks to, in a Draft version, due at a cue's start.
            While a show runs that version, groups with a movement wait, leave a minute before their leave-by time
            ("2 min late": a minute after it) and walk at the movement's pace, one movement after another.
          </p>
        </div>
        <p v-if="!drafts.length" class="small text-muted mb-0">Make a Draft version with at least one cue in the Run sheet tab first.</p>
        <div v-else class="d-flex flex-wrap align-items-end gap-2">
          <label class="form-label mb-0 small">Version
            <select v-model="planSheet" class="form-select form-select-sm" data-testid="sim-plan-sheet" @focus="loadDrafts">
              <option v-for="d in drafts" :key="d.id" :value="d.id">{{ d.name }}</option>
            </select>
          </label>
          <label class="form-label mb-0 small">Due at the start of
            <select v-model="planCue" class="form-select form-select-sm" data-testid="sim-plan-cue">
              <option v-for="c in planCues" :key="c.id" :value="c.id">{{ c.code }} {{ c.title }} ({{ c.start_time }})</option>
            </select>
          </label>
          <button class="btn btn-outline-primary btn-sm" type="submit" :disabled="busy || !groupCount || !planCue" data-testid="sim-plan-btn">
            Add movements
          </button>
        </div>
      </div>
    </form>
  </div>
</template>

<style scoped>
.sim-num {
  width: 5.5rem;
  display: inline-block;
}
.sim-nums {
  font-variant-numeric: tabular-nums;
}
</style>
