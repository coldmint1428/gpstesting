<script setup>
// MovementEditor - add or edit one movement of a run sheet (merger Stage 4):
//   WHO     one group, or every group of a category (with per-group exceptions: skip, or another zone)
//   WHERE   a zone (never a No-Go zone)
//   BY WHEN a cue's start or end, or a fixed time; optionally some minutes early
//   ARRIVED at least N ICs inside for N seconds; amber when the spare time is under N seconds
//   HOW     on foot (pace), vehicle or fixed route (planned only: the live check treats them like on foot for now)
//   PLANNED must have left by, the door they enter by, the fixed route's name (from the Excel template; used later)
// The database checks it all again (save_movement in 024_run_sheets.sql).
import { ref, computed, watch } from 'vue'
import { askConfirm, toast } from '../composables/useNotify'
import { rsCall, formatLength, parseLength } from '../composables/useRunSheets'

const props = defineProps({
  sheetId: { type: String, required: true },
  movement: { type: Object, default: null }, // null = new
  exceptions: { type: Array, default: () => [] },
  cues: { type: Array, default: () => [] },
  zones: { type: Array, default: () => [] },
  groups: { type: Array, default: () => [] },
  readOnly: { type: Boolean, default: false },
})
const emit = defineEmits(['saved', 'close', 'changed'])

function blank() {
  const first = props.cues[0]
  return {
    id: null,
    rev: null,
    code: '',
    who: 'group', // group | category
    group_id: '',
    category: '',
    zone_id: '',
    deadline_kind: 'cue_start',
    cue_id: first ? first.id : '',
    fixed_time: '',
    fixed_day_offset: false,
    early: '0:00',
    min_ics: '',
    dwell: '0:20',
    amber: '0:30',
    travel_mode: 'on_foot',
    pace_mps: '1.2',
    notes: '',
    leave_by: '',
    arrival_point: '',
    route: '',
  }
}
function fromMovement(m) {
  return {
    id: m.id,
    rev: m.rev,
    code: m.code,
    who: m.category ? 'category' : 'group',
    group_id: m.group_id || '',
    category: m.category || '',
    zone_id: m.zone_id || '',
    deadline_kind: m.deadline_kind,
    cue_id: m.cue_id || '',
    fixed_time: m.fixed_time || '',
    fixed_day_offset: m.fixed_day_offset === 1,
    early: formatLength(m.early_s),
    min_ics: m.min_ics == null ? '' : String(m.min_ics),
    dwell: formatLength(m.dwell_s),
    amber: formatLength(m.amber_s),
    travel_mode: m.travel_mode,
    pace_mps: String(m.pace_mps),
    notes: m.notes || '',
    leave_by: m.leave_by || '',
    arrival_point: m.arrival_point || '',
    route: m.route || '',
  }
}
const form = ref(props.movement ? fromMovement(props.movement) : blank())
// Someone else saved it (realtime reload): show their version unless we are mid-save
watch(
  () => props.movement && props.movement.rev,
  () => {
    if (props.movement && !saving.value) form.value = fromMovement(props.movement)
  },
)
const error = ref('')
const saving = ref(false)

const sortedGroups = computed(() => [...props.groups].sort((a, b) => a.name.localeCompare(b.name)))
const categories = computed(() => [...new Set(props.groups.map((g) => g.category).filter(Boolean))].sort())
const placeZones = computed(() => props.zones.filter((z) => z.kind !== 'no_go'))
const inCategory = computed(() =>
  form.value.who === 'category' && form.value.category
    ? sortedGroups.value.filter((g) => (g.category || '').toLowerCase() === form.value.category.trim().toLowerCase())
    : [],
)

// One sentence saying what this movement means
const summary = computed(() => {
  const f = form.value
  const g = props.groups.find((x) => x.id === f.group_id)
  const who = f.who === 'category' ? (f.category ? 'Every group in "' + f.category + '"' : 'A category') : g ? g.name : 'A group'
  const z = props.zones.find((x) => x.id === f.zone_id)
  const where = z ? z.code + (z.name ? ' (' + z.name + ')' : '') : 'a zone'
  const early = parseLength(f.early) || 0
  let when
  if (f.deadline_kind === 'fixed') when = (f.fixed_time || '…') + (f.fixed_day_offset ? ' the next day' : '')
  else {
    const c = props.cues.find((x) => x.id === f.cue_id)
    when = '"' + (c ? c.title : '…') + '" ' + (f.deadline_kind === 'cue_end' ? 'ends' : 'starts')
  }
  const lead = early ? formatLength(early) + ' before ' : f.deadline_kind === 'fixed' ? 'by ' : 'by the time '
  return who + ' must be in ' + where + ' ' + lead + when + '.'
})

function payload() {
  const f = form.value
  return {
    id: f.id,
    rev: f.rev,
    code: f.code,
    group_id: f.who === 'group' ? f.group_id : null,
    // the spelling the groups use ("contingent" -> "Contingent"); a new category stays as typed
    category: f.who === 'category' ? categories.value.find((c) => c.toLowerCase() === f.category.trim().toLowerCase()) || f.category : null,
    zone_id: f.zone_id || null,
    deadline_kind: f.deadline_kind,
    cue_id: f.deadline_kind === 'fixed' ? null : f.cue_id || null,
    fixed_time: f.deadline_kind === 'fixed' ? (f.fixed_time.length === 5 ? f.fixed_time + ':00' : f.fixed_time) || null : null,
    fixed_day_offset: f.deadline_kind === 'fixed' && f.fixed_day_offset ? 1 : 0,
    early_s: parseLength(f.early),
    min_ics: f.min_ics === '' ? null : f.min_ics,
    dwell_s: parseLength(f.dwell),
    amber_s: parseLength(f.amber),
    travel_mode: f.travel_mode,
    pace_mps: f.pace_mps,
    notes: f.notes,
    leave_by: f.leave_by,
    arrival_point: f.arrival_point,
    route: f.route,
  }
}

async function save() {
  const f = form.value
  error.value = ''
  if (f.who === 'group' && !f.group_id) return (error.value = 'Pick the group that moves.')
  if (f.who === 'category' && !f.category.trim()) return (error.value = 'Pick the category that moves.')
  for (const [label, v] of [['Arrive early by', f.early], ['Inside for', f.dwell], ['Amber when spare under', f.amber]]) {
    if (parseLength(v) === null) return (error.value = label + ': write it as m:ss, like 2:00.')
  }
  if (f.deadline_kind === 'fixed' && !f.fixed_time) return (error.value = 'Give the fixed time.')
  if (f.deadline_kind !== 'fixed' && !f.cue_id) return (error.value = 'Pick the cue it is timed to.')
  saving.value = true
  const r = await rsCall('save_movement', { p_sheet: props.sheetId, p_move: payload() })
  saving.value = false
  if (r.error) {
    error.value = r.error
    if (r.stale) emit('changed')
    return
  }
  toast(f.id ? 'Movement saved.' : 'Movement added.', 'success')
  emit('saved', r.data)
}

async function remove() {
  const f = form.value
  const ok = await askConfirm({
    title: 'Delete movement ' + f.code + '?',
    message: props.exceptions.length ? 'Its ' + props.exceptions.length + ' exception(s) are deleted too.' : '',
    confirmText: 'Delete movement',
    danger: true,
  })
  if (!ok) return
  const r = await rsCall('delete_movement', { p_move: f.id })
  if (r.error) return (error.value = r.error)
  toast('Movement deleted.', 'success')
  emit('saved', null)
}

// ---------- Exceptions (only for a saved category movement) ----------
const exForm = ref(null) // { group_id, skip, zone_id }
const exError = ref('')
const freeGroups = computed(() => inCategory.value.filter((g) => !props.exceptions.some((x) => x.group_id === g.id)))
function groupName(id) {
  const g = props.groups.find((x) => x.id === id)
  return g ? g.name : 'A deleted group'
}
function zoneCode(id) {
  const z = props.zones.find((x) => x.id === id)
  return z ? z.code : 'no zone'
}
async function addException() {
  const x = exForm.value
  exError.value = ''
  if (!x.group_id) return (exError.value = 'Pick the group.')
  if (!x.skip && !x.zone_id) return (exError.value = 'Pick the other zone, or tick "Skip".')
  const m = props.movement
  const r = await rsCall('save_movement', {
    p_sheet: props.sheetId,
    p_move: {
      parent_id: m.id,
      group_id: x.group_id,
      skip: x.skip,
      zone_id: x.skip ? null : x.zone_id,
      deadline_kind: m.deadline_kind,
      cue_id: m.cue_id,
      fixed_time: m.fixed_time,
      fixed_day_offset: m.fixed_day_offset,
      early_s: m.early_s,
      min_ics: m.min_ics,
      dwell_s: m.dwell_s,
      amber_s: m.amber_s,
      travel_mode: m.travel_mode,
      pace_mps: m.pace_mps,
      leave_by: m.leave_by,
      arrival_point: m.arrival_point,
      route: m.route,
    },
  })
  if (r.error) return (exError.value = r.error)
  exForm.value = null
  emit('changed')
}
async function removeException(x) {
  const r = await rsCall('delete_movement', { p_move: x.id })
  if (r.error) return toast(r.error, 'danger', 8000)
  emit('changed')
}
</script>

<template>
  <form class="card border-primary" data-testid="move-form" @submit.prevent="save">
    <div class="card-body d-grid gap-3">
      <div class="d-flex align-items-center">
        <h3 class="h6 mb-0 flex-grow-1">{{ readOnly ? 'Movement ' + form.code : form.id ? 'Edit movement ' + form.code : 'New movement' }}</h3>
        <button type="button" class="btn-close" aria-label="Close" @click="emit('close')"></button>
      </div>

      <p class="mb-0 small bg-light border rounded p-2" data-testid="move-summary">{{ summary }}</p>

      <fieldset :disabled="readOnly" class="d-grid gap-3">
        <!-- WHO -->
        <div>
          <div class="small fw-semibold mb-1">Who moves</div>
          <div class="btn-group btn-group-sm mb-2" role="group" aria-label="Who moves">
            <input id="mv-who-g" v-model="form.who" class="btn-check" type="radio" value="group" :disabled="!!form.id && !!movement && !!movement.category" />
            <label class="btn btn-outline-primary" for="mv-who-g">One group</label>
            <input id="mv-who-c" v-model="form.who" class="btn-check" type="radio" value="category" :disabled="!!form.id && !!movement && !movement.category && exceptions.length > 0" />
            <label class="btn btn-outline-primary" for="mv-who-c">A whole category</label>
          </div>
          <select v-if="form.who === 'group'" v-model="form.group_id" class="form-select" data-testid="move-group">
            <option value="" disabled>Pick a group…</option>
            <option v-for="g in sortedGroups" :key="g.id" :value="g.id">{{ g.name }}{{ g.category ? ' · ' + g.category : '' }}</option>
          </select>
          <template v-else>
            <input v-model="form.category" class="form-control" list="mv-categories" maxlength="50" placeholder="e.g. Contingent" data-testid="move-category" />
            <datalist id="mv-categories"><option v-for="c in categories" :key="c" :value="c" /></datalist>
            <div class="form-text" data-testid="move-category-count">
              <template v-if="!categories.length">No group has a category yet: set it in the Members tab (group details).</template>
              <template v-else-if="form.category">{{ inCategory.length }} group{{ inCategory.length === 1 ? '' : 's' }} in this category now.</template>
            </div>
          </template>
        </div>

        <!-- WHERE -->
        <div>
          <label class="small fw-semibold mb-1" for="mv-zone">Where to</label>
          <select id="mv-zone" v-model="form.zone_id" class="form-select" data-testid="move-zone">
            <option value="">Not decided yet</option>
            <option v-for="z in placeZones" :key="z.id" :value="z.id">{{ z.code }}{{ z.name ? ' · ' + z.name : '' }}</option>
          </select>
          <div v-if="!placeZones.length" class="form-text">No zones yet: draw them in the Zones tab. (No-Go zones are never a destination.)</div>
        </div>

        <!-- BY WHEN -->
        <div class="row g-2">
          <div class="col-12 small fw-semibold">By when</div>
          <div class="col-sm-5">
            <select v-model="form.deadline_kind" class="form-select" aria-label="Deadline" data-testid="move-kind">
              <option value="cue_start">When a cue starts</option>
              <option value="cue_end">When a cue ends</option>
              <option value="fixed">At a fixed time</option>
            </select>
          </div>
          <div v-if="form.deadline_kind !== 'fixed'" class="col-sm-7">
            <select v-model="form.cue_id" class="form-select" aria-label="Cue" data-testid="move-cue">
              <option value="" disabled>Pick a cue…</option>
              <option v-for="c in cues" :key="c.id" :value="c.id">{{ c.start_time.slice(0, 8) }}{{ c.day_offset ? ' (+1)' : '' }} · {{ c.code }} {{ c.title }}</option>
            </select>
          </div>
          <div v-else class="col-sm-7 d-flex gap-2 align-items-center">
            <input v-model="form.fixed_time" type="time" step="1" class="form-control" aria-label="Fixed time" data-testid="move-fixed" />
            <div class="form-check text-nowrap">
              <input id="mv-next" v-model="form.fixed_day_offset" class="form-check-input" type="checkbox" />
              <label class="form-check-label small" for="mv-next">+1 day</label>
            </div>
          </div>
          <div class="col-6 col-sm-4">
            <label class="form-label small mb-1" for="mv-early">Arrive early by (m:ss)</label>
            <input id="mv-early" v-model="form.early" class="form-control" data-testid="move-early" />
          </div>
        </div>

        <!-- ARRIVED -->
        <div class="row g-2">
          <div class="col-12 small fw-semibold">Counts as arrived when</div>
          <div class="col-4">
            <label class="form-label small mb-1" for="mv-min">At least … ICs</label>
            <input id="mv-min" v-model="form.min_ics" class="form-control" inputmode="numeric" placeholder="all" data-testid="move-min" />
          </div>
          <div class="col-4">
            <label class="form-label small mb-1" for="mv-dwell">inside for (m:ss)</label>
            <input id="mv-dwell" v-model="form.dwell" class="form-control" data-testid="move-dwell" />
          </div>
          <div class="col-4">
            <label class="form-label small mb-1" for="mv-amber">Amber when spare &lt; (m:ss)</label>
            <input id="mv-amber" v-model="form.amber" class="form-control" data-testid="move-amber" />
          </div>
        </div>

        <!-- HOW -->
        <div class="row g-2">
          <div class="col-12 small fw-semibold">How they travel</div>
          <div class="col-7">
            <select v-model="form.travel_mode" class="form-select" aria-label="Travel mode" data-testid="move-mode">
              <option value="on_foot">On foot</option>
              <option value="vehicle">Vehicle (planned only)</option>
              <option value="fixed_route">Fixed route (planned only)</option>
            </select>
          </div>
          <div class="col-5">
            <div class="input-group">
              <input v-model="form.pace_mps" class="form-control" inputmode="decimal" aria-label="Pace" data-testid="move-pace" />
              <span class="input-group-text">m/s</span>
            </div>
          </div>
          <div v-if="form.travel_mode !== 'on_foot'" class="col-12 form-text">
            Saved with the plan. The live arrival estimate uses the pace for now; road and route timing come in a later stage.
          </div>
        </div>

        <!-- Planned only (from the Excel template; used from Stages 7 and 9) -->
        <details class="small" :open="!!(form.leave_by || form.arrival_point || form.route)">
          <summary class="fw-semibold">Planned details <span class="fw-normal text-muted">· kept with the plan, not used live yet</span></summary>
          <div class="row g-2 mt-1">
            <div class="col-sm-4">
              <label class="form-label small mb-1" for="mv-leave">Must leave by</label>
              <input id="mv-leave" v-model="form.leave_by" class="form-control form-control-sm" maxlength="30" placeholder="C034 end or 18:20:00" data-testid="move-leave" />
            </div>
            <div class="col-sm-4">
              <label class="form-label small mb-1" for="mv-arrival">Arrival point (door)</label>
              <input id="mv-arrival" v-model="form.arrival_point" class="form-control form-control-sm" maxlength="40" list="mv-zone-codes" placeholder="Zone code, e.g. D4" data-testid="move-arrival" />
              <datalist id="mv-zone-codes"><option v-for="z in zones" :key="z.id" :value="z.code" /></datalist>
            </div>
            <div class="col-sm-4">
              <label class="form-label small mb-1" for="mv-route">Route</label>
              <input id="mv-route" v-model="form.route" class="form-control form-control-sm" maxlength="60" placeholder="MC_ROUTE" data-testid="move-route" />
            </div>
          </div>
        </details>

        <div class="row g-2">
          <div class="col-4">
            <label class="form-label small mb-1" for="mv-code">Code</label>
            <input id="mv-code" v-model="form.code" class="form-control" maxlength="20" placeholder="auto" />
          </div>
          <div class="col-8">
            <label class="form-label small mb-1" for="mv-notes">Notes</label>
            <input id="mv-notes" v-model="form.notes" class="form-control" maxlength="500" />
          </div>
        </div>
      </fieldset>

      <div v-if="error" class="small text-danger" role="alert" data-testid="move-error">{{ error }}</div>
      <div v-if="!readOnly" class="d-flex gap-2">
        <button class="btn btn-primary btn-sm" type="submit" :disabled="saving" data-testid="move-save">{{ form.id ? 'Save movement' : 'Add movement' }}</button>
        <button class="btn btn-outline-secondary btn-sm" type="button" @click="emit('close')">Cancel</button>
        <button v-if="form.id" class="btn btn-outline-danger btn-sm ms-auto" type="button" data-testid="move-delete" @click="remove">Delete</button>
      </div>

      <!-- Exceptions to a category movement -->
      <div v-if="movement && movement.category" class="border-top pt-3" data-testid="move-exceptions">
        <div class="small fw-semibold mb-1">Exceptions <span class="fw-normal text-muted">· groups of "{{ movement.category }}" that skip this or go elsewhere</span></div>
        <ul v-if="exceptions.length" class="list-unstyled small mb-2">
          <li v-for="x in exceptions" :key="x.id" class="d-flex align-items-center gap-2 py-1">
            <span class="flex-grow-1">{{ groupName(x.group_id) }}: {{ x.skip ? 'skips this movement' : 'goes to ' + zoneCode(x.zone_id) }}</span>
            <button v-if="!readOnly" type="button" class="btn btn-sm btn-outline-danger py-0" @click="removeException(x)">Remove</button>
          </li>
        </ul>
        <p v-else class="small text-muted mb-2">None: every group in the category does this movement.</p>
        <template v-if="!readOnly">
          <button v-if="!exForm" type="button" class="btn btn-sm btn-outline-secondary" :disabled="!freeGroups.length" data-testid="move-add-exception" @click="exForm = { group_id: '', skip: false, zone_id: '' }">
            Add exception
          </button>
          <div v-else class="d-grid gap-2 bg-light border rounded p-2">
            <select v-model="exForm.group_id" class="form-select form-select-sm" aria-label="Group" data-testid="ex-group">
              <option value="" disabled>Pick a group…</option>
              <option v-for="g in freeGroups" :key="g.id" :value="g.id">{{ g.name }}</option>
            </select>
            <div class="form-check">
              <input id="ex-skip" v-model="exForm.skip" class="form-check-input" type="checkbox" data-testid="ex-skip" />
              <label class="form-check-label small" for="ex-skip">Skip this movement</label>
            </div>
            <select v-if="!exForm.skip" v-model="exForm.zone_id" class="form-select form-select-sm" aria-label="Other zone" data-testid="ex-zone">
              <option value="" disabled>Goes to another zone…</option>
              <option v-for="z in placeZones" :key="z.id" :value="z.id">{{ z.code }}{{ z.name ? ' · ' + z.name : '' }}</option>
            </select>
            <div v-if="exError" class="small text-danger" role="alert">{{ exError }}</div>
            <div class="d-flex gap-2">
              <button type="button" class="btn btn-sm btn-primary" data-testid="ex-save" @click="addException">Add</button>
              <button type="button" class="btn btn-sm btn-outline-secondary" @click="exForm = null">Cancel</button>
            </div>
          </div>
        </template>
      </div>
      <p v-else-if="form.who === 'category' && !form.id" class="small text-muted mb-0">Save it first, then you can add exceptions (groups that skip it or go elsewhere).</p>
    </div>
  </form>
</template>
