<script setup>
// RunSheetImport - "Import from Excel" (merger Stage 5): pick the workbook, see every problem by tab and row,
// name the new version, then import it as a Draft. Nothing is saved while anything is red; the database
// checks it all again and stores all of it or nothing (import_run_sheet in 025_run_sheet_import.sql).
import { ref, computed } from 'vue'
import { readWorkbook, importPayload } from '../utils/runSheetFile'
import { loadExcel, rsCall } from '../composables/useRunSheets'

const props = defineProps({
  eventId: { type: String, required: true },
  eventName: { type: String, default: '' },
  groups: { type: Array, default: () => [] },
  zones: { type: Array, default: () => [] }, // { code, name, kind }
  versionNames: { type: Array, default: () => [] },
})
const emit = defineEmits(['imported', 'close'])

const MAX_BYTES = 10 * 1024 * 1024
const SHOWN = 40 // problems listed before "Show all"

const fileInput = ref(null)
const fileName = ref('')
const reading = ref(false)
const saving = ref(false)
const result = ref(null)
const fileError = ref('')
const serverError = ref('')
const name = ref('')
const forDate = ref('')
const showAll = ref({ errors: false, warnings: false })

function choose() {
  fileInput.value && fileInput.value.click()
}

async function onFile(ev) {
  const file = ev.target.files && ev.target.files[0]
  ev.target.value = '' // the same file can be picked again after fixing it
  if (!file) return
  fileError.value = ''
  serverError.value = ''
  result.value = null
  fileName.value = file.name
  if (!/\.xlsx$/i.test(file.name)) {
    fileError.value = 'Pick an Excel workbook (.xlsx). Older .xls files and CSV: open them in Excel and save as .xlsx.'
    return
  }
  if (file.size > MAX_BYTES) {
    fileError.value = 'This file is ' + (file.size / 1048576).toFixed(1) + ' MB; a run sheet workbook is far smaller (10 MB at most). Is it the right file?'
    return
  }
  reading.value = true
  try {
    const ExcelJS = await loadExcel()
    const buffer = await file.arrayBuffer()
    const r = await readWorkbook(ExcelJS, buffer, {
      eventName: props.eventName,
      groups: props.groups,
      zones: props.zones,
    })
    result.value = r
    name.value = (r.meta.versionName || file.name.replace(/\.xlsx$/i, '')).slice(0, 60)
    forDate.value = r.meta.forDate || ''
    showAll.value = { errors: false, warnings: false }
  } catch (e) {
    fileError.value = 'The file could not be read: ' + (e && e.message ? e.message : e)
  } finally {
    reading.value = false
  }
}

const nameError = computed(() => {
  const n = name.value.trim()
  if (!n) return 'Give the new version a name.'
  if (n.length > 60) return 'A version name is up to 60 characters.'
  if (props.versionNames.some((v) => v.trim().toLowerCase() === n.toLowerCase())) return 'There is already a version called "' + n + '". Pick another name.'
  return ''
})
const canImport = computed(() => result.value && !result.value.errors.length && !nameError.value && !saving.value)

function where(p) {
  return p.tab + (p.row ? ' row ' + p.row : '')
}
const list = (kind) => {
  const all = result.value ? result.value[kind] : []
  return showAll.value[kind] ? all : all.slice(0, SHOWN)
}

const summary = computed(() => {
  const c = result.value && result.value.counts
  if (!c) return []
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many)
  return [
    plural(c.cues, 'cue', 'cues'),
    plural(c.movements, 'movement', 'movements'),
    c.exceptions ? plural(c.exceptions, 'change for one group', 'changes for one group') : '',
    c.groupsNew ? plural(c.groupsNew, 'new group', 'new groups') : '',
    c.groupsUpdated ? plural(c.groupsUpdated, 'group updated', 'groups updated') : '',
    c.zonesNew ? plural(c.zonesNew, 'circle zone to draw', 'circle zones to draw') : '',
    c.zonesMissing ? plural(c.zonesMissing, 'zone still to draw by hand', 'zones still to draw by hand') : '',
  ].filter(Boolean)
})

async function doImport() {
  if (!canImport.value) return
  saving.value = true
  serverError.value = ''
  const r = await rsCall('import_run_sheet', {
    p_event: props.eventId,
    p_data: importPayload(result.value, name.value.trim(), forDate.value),
  })
  saving.value = false
  if (r.error) {
    serverError.value = r.error
    return
  }
  emit('imported', r.data)
}
</script>

<template>
  <div class="card border-primary" data-testid="rs-import-panel">
    <div class="card-body d-grid gap-3">
      <div class="d-flex align-items-start">
        <div class="flex-grow-1">
          <h3 class="h6 mb-1">Import from Excel</h3>
          <p class="small text-muted mb-0">
            The workbook becomes a <strong>new Draft version</strong>; other versions are not touched. Nothing is saved until
            every row is right.
          </p>
        </div>
        <button type="button" class="btn-close" aria-label="Close" @click="emit('close')"></button>
      </div>

      <input ref="fileInput" type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" class="d-none" data-testid="rs-import-file" @change="onFile" />
      <div class="d-flex flex-wrap gap-2 align-items-center">
        <button type="button" class="btn btn-outline-primary btn-sm" :disabled="reading || saving" data-testid="rs-import-choose" @click="choose">
          {{ result || fileError ? 'Choose another file' : 'Choose the Excel file' }}
        </button>
        <span v-if="fileName" class="small text-muted text-break">{{ fileName }}</span>
        <span v-if="reading" class="small">Reading the workbook…</span>
      </div>
      <div v-if="fileError" class="alert alert-danger small mb-0" role="alert" data-testid="rs-import-file-error">{{ fileError }}</div>

      <template v-if="result">
        <div class="small" data-testid="rs-import-summary">
          <strong>In this file:</strong> {{ summary.join(' · ') || 'nothing' }}
        </div>

        <!-- Problems that stop the import -->
        <div v-if="result.errors.length" class="border border-danger rounded p-2" data-testid="rs-import-errors">
          <div class="small fw-semibold text-danger mb-1">
            {{ result.errors.length }} problem{{ result.errors.length === 1 ? '' : 's' }} to fix in the file first. Fix them in Excel, save, and choose the file again.
          </div>
          <ul class="small mb-0 ps-3 d-grid gap-1">
            <li v-for="(p, i) in list('errors')" :key="'e' + i"><strong>{{ where(p) }}:</strong> {{ p.msg }}</li>
          </ul>
          <button v-if="result.errors.length > SHOWN" type="button" class="btn btn-link btn-sm p-0" @click="showAll.errors = !showAll.errors">
            {{ showAll.errors ? 'Show fewer' : 'Show all ' + result.errors.length }}
          </button>
        </div>
        <div v-else class="small text-success" data-testid="rs-import-clean">✓ Every row can be imported.</div>

        <!-- Things to know (do not stop the import) -->
        <details v-if="result.warnings.length" class="small" :open="!result.errors.length" data-testid="rs-import-warnings">
          <summary class="text-warning-emphasis fw-semibold">{{ result.warnings.length }} thing{{ result.warnings.length === 1 ? '' : 's' }} to know (the import still works)</summary>
          <ul class="mb-0 ps-3 mt-1 d-grid gap-1">
            <li v-for="(p, i) in list('warnings')" :key="'w' + i"><strong>{{ where(p) }}:</strong> {{ p.msg }}</li>
          </ul>
          <button v-if="result.warnings.length > SHOWN" type="button" class="btn btn-link btn-sm p-0" @click="showAll.warnings = !showAll.warnings">
            {{ showAll.warnings ? 'Show fewer' : 'Show all ' + result.warnings.length }}
          </button>
        </details>
        <ul v-if="result.infos.length" class="small text-muted mb-0 ps-3" data-testid="rs-import-infos">
          <li v-for="(p, i) in result.infos" :key="'i' + i">{{ p.msg }}</li>
        </ul>

        <!-- The new version -->
        <div v-if="!result.errors.length" class="row g-2">
          <div class="col-sm-7">
            <label class="form-label small mb-1" for="rs-import-name">New version name</label>
            <input id="rs-import-name" v-model="name" class="form-control" maxlength="60" data-testid="rs-import-name" />
            <div v-if="nameError" class="small text-danger mt-1" data-testid="rs-import-name-error">{{ nameError }}</div>
          </div>
          <div class="col-sm-5">
            <label class="form-label small mb-1" for="rs-import-date">For date (optional)</label>
            <input id="rs-import-date" v-model="forDate" type="date" class="form-control" data-testid="rs-import-date" />
          </div>
        </div>

        <div v-if="serverError" class="alert alert-danger small mb-0" role="alert" data-testid="rs-import-server-error">
          Nothing was imported. {{ serverError }}
        </div>

        <div class="d-flex gap-2">
          <button type="button" class="btn btn-primary btn-sm" :disabled="!canImport" data-testid="rs-import-go" @click="doImport">
            {{ saving ? 'Importing…' : 'Import as a new draft' }}
          </button>
          <button type="button" class="btn btn-outline-secondary btn-sm" :disabled="saving" @click="emit('close')">Cancel</button>
        </div>
      </template>
    </div>
  </div>
</template>
