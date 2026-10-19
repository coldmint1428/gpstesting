<script setup>
// RunSheetPanel - the event's "Run sheet" tab (merger Stage 4).
//
// Versions ("Rehearsal 2 · Sat 19 Jul · Ready"): pick one, New / Duplicate / Rename / Delete, Check & mark
// ready. A version is Draft (being edited), Ready (passed the check) or Used (ran in a session: read-only,
// duplicate it to change it). Below: the problems the check finds (always shown), the cues by section with
// an inline editor, and the movements (who must be where by when) with their editor.
//
// Root and planners edit; marshals only read. The database checks all of it again (024_run_sheets.sql).
import { ref, computed, watch, nextTick } from 'vue'
import { supabase } from '../lib/supabase'
import { askConfirm, toast } from '../composables/useNotify'
import { formatDayTime } from '../utils/time'
import {
  useRunSheet,
  rsCall,
  dayLabel,
  formatLength,
  parseLength,
  addSeconds,
  nextName,
  isoDate,
  loadExcel,
} from '../composables/useRunSheets'
import MovementEditor from './MovementEditor.vue'
import RunSheetImport from './RunSheetImport.vue'
import { buildWorkbook, TEMPLATE_EXAMPLE } from '../utils/runSheetFile'
import { saveFile, XLSX_TYPE } from '../lib/saveFile'

const props = defineProps({
  eventId: { type: String, required: true },
  canEdit: { type: Boolean, default: false }, // root / planner
  list: { type: Object, required: true }, // useRunSheetList(eventId), shared with the event status card
  groups: { type: Array, default: () => [] },
  liveSession: { type: Object, default: null }, // { id, runSheetId } while live
  eventName: { type: String, default: '' },
  members: { type: Array, default: () => [] }, // for the IC usernames in an export
  plannedDay: { type: String, default: '' }, // YYYY-MM-DD: the event's planned day (Create-an-event wizard), if any
})
// An import can create groups and change their details: the event page reloads them
const emit = defineEmits(['changed'])

const sheets = computed(() => props.list.sheets.value)

// ---------- Which version is open (remembered per event on this device) ----------
const KEY = 'run-sheet-open-' + props.eventId
const selectedId = ref(readSaved())
function readSaved() {
  try {
    return localStorage.getItem(KEY) || ''
  } catch {
    return ''
  }
}
watch(selectedId, (id) => {
  try {
    if (id) localStorage.setItem(KEY, id)
  } catch {
    // storage blocked: just not remembered
  }
})
// Keep the choice valid: the live version first, then what was open, then the suggested / first one
watch(
  sheets,
  (list) => {
    if (!list.length) return (selectedId.value = '')
    if (list.some((s) => s.id === selectedId.value)) return
    const live = list.find((s) => s.live)
    selectedId.value = (live || props.list.suggested.value || list[0]).id
  },
  { immediate: true },
)
const sheet = computed(() => sheets.value.find((s) => s.id === selectedId.value) || null)

const { cues, movements, problems, problemsFor, errorCount, warningCount, errorMsg, load } = useRunSheet(selectedId)

const readOnly = computed(() => !props.canEdit || !sheet.value || sheet.value.status === 'used')

function versionLabel(s) {
  const icon = s.status === 'used' ? '🔒' : s.status === 'ready' ? '✅' : '✏️'
  const status = s.status === 'used' ? 'Used' : s.status === 'ready' ? 'Ready' : 'Draft'
  return icon + ' ' + s.name + (s.forDate ? ' · ' + dayLabel(s.forDate) : '') + ' · ' + status + (s.live ? ' · running now' : '')
}

// ---------- Zones (for the movement editor and labels) ----------
const zones = ref([])
async function loadZones() {
  const { data } = await supabase
    .from('zones')
    .select('id, code, name, kind, capacity, is_circle, radius_m')
    .eq('event_id', props.eventId)
    .order('code')
  zones.value = data || []
}
loadZones()
const zoneById = computed(() => Object.fromEntries(zones.value.map((z) => [z.id, z])))
const groupById = computed(() => Object.fromEntries(props.groups.map((g) => [g.id, g])))
const cueById = computed(() => Object.fromEntries(cues.value.map((c) => [c.id, c])))

// ---------- Version form: new / duplicate / rename ----------
const versionForm = ref(null) // { mode: 'new'|'rename', name, forDate, copyFrom }
const versionError = ref('')
const busy = ref(false)

function openNew(copy) {
  const base = copy && sheet.value ? sheet.value.name : sheets.value.length ? sheets.value[0].name : 'Rehearsal 0'
  versionForm.value = {
    mode: 'new',
    name: sheets.value.length || copy ? nextName(base, sheets.value.map((s) => s.name)) : 'Rehearsal 1',
    forDate: props.plannedDay || '',
    copyFrom: copy && sheet.value ? sheet.value.id : '',
  }
  versionError.value = ''
}
function openRename() {
  versionForm.value = { mode: 'rename', name: sheet.value.name, forDate: sheet.value.forDate || '', copyFrom: '' }
  versionError.value = ''
}
async function saveVersion() {
  const f = versionForm.value
  versionError.value = ''
  if (!f.name.trim()) return (versionError.value = 'Give the version a name.')
  busy.value = true
  const r =
    f.mode === 'new'
      ? await rsCall('create_run_sheet', { p_event: props.eventId, p_name: f.name, p_for_date: f.forDate || null, p_copy_from: f.copyFrom || null })
      : await rsCall('update_run_sheet', { p_sheet: sheet.value.id, p_name: f.name, p_for_date: f.forDate || null })
  busy.value = false
  if (r.error) return (versionError.value = r.error)
  versionForm.value = null
  await props.list.load()
  if (f.mode === 'new') selectedId.value = r.data
  toast(f.mode === 'new' ? 'Version "' + f.name.trim() + '" created.' : 'Version renamed.', 'success')
}

async function deleteVersion() {
  const s = sheet.value
  const ok = await askConfirm({
    title: 'Delete "' + s.name + '"?',
    message: 'Its ' + s.cueCount + ' cues and ' + s.movementCount + ' movements are deleted too. Other versions stay.',
    confirmText: 'Delete version',
    danger: true,
  })
  if (!ok) return
  const r = await rsCall('delete_run_sheet', { p_sheet: s.id })
  if (r.error) return toast(r.error, 'danger', 8000)
  selectedId.value = ''
  await props.list.load()
  toast('Version deleted.', 'success')
}

async function markReady() {
  busy.value = true
  const r = await rsCall('mark_run_sheet_ready', { p_sheet: sheet.value.id })
  busy.value = false
  await Promise.all([props.list.load(), load()])
  if (r.error) return toast(r.error, 'danger', 8000)
  toast(
    '"' + sheet.value.name + '" is ready to run.' + (r.data ? ' ' + r.data + ' warning' + (r.data === 1 ? '' : 's') + ' left (amber).' : ''),
    'success',
  )
}

async function switchLive() {
  const s = sheet.value
  const ok = await askConfirm({
    title: 'Switch the live show to "' + s.name + '"?',
    message: 'The rest of the show runs with this version from now. The one running now stays as a record.',
    confirmText: 'Switch',
  })
  if (!ok) return
  const r = await rsCall('switch_live_run_sheet', { p_event: props.eventId, p_sheet: s.id })
  if (r.error) return toast(r.error, 'danger', 8000)
  await props.list.load()
  toast('The live show now runs "' + s.name + '".', 'success')
}

const liveName = computed(() => {
  const id = props.liveSession && props.liveSession.runSheetId
  const s = id && sheets.value.find((x) => x.id === id)
  return s ? s.name : ''
})

// ---------- Cues ----------
const sections = computed(() => [...new Set(cues.value.map((c) => c.section).filter(Boolean))])
// Rows with a section heading wherever the section changes
const rows = computed(() => {
  const out = []
  let last = null
  for (const c of cues.value) {
    const sec = c.section || ''
    if (sec !== last) {
      out.push({ heading: sec || 'No section', key: 'h-' + c.id })
      last = sec
    }
    out.push({ cue: c, key: c.id })
  }
  return out
})
const movesByCue = computed(() => {
  const map = {}
  for (const m of movements.value) if (!m.parent_id && m.cue_id) (map[m.cue_id] = map[m.cue_id] || []).push(m)
  return map
})

const editing = ref(null) // cue form: { id, rev, section, start_time, day_offset, length, title, type, can_shorten, start_mode, area, department, notes, after_position }
const cueError = ref('')
const cueIndex = computed(() => (editing.value && editing.value.id ? cues.value.findIndex((c) => c.id === editing.value.id) : -1))
// The row the editor opens under: the cue itself, or the cue a new one is added after (none = at the end)
const editorAnchor = computed(() => (editing.value ? editing.value.id || editing.value.after_id || null : null))

function openCue(c) {
  if (readOnly.value) return
  editing.value = {
    id: c.id,
    rev: c.rev,
    code: c.code,
    section: c.section || '',
    start_time: c.start_time,
    day_offset: c.day_offset === 1,
    length: formatLength(c.length_s),
    title: c.title,
    type: c.type,
    can_shorten: formatLength(c.can_shorten_s),
    start_mode: c.start_mode,
    area: c.area || '',
    department: c.department || '',
    notes: c.notes || '',
  }
  cueError.value = ''
}
function newCue(after) {
  const prev = after || cues.value[cues.value.length - 1]
  editing.value = {
    id: null,
    rev: null,
    code: '',
    section: prev ? prev.section || '' : '',
    start_time: prev ? addSeconds(prev.start_time, prev.length_s) : '18:00:00',
    day_offset: prev ? prev.day_offset === 1 : false,
    length: '1:00',
    title: '',
    type: 'normal',
    can_shorten: '0:00',
    start_mode: 'auto',
    area: '',
    department: '',
    notes: '',
    after_position: after ? after.position : null,
    after_id: after ? after.id : null,
  }
  cueError.value = ''
}
async function saveCue() {
  const f = editing.value
  cueError.value = ''
  const length = parseLength(f.length)
  const shorten = parseLength(f.can_shorten)
  if (!f.title.trim()) return (cueError.value = 'Give the cue a name.')
  if (!f.start_time) return (cueError.value = 'Give the cue a start time.')
  if (length === null) return (cueError.value = 'Length: write it as m:ss, like 2:30.')
  if (f.type === 'flexible' && shorten === null) return (cueError.value = 'Can shorten by: write it as m:ss.')
  if (f.type === 'flexible' && shorten > length) return (cueError.value = 'It cannot shorten by more than its length.')
  busy.value = true
  const r = await rsCall('save_cue', {
    p_sheet: sheet.value.id,
    p_cue: {
      id: f.id,
      rev: f.rev,
      code: f.code,
      section: f.section,
      title: f.title,
      start_time: f.start_time.length === 5 ? f.start_time + ':00' : f.start_time,
      day_offset: f.day_offset ? 1 : 0,
      length_s: length,
      type: f.type,
      can_shorten_s: f.type === 'flexible' ? shorten : 0,
      start_mode: f.type === 'anchor' ? 'auto' : f.start_mode,
      area: f.area,
      department: f.department,
      notes: f.notes,
      after_position: f.after_position,
    },
  })
  busy.value = false
  if (r.error) {
    cueError.value = r.error
    if (r.stale) {
      // Keep what I typed; the table above now shows their change. Saving again replaces it with mine.
      await load()
      const latest = cues.value.find((c) => c.id === f.id)
      if (!latest) cueError.value = 'Someone else deleted this cue. Press Cancel.'
      else {
        f.rev = latest.rev
        cueError.value = 'Someone else changed this cue a moment ago (the table shows their version). Save again to replace it with yours, or Cancel.'
      }
    }
    return
  }
  editing.value = null
  await Promise.all([load(), props.list.load()])
}
async function deleteCue() {
  const f = editing.value
  const linked = (movesByCue.value[f.id] || []).length
  const ok = await askConfirm({
    title: 'Delete "' + f.title + '"?',
    message: linked
      ? linked + (linked === 1 ? ' movement is timed to this cue. It stays' : ' movements are timed to this cue. They stay') +
        ', and the check asks you to pick a new cue.'
      : '',
    confirmText: 'Delete cue',
    danger: true,
  })
  if (!ok) return
  const r = await rsCall('delete_cue', { p_cue: f.id })
  if (r.error) return (cueError.value = r.error)
  editing.value = null
  await Promise.all([load(), props.list.load()])
}
async function moveCue(dir) {
  const r = await rsCall('move_cue', { p_cue: editing.value.id, p_direction: dir })
  if (r.error) return (cueError.value = r.error)
  editing.value = null
  await load()
}

// ---------- Movements ----------
const topMovements = computed(() => movements.value.filter((m) => !m.parent_id))
const exceptionsOf = (m) => movements.value.filter((x) => x.parent_id === m.id)
const movementEdit = ref(null) // the movement open in the editor, or { } for a new one

// A chip in the cue table: bring the movement into view below and flash it
function showMove(m) {
  const el = document.getElementById('rs-' + m.id)
  if (!el) return
  el.scrollIntoView({ behavior: 'smooth', block: 'center' })
  el.classList.add('rs-flash')
  setTimeout(() => el.classList.remove('rs-flash'), 1600)
}
function whoText(m) {
  if (m.category) return 'All "' + m.category + '"'
  const g = groupById.value[m.group_id]
  return g ? g.name : 'A deleted group'
}
function whenText(m) {
  const early = m.early_s ? formatLength(m.early_s) + ' before ' : 'by '
  if (m.deadline_kind === 'fixed') return (m.early_s ? early : 'by ') + (m.fixed_time || '?') + (m.fixed_day_offset ? ' (next day)' : '')
  const c = cueById.value[m.cue_id]
  if (!c) return 'timed to a cue that was deleted'
  const point = m.deadline_kind === 'cue_end' ? 'ends' : 'starts'
  return (m.early_s ? early : 'by the time ') + '"' + c.title + '" ' + point
}

// Another version picked: close the editors (their cue / movement belongs to the old one)
watch(selectedId, () => {
  editing.value = null
  movementEdit.value = null
})

async function onMovementSaved() {
  movementEdit.value = null
  await Promise.all([load(), props.list.load()])
}

// ---------- Excel (Stage 5): import a workbook as a new draft, export a version, the empty template ----------
const showImport = ref(false)
// On a phone the import panel opens far below the button: bring it into view
watch(showImport, async (on) => {
  if (!on) return
  await nextTick()
  const el = document.querySelector('[data-testid="rs-import-panel"]')
  if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - 8, behavior: 'smooth' })
})
const excelBusy = ref('') // 'export' or 'template' while a file is made

async function onImported(res) {
  showImport.value = false
  emit('changed')
  await Promise.all([props.list.load(), loadZones()])
  selectedId.value = res.sheet_id
  const plural = (n, one) => n + ' ' + one + (n === 1 ? '' : 's')
  const extra = [
    res.exceptions ? plural(res.exceptions, 'change') + ' for one group' : '',
    res.groups_created ? plural(res.groups_created, 'new group') : '',
    res.zones_created ? plural(res.zones_created, 'circle zone') + ' drawn' : '',
  ].filter(Boolean)
  toast(
    'Imported as a new draft: ' + plural(res.cues, 'cue') + ', ' + plural(res.movements, 'movement') +
      (extra.length ? ', ' + extra.join(', ') : '') + '. Check it, then mark it ready.',
    'success',
    9000,
  )
}

// A circle zone's centre: the middle of its outline (the bench stores it as 32 points)
async function zonesForExport() {
  const { data } = await supabase.rpc('event_zones', { p_event: props.eventId })
  const shapes = Object.fromEntries((data || []).map((z) => [z.id, z.geojson]))
  return zones.value.map((z) => {
    let centre = null
    const ring = shapes[z.id] && shapes[z.id].coordinates && shapes[z.id].coordinates[0]
    if (z.is_circle && ring && ring.length > 1) {
      const pts = ring.slice(0, -1)
      centre = [pts.reduce((a, p) => a + p[1], 0) / pts.length, pts.reduce((a, p) => a + p[0], 0) / pts.length]
    }
    return { id: z.id, code: z.code, name: z.name, kind: z.kind, capacity: z.capacity, isCircle: z.is_circle, radius: Number(z.radius_m), centre }
  })
}

async function exportVersion() {
  const s = sheet.value
  excelBusy.value = 'export'
  try {
    const ExcelJS = await loadExcel()
    const wb = buildWorkbook(ExcelJS, {
      event: { name: props.eventName },
      sheet: { name: s.name, forDate: s.forDate },
      cues: cues.value,
      movements: movements.value,
      groups: props.groups,
      zones: await zonesForExport(),
      members: props.members,
    })
    const saved = await saveFile(await wb.xlsx.writeBuffer(), 'Run sheet - ' + props.eventName + ' - ' + s.name + '.xlsx', XLSX_TYPE)
    if (saved) toast('"' + s.name + '" saved as an Excel file.', 'success')
  } catch (e) {
    toast('The Excel file could not be made: ' + (e && e.message ? e.message : e), 'danger', 8000)
  } finally {
    excelBusy.value = ''
  }
}

async function downloadTemplate() {
  excelBusy.value = 'template'
  try {
    const ExcelJS = await loadExcel()
    const wb = buildWorkbook(ExcelJS, TEMPLATE_EXAMPLE)
    await saveFile(await wb.xlsx.writeBuffer(), 'Run sheet template.xlsx', XLSX_TYPE)
  } catch (e) {
    toast('The template could not be made: ' + (e && e.message ? e.message : e), 'danger', 8000)
  } finally {
    excelBusy.value = ''
  }
}

// Problems: errors first; a big run sheet can have hundreds of warnings, so show 8 until asked
const PROBLEMS_SHOWN = 8
const showAllProblems = ref(false)
const sortedProblems = computed(() => [...problems.value].sort((a, b) => (a.severity === b.severity ? 0 : a.severity === 'error' ? -1 : 1)))
const visibleProblems = computed(() => (showAllProblems.value ? sortedProblems.value : sortedProblems.value.slice(0, PROBLEMS_SHOWN)))
watch(selectedId, () => (showAllProblems.value = false))

function scrollToProblem(p) {
  if (p.itemType === 'cue') {
    const c = cueById.value[p.itemId]
    if (c && !readOnly.value) openCue(c)
  } else if (p.itemType === 'movement') {
    const m = movements.value.find((x) => x.id === p.itemId)
    const top = m && m.parent_id ? movements.value.find((x) => x.id === m.parent_id) : m
    if (top) movementEdit.value = top
  }
  const el = document.getElementById('rs-' + p.itemId)
  if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' })
}

const todayIso = isoDate(new Date())
</script>

<template>
  <div class="d-grid gap-3" data-testid="run-sheet">
    <!-- ======== Versions ======== -->
    <div class="card">
      <div class="card-body d-grid gap-2">
        <div v-if="!list.loaded.value" class="text-muted small">Loading run sheets…</div>

        <template v-else-if="!sheets.length">
          <div class="text-center py-3" data-testid="rs-empty">
            <p class="mb-2"><strong>No run sheet yet.</strong></p>
            <p class="small text-muted mb-3">A run sheet is the show's running order: cues with their times, and where each group must be by when.</p>
            <div v-if="canEdit" class="d-flex flex-wrap gap-2 justify-content-center">
              <button class="btn btn-primary" data-testid="rs-create-first" @click="openNew(false)">Create run sheet</button>
              <button class="btn btn-outline-primary" data-testid="rs-import-first" @click="showImport = true">Import from Excel</button>
            </div>
            <p v-else class="small text-muted mb-0">The root or a planner creates it.</p>
            <button class="btn btn-link btn-sm mt-2" :disabled="!!excelBusy" data-testid="rs-template-first" @click="downloadTemplate">
              {{ excelBusy === 'template' ? 'Making the template…' : 'Download the Excel template' }}
            </button>
          </div>
        </template>

        <template v-else>
          <div class="d-flex flex-wrap gap-2 align-items-center">
            <label class="visually-hidden" for="rs-version">Version</label>
            <select id="rs-version" v-model="selectedId" class="form-select rs-version" data-testid="rs-version">
              <option v-for="s in sheets" :key="s.id" :value="s.id">{{ versionLabel(s) }}</option>
            </select>
            <template v-if="canEdit">
              <button class="btn btn-sm btn-outline-primary" data-testid="rs-new" @click="openNew(false)">New version</button>
              <button class="btn btn-sm btn-outline-secondary" :disabled="!sheet" data-testid="rs-duplicate" @click="openNew(true)">Duplicate</button>
              <button class="btn btn-sm btn-outline-secondary" :disabled="!sheet" data-testid="rs-rename" @click="openRename">Rename</button>
              <button
                v-if="sheet && sheet.status !== 'used'"
                class="btn btn-sm btn-outline-danger"
                data-testid="rs-delete"
                @click="deleteVersion"
              >Delete</button>
            </template>
          </div>

          <!-- Excel -->
          <div class="d-flex flex-wrap gap-2 align-items-center small" data-testid="rs-excel">
            <span class="text-muted">Excel:</span>
            <button v-if="canEdit" class="btn btn-sm btn-outline-secondary" :disabled="showImport" data-testid="rs-import" @click="showImport = true">Import</button>
            <button class="btn btn-sm btn-outline-secondary" :disabled="!sheet || !!excelBusy" data-testid="rs-export" @click="exportVersion">
              {{ excelBusy === 'export' ? 'Making the file…' : 'Export this version' }}
            </button>
            <button class="btn btn-sm btn-link px-1" :disabled="!!excelBusy" data-testid="rs-template" @click="downloadTemplate">
              {{ excelBusy === 'template' ? 'Making the template…' : 'Template' }}
            </button>
          </div>

          <div v-if="sheet" class="small text-muted" data-testid="rs-summary">
            {{ sheet.cueCount }} cue{{ sheet.cueCount === 1 ? '' : 's' }} · {{ sheet.movementCount }} movement{{ sheet.movementCount === 1 ? '' : 's' }}
            <template v-if="sheet.forDate"> · for {{ dayLabel(sheet.forDate) }}<span v-if="sheet.forDate === todayIso"> (today)</span></template>
          </div>

          <!-- What this version's status means, in one line -->
          <div v-if="sheet && sheet.status === 'used'" class="alert alert-secondary py-2 small mb-0" data-testid="rs-used-note">
            🔒 <strong>Used:</strong> it ran on {{ formatDayTime(sheet.usedOn) }}{{ sheet.live ? ' and is running now' : '' }}, so it is kept as it was.
            <template v-if="canEdit"> To change it, <button class="btn btn-link btn-sm p-0 align-baseline" @click="openNew(true)">duplicate it</button>.</template>
          </div>
          <div v-else-if="sheet && sheet.status === 'ready'" class="small text-success" data-testid="rs-ready-note">
            ✅ <strong>Ready:</strong> it can be picked when the event starts. Editing it makes it a draft again until it is checked.
          </div>
          <div v-else-if="sheet" class="small text-muted" data-testid="rs-draft-note">
            ✏️ <strong>Draft:</strong> fix anything in red, then check it to make it Ready. Only Ready versions can be picked when the event starts.
          </div>
          <div v-if="sheet && sheet.scheduledAt" class="small" :class="sheet.status === 'draft' ? 'text-danger' : 'text-primary'" data-testid="rs-scheduled-note">
            📅 Picked for the scheduled start, {{ formatDayTime(sheet.scheduledAt) }}.
            <strong v-if="sheet.status === 'draft'">It was changed since it was checked: check it again before the start.</strong>
          </div>

          <!-- Live: run the rest of the show with another version -->
          <div
            v-if="canEdit && liveSession && sheet && !sheet.live && sheet.status !== 'draft'"
            class="alert alert-warning py-2 small mb-0 d-flex flex-wrap gap-2 align-items-center"
            data-testid="rs-switch-live"
          >
            <span class="flex-grow-1">The live show is running {{ liveName ? '"' + liveName + '"' : 'without a run sheet' }}.</span>
            <button class="btn btn-sm btn-warning" @click="switchLive">Switch live show to "{{ sheet.name }}"</button>
          </div>

          <div v-if="canEdit && sheet && sheet.status === 'draft'">
            <button class="btn btn-success btn-sm" :disabled="busy || !cues.length" data-testid="rs-mark-ready" @click="markReady">
              Check &amp; mark ready
            </button>
          </div>
        </template>

        <!-- New / Duplicate / Rename -->
        <form v-if="versionForm" class="border rounded p-3 bg-light d-grid gap-2" data-testid="rs-version-form" @submit.prevent="saveVersion">
          <h3 class="h6 mb-0">{{ versionForm.mode === 'rename' ? 'Rename version' : versionForm.copyFrom ? 'Duplicate version' : 'New version' }}</h3>
          <div class="row g-2">
            <div class="col-sm-7">
              <label class="form-label small mb-1" for="rs-name">Name</label>
              <!-- The suggested name is selected on the first tap, so typing replaces it instead of adding to it -->
              <input id="rs-name" v-model="versionForm.name" class="form-control" maxlength="60" placeholder="e.g. Rehearsal 2" data-testid="rs-name" @focus="$event.target.select()" />
            </div>
            <div class="col-sm-5">
              <label class="form-label small mb-1" for="rs-date">For date (optional)</label>
              <input id="rs-date" v-model="versionForm.forDate" type="date" class="form-control" data-testid="rs-date" />
            </div>
          </div>
          <div v-if="versionForm.mode === 'new' && sheets.length">
            <label class="form-label small mb-1" for="rs-copy">Start from</label>
            <select id="rs-copy" v-model="versionForm.copyFrom" class="form-select" data-testid="rs-copy">
              <option value="">A blank run sheet</option>
              <option v-for="s in sheets" :key="s.id" :value="s.id">A copy of "{{ s.name }}"</option>
            </select>
          </div>
          <div v-if="versionError" class="small text-danger" role="alert" data-testid="rs-version-error">{{ versionError }}</div>
          <div class="d-flex gap-2">
            <button class="btn btn-primary btn-sm" type="submit" :disabled="busy" data-testid="rs-version-save">
              {{ versionForm.mode === 'rename' ? 'Save' : 'Create' }}
            </button>
            <button class="btn btn-outline-secondary btn-sm" type="button" @click="versionForm = null">Cancel</button>
          </div>
        </form>
      </div>
    </div>

    <RunSheetImport
      v-if="showImport && canEdit"
      :event-id="eventId"
      :event-name="eventName"
      :groups="groups"
      :zones="zones"
      :version-names="sheets.map((s) => s.name)"
      @imported="onImported"
      @close="showImport = false"
    />

    <template v-if="sheet">
      <div v-if="errorMsg" class="alert alert-danger small" role="alert">{{ errorMsg }}</div>

      <!-- ======== Problems ======== -->
      <div
        v-if="problems.length"
        class="card"
        :class="errorCount ? 'border-danger' : 'border-warning'"
        data-testid="rs-problems"
      >
        <div class="card-body py-2">
          <div class="small fw-semibold mb-1">
            <span v-if="errorCount" class="text-danger">{{ errorCount }} problem{{ errorCount === 1 ? '' : 's' }} to fix</span>
            <span v-if="errorCount && warningCount"> · </span>
            <span v-if="warningCount" class="text-warning-emphasis">{{ warningCount }} warning{{ warningCount === 1 ? '' : 's' }}</span>
          </div>
          <ul class="list-unstyled small mb-0 d-grid gap-1">
            <li v-for="(p, i) in visibleProblems" :key="i" :data-testid="'rs-problem-' + p.severity">
              <button class="btn btn-link btn-sm p-0 text-start text-decoration-none" :class="p.severity === 'error' ? 'text-danger' : 'text-warning-emphasis'" @click="scrollToProblem(p)">
                {{ p.severity === 'error' ? '✗' : '!' }} {{ p.message }}
              </button>
            </li>
          </ul>
          <button
            v-if="problems.length > PROBLEMS_SHOWN"
            class="btn btn-link btn-sm p-0 mt-1"
            data-testid="rs-problems-toggle"
            @click="showAllProblems = !showAllProblems"
          >
            {{ showAllProblems ? 'Show fewer' : 'Show all ' + problems.length }}
          </button>
        </div>
      </div>
      <div v-else-if="cues.length" class="small text-success" data-testid="rs-no-problems">✓ The check finds no problems.</div>

      <!-- ======== Cues ======== -->
      <div class="card">
        <div class="card-header d-flex align-items-center">
          <h3 class="h6 mb-0 flex-grow-1">Cues</h3>
          <button v-if="!readOnly" class="btn btn-sm btn-outline-primary" data-testid="rs-add-cue" @click="newCue(null)">Add cue</button>
        </div>
        <div v-if="!cues.length" class="card-body small text-muted" data-testid="rs-no-cues">
          No cues yet. <template v-if="!readOnly">Press <strong>Add cue</strong> to add the first one.</template>
        </div>
        <div v-else class="table-responsive">
          <table class="table table-sm align-middle mb-0 rs-table pv-stack">
            <thead>
              <tr>
                <th scope="col">Start</th>
                <th scope="col">Length</th>
                <th scope="col">Cue</th>
                <th scope="col" class="d-none d-md-table-cell">Type · starts</th>
                <th scope="col">Groups must be in…</th>
              </tr>
            </thead>
            <tbody>
              <template v-for="row in rows" :key="row.key">
                <tr v-if="row.heading" class="rs-section">
                  <th colspan="5" scope="rowgroup">{{ row.heading }}</th>
                </tr>
                <template v-else>
                  <tr
                    :id="'rs-' + row.cue.id"
                    :class="{ 'rs-row-edit': !readOnly, 'table-active': editing && editing.id === row.cue.id }"
                    :data-testid="'rs-cue-' + row.cue.code"
                    @click="openCue(row.cue)"
                  >
                    <td class="rs-mono">{{ row.cue.start_time }}<span v-if="row.cue.day_offset" class="badge text-bg-light border ms-1">+1 day</span></td>
                    <td class="rs-mono">{{ formatLength(row.cue.length_s) }}</td>
                    <td>
                      <span v-for="p in problemsFor[row.cue.id] || []" :key="p.message" :class="p.severity === 'error' ? 'text-danger' : 'text-warning-emphasis'" :title="p.message">{{ p.severity === 'error' ? '✗ ' : '! ' }}</span>
                      <span class="text-muted small me-1">{{ row.cue.code }}</span>{{ row.cue.title }}
                      <span v-if="row.cue.type === 'anchor'" class="badge text-bg-dark ms-1 d-md-none">⚓</span>
                    </td>
                    <td class="d-none d-md-table-cell small">
                      <span v-if="row.cue.type === 'anchor'" class="rs-pill rs-pill-anchor">⚓ Anchor · fixed</span>
                      <template v-else>
                        <span v-if="row.cue.type === 'flexible'" class="rs-pill rs-pill-flex">Flexible · −{{ formatLength(row.cue.can_shorten_s) }}</span>
                        <span v-else>Normal</span>
                        <span class="text-muted"> · </span>
                        <strong v-if="row.cue.start_mode === 'auto_ready'">When ready</strong>
                        <span v-else>{{ row.cue.start_mode === 'auto' ? 'Auto' : 'GO' }}</span>
                      </template>
                    </td>
                    <td class="small">
                      <!-- Who must be where for this cue: a chip per movement (tap to see it below) -->
                      <span class="d-flex flex-wrap gap-1">
                        <button
                          v-for="m in movesByCue[row.cue.id] || []"
                          :key="m.id"
                          type="button"
                          class="rs-pill rs-pill-move"
                          :title="whoText(m) + ' must be inside ' + (zoneById[m.zone_id] ? zoneById[m.zone_id].code : 'its zone') + ' ' + whenText(m)"
                          @click.stop="showMove(m)"
                        >
                          {{ whoText(m) }} → {{ zoneById[m.zone_id] ? zoneById[m.zone_id].code : '?' }}
                        </button>
                        <span v-if="!(movesByCue[row.cue.id] || []).length" class="text-muted">—</span>
                      </span>
                    </td>
                  </tr>
                  <!-- The cue editor opens right under the cue being edited (or the cue a new one goes after) -->
                  <tr v-if="editorAnchor === row.cue.id" class="rs-editor-row">
                    <td colspan="5" class="p-2"><div id="rs-cue-slot"></div></td>
                  </tr>
                </template>
              </template>
            </tbody>
          </table>
        </div>
      </div>

      <!-- A new cue at the end: the editor opens here -->
      <div v-if="editing && !editorAnchor" id="rs-cue-slot"></div>

      <Teleport v-if="editing" :key="editorAnchor || 'end'" defer to="#rs-cue-slot">
      <form
        class="card border-primary"
        data-testid="rs-cue-form"
        @submit.prevent="saveCue"
      >
        <div class="card-body d-grid gap-2">
          <h3 class="h6 mb-0">{{ editing.id ? 'Edit cue ' + editing.code : 'New cue' }}</h3>
          <div class="row g-2">
            <div class="col-12 col-md-6">
              <label class="form-label small mb-1" for="cue-title">Cue name</label>
              <input id="cue-title" v-model="editing.title" class="form-control" maxlength="120" placeholder="e.g. Parade & Ceremony" data-testid="cue-title" />
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-section">Section</label>
              <input id="cue-section" v-model="editing.section" class="form-control" maxlength="60" list="rs-sections" placeholder="e.g. Pre-show" data-testid="cue-section" />
              <datalist id="rs-sections"><option v-for="s in sections" :key="s" :value="s" /></datalist>
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-code">Code</label>
              <input id="cue-code" v-model="editing.code" class="form-control" maxlength="20" placeholder="auto" data-testid="cue-code" />
            </div>
            <div class="col-7 col-md-3">
              <label class="form-label small mb-1" for="cue-start">Start</label>
              <input id="cue-start" v-model="editing.start_time" type="time" step="1" class="form-control" data-testid="cue-start" />
              <div class="form-check mt-1">
                <input id="cue-next-day" v-model="editing.day_offset" class="form-check-input" type="checkbox" />
                <label class="form-check-label small" for="cue-next-day">After midnight (+1 day)</label>
              </div>
            </div>
            <div class="col-5 col-md-3">
              <label class="form-label small mb-1" for="cue-length">Length (m:ss)</label>
              <input id="cue-length" v-model="editing.length" class="form-control" inputmode="numeric" placeholder="2:30" data-testid="cue-length" />
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-type">Type</label>
              <select id="cue-type" v-model="editing.type" class="form-select" data-testid="cue-type">
                <option value="normal">Normal</option>
                <option value="flexible">Flexible (can shorten)</option>
                <option value="anchor">⚓ Anchor (fixed time)</option>
              </select>
            </div>
            <div v-if="editing.type === 'flexible'" class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-shorten">Can shorten by (m:ss)</label>
              <input id="cue-shorten" v-model="editing.can_shorten" class="form-control" data-testid="cue-shorten" />
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-mode">How it starts</label>
              <select id="cue-mode" v-model="editing.start_mode" class="form-select" :disabled="editing.type === 'anchor'" data-testid="cue-mode">
                <option value="auto">Auto (on time)</option>
                <option value="auto_ready">Auto when groups are ready</option>
                <option value="manual">Manual (waits for GO)</option>
              </select>
              <div v-if="editing.type === 'anchor'" class="form-text">An anchor always starts on its time.</div>
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-area">Area</label>
              <input id="cue-area" v-model="editing.area" class="form-control" maxlength="60" placeholder="e.g. Padang" />
            </div>
            <div class="col-6 col-md-3">
              <label class="form-label small mb-1" for="cue-dept">Department</label>
              <input id="cue-dept" v-model="editing.department" class="form-control" maxlength="60" />
            </div>
            <div class="col-12">
              <label class="form-label small mb-1" for="cue-notes">Notes</label>
              <textarea id="cue-notes" v-model="editing.notes" class="form-control" rows="2" maxlength="500"></textarea>
            </div>
          </div>
          <div class="small text-muted" data-testid="cue-ends">
            Ends at {{ addSeconds(editing.start_time.length === 5 ? editing.start_time + ':00' : editing.start_time, parseLength(editing.length) || 0) }}
          </div>
          <div v-if="cueError" class="small text-danger" role="alert" data-testid="cue-error">{{ cueError }}</div>
          <div class="d-flex flex-wrap gap-2">
            <button class="btn btn-primary btn-sm" type="submit" :disabled="busy" data-testid="cue-save">Save cue</button>
            <button class="btn btn-outline-secondary btn-sm" type="button" @click="editing = null">Cancel</button>
            <template v-if="editing.id">
              <button class="btn btn-outline-secondary btn-sm" type="button" title="Move up" :disabled="cueIndex === 0" data-testid="cue-up" @click="moveCue(-1)">↑ Up</button>
              <button class="btn btn-outline-secondary btn-sm" type="button" title="Move down" :disabled="cueIndex === cues.length - 1" data-testid="cue-down" @click="moveCue(1)">↓ Down</button>
              <button class="btn btn-outline-primary btn-sm" type="button" data-testid="cue-add-after" @click="newCue(cueById[editing.id])">Add cue after</button>
              <button class="btn btn-outline-danger btn-sm ms-auto" type="button" data-testid="cue-delete" @click="deleteCue">Delete</button>
            </template>
          </div>
        </div>
      </form>
      </Teleport>

      <!-- ======== Movements ======== -->
      <div class="card">
        <div class="card-header d-flex align-items-center">
          <h3 class="h6 mb-0 flex-grow-1">Movements <span class="small text-muted fw-normal">· who must be where, by when</span></h3>
          <button v-if="!readOnly" class="btn btn-sm btn-outline-primary" :disabled="!cues.length" data-testid="rs-add-move" @click="movementEdit = {}">Add movement</button>
        </div>
        <div v-if="!topMovements.length" class="card-body small text-muted" data-testid="rs-no-moves">
          No movements yet.<template v-if="!readOnly && !cues.length"> Add a cue first: movements are timed to cues.</template>
        </div>
        <ul v-else class="list-group list-group-flush">
          <li
            v-for="m in topMovements"
            :id="'rs-' + m.id"
            :key="m.id"
            class="list-group-item d-flex gap-2 align-items-start"
            :data-testid="'rs-move-' + m.code"
          >
            <div class="flex-grow-1 small">
              <span v-for="p in problemsFor[m.id] || []" :key="p.message" :class="p.severity === 'error' ? 'text-danger' : 'text-warning-emphasis'" :title="p.message">{{ p.severity === 'error' ? '✗ ' : '! ' }}</span>
              <span class="text-muted me-1">{{ m.code }}</span>
              <strong>{{ whoText(m) }}</strong> →
              <strong>{{ zoneById[m.zone_id] ? zoneById[m.zone_id].code : 'no zone yet' }}</strong>
              <span class="text-muted"> · {{ whenText(m) }}</span>
              <span v-if="m.travel_mode !== 'on_foot'" class="badge text-bg-light border ms-1">{{ m.travel_mode === 'vehicle' ? 'Vehicle' : 'Fixed route' }}</span>
              <div v-if="exceptionsOf(m).length" class="text-muted">
                Exceptions: {{ exceptionsOf(m).map((x) => (groupById[x.group_id] || { name: '?' }).name + (x.skip ? ' (skipped)' : ' → ' + (zoneById[x.zone_id] || { code: 'no zone' }).code)).join(', ') }}
              </div>
            </div>
            <button class="btn btn-sm btn-outline-secondary" :data-testid="'rs-move-open-' + m.code" @click="movementEdit = m">{{ readOnly ? 'View' : 'Edit' }}</button>
          </li>
        </ul>
      </div>

      <MovementEditor
        v-if="movementEdit"
        :sheet-id="sheet.id"
        :movement="movementEdit.id ? movementEdit : null"
        :exceptions="movementEdit.id ? exceptionsOf(movementEdit) : []"
        :cues="cues"
        :zones="zones"
        :groups="groups"
        :read-only="readOnly"
        @saved="onMovementSaved"
        @close="movementEdit = null"
        @changed="load"
      />
    </template>
  </div>
</template>

<style scoped>
.rs-version {
  max-width: 28rem;
  flex: 1 1 16rem;
}
.rs-mono {
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.rs-section th {
  background: var(--bs-tertiary-bg);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--bs-secondary-color);
}
.rs-row-edit {
  cursor: pointer;
}
.rs-editor-row > td {
  background: var(--bs-tertiary-bg);
}
.rs-pill {
  display: inline-block;
  border: 0;
  border-radius: 999px;
  padding: 2px 10px;
  font-size: 12px;
  font-weight: 600;
  line-height: 1.5;
  white-space: nowrap;
}
.rs-pill-anchor {
  background: #0f1b2d;
  color: #fff;
}
.rs-pill-flex {
  background: #e0f2fe;
  color: #0c4a6e;
}
.rs-pill-move {
  background: #ccfbf1;
  color: #115e59;
  cursor: pointer;
}
.rs-pill-move:hover,
.rs-pill-move:focus-visible {
  background: #99f6e4;
}
.rs-flash {
  animation: rs-flash 1.6s ease-out;
}
@keyframes rs-flash {
  0%,
  40% {
    background: #fef3c7;
  }
}
@media (prefers-reduced-motion: reduce) {
  .rs-flash {
    animation: none;
  }
}
</style>
