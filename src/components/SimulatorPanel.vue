<script setup>
// SimulatorPanel - the root's controls for a SIMULATION event (merger Stage 3, migration 022).
//
// Set up N virtual groups (each 1-3 virtual ICs), choose how they behave, then Start / Pause / Reset. The server moves
// them every 10 s and their readings go through the same path as a real phone, so the live map, zone presence and
// No-Go alerts all react to them. Virtual ICs are fake accounts that cannot sign in; Reset deletes them and everything
// they sent.
//
// Since 060 they walk the PLAN: each group's next leg is to its own next on-site moment in the published plan, timed
// to arrive a minute early ("2 min late": two minutes later; "stops halfway" and "loses signal" keep their meanings).
// That is why Start needs a published plan, and why the old "Plan their movements" card is gone -- a strip already
// says where each group stands and when, so there is nothing to generate.
import { ref, computed, onMounted, onUnmounted } from 'vue'
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
const livePlan = ref(null) // the published plan the groups walk to (060); null = none yet
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
  const [s, r, g, ics, p] = await Promise.all([
    supabase.from('sim_scripts').select('key, label, description').order('sort'),
    supabase.from('sim_runs').select('status, ticks, readings, started_at').eq('event_id', props.eventId).maybeSingle(),
    supabase.from('sim_groups').select('script').eq('event_id', props.eventId),
    supabase
      .from('group_members')
      .select('user_id, profiles!inner (is_simulated)', { count: 'exact', head: true })
      .eq('event_id', props.eventId)
      .eq('profiles.is_simulated', true),
    supabase.from('plans').select('id, name').eq('event_id', props.eventId).eq('status', 'live').order('updated_at', { ascending: false }).limit(1),
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
  if (!p.error) livePlan.value = (p.data || [])[0] || null
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
  <div class="d-grid gap-3" data-testid="simulator-panel" :aria-busy="busy ? 'true' : null">
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
        <span v-if="livePlan" class="small text-muted" data-testid="sim-plan-name"> · walking the plan "{{ livePlan.name }}"</span>
        <span v-else class="small text-danger" data-testid="sim-plan-missing"> · publish a plan first</span>
        <div class="ms-auto d-flex flex-wrap gap-2">
          <button v-if="status !== 'running'" class="btn btn-success btn-sm" :disabled="busy || !groupCount || !livePlan" data-testid="sim-start" @click="start">
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
            Each group starts at a random spot 200–600 m from one of this event's zones (Zones tab) and then walks to its
            own moments in the published plan, leaving late enough to arrive a minute early. Its virtual ICs send a
            reading every 10 s with 5–15 m of GPS noise. Virtual ICs are fake accounts that cannot sign in; Reset
            removes them.
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
