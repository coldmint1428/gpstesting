<script setup>
// Playback tab (root and planners only; the database checks this too).
// Lists the event's recordings, newest first:
//   - the live session (Rewind: replay up to now, then back to the live map)
//   - finished sessions (Start -> End), kept online until 23:59 seven days after the day they ended
//   - days with readings from before Start/End existed
// Each can be played or downloaded as CSV. After the 7 days, a downloaded CSV can be replayed
// here: the file is read in the browser and never uploaded.
import { ref, computed, watch, markRaw, onMounted, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { loadRecording, loadNewRows } from '../composables/usePlaybackHistory'
import { addRows, recordingToCsv, csvToRecording, csvFileName, downloadText } from '../utils/playback'
import { formatTime, formatDay, formatDayTime, sgtParts } from '../utils/time'
import { askConfirm, toast } from '../composables/useNotify'
import PlaybackPlayer from './PlaybackPlayer.vue'

const props = defineProps({
  eventId: { type: String, required: true },
  eventName: { type: String, default: '' },
  members: { type: Array, default: () => [] }, // names for people who start sharing during a live rewind
  active: { type: Boolean, default: true }, // tab visible
})
const emit = defineEmits(['go-live'])

const LIVE_REFRESH_MS = 30000 // live rewind: fetch new readings every 30 s (phones send every 30 s)
const DAY_MS = 24 * 3600 * 1000

const items = ref([])
const loadingList = ref(false)
const errorMsg = ref('')
const infoMsg = ref('')
const busyKey = ref(null) // which item is loading
const progress = ref('')
const player = ref(null) // { recording, version, title, live, fileName, item }

// ---------- List ----------
async function loadList() {
  loadingList.value = true
  const [{ data, error }, ran] = await Promise.all([
    supabase.rpc('playback_list', { p_event_id: props.eventId }),
    supabase.rpc('session_run_sheets', { p_event: props.eventId }),
  ])
  loadingList.value = false
  // "Ran with: Rehearsal 2, then Rehearsal 2b from 8:14 pm" (run sheet versions, merger Stage 4)
  const ranWith = {}
  for (const r of (ran && ran.data) || []) (ranWith[r.session_id] = ranWith[r.session_id] || []).push(r)
  if (error) {
    errorMsg.value = error.message
    return
  }
  const now = Date.now()
  items.value = data.map((row) => {
    const startsAt = new Date(row.starts_at)
    const endedAt = row.ended_at ? new Date(row.ended_at) : null
    const availableUntil = row.available_until ? new Date(row.available_until) : null
    const live = row.kind === 'session' && !endedAt
    return {
      key: row.session_id || 'day-' + row.starts_at,
      kind: row.kind,
      live,
      startsAt,
      endedAt,
      endReason: row.end_reason,
      readings: row.readings,
      people: row.people,
      availableUntil,
      expired: availableUntil !== null && now >= availableUntil.getTime(),
      expiresSoon: availableUntil !== null && availableUntil.getTime() - now <= 2 * DAY_MS,
      title: itemTitle(row.kind, startsAt, endedAt),
      ranWith: row.session_id ? ranWithText(ranWith[row.session_id]) : '',
    }
  })
}

function ranWithText(steps) {
  if (!steps || !steps.length || (steps.length === 1 && !steps[0].run_sheet_id)) return ''
  return steps
    .map((s, i) => (s.run_sheet_id ? s.name || 'a deleted version' : 'no run sheet') + (i ? ' from ' + formatTime(new Date(s.from_at)) : ''))
    .join(', then ')
}

function itemTitle(kind, startsAt, endedAt) {
  if (!endedAt) return 'Live since ' + formatDayTime(startsAt)
  const sameDay = formatDay(startsAt) === formatDay(endedAt)
  const range = formatDayTime(startsAt) + ' – ' + (sameDay ? formatTime(endedAt) : formatDayTime(endedAt))
  return kind === 'day' ? range + ' (before Start/End)' : range
}

// "available until" is midnight starting the 8th day; show it as 11:59 pm the day before
function untilText(item) {
  return formatDay(item.availableUntil.getTime() - 60000) + ', 11:59 pm'
}

// ---------- Play / download from the database ----------
async function fetchRecording(item) {
  busyKey.value = item.key
  progress.value = 'Loading...'
  errorMsg.value = ''
  try {
    const to = item.endedAt ? item.endedAt.getTime() : Date.now()
    const recording = await loadRecording(props.eventId, item.startsAt, to, (n) => {
      progress.value = 'Loading ' + n.toLocaleString() + ' readings...'
    })
    return markRaw(recording) // large: keep it out of Vue's reactivity
  } catch (err) {
    errorMsg.value = err.message
    return null
  } finally {
    busyKey.value = null
    progress.value = ''
  }
}

async function play(item) {
  const recording = await fetchRecording(item)
  if (!recording) return
  infoMsg.value = ''
  player.value = { recording, version: 0, title: item.title, live: item.live, fileName: '', item }
  if (item.live) startLiveRefresh()
}

// Delete a finished recording for everyone (root / planners; the database checks it)
async function remove(item) {
  const what = item.readings ? item.readings.toLocaleString() + (item.readings === 1 ? ' reading' : ' readings') : 'This empty recording'
  const ok = await askConfirm({
    title: 'Delete this recording?',
    message:
      item.title + '. ' + what + (item.readings ? ' will be deleted for everyone.' : ' will be removed.') +
      " This can't be undone." + (item.readings ? ' Download a CSV first if you want to keep it.' : ''),
    confirmText: 'Delete recording',
    danger: true,
  })
  if (!ok) return
  busyKey.value = item.key
  const { data, error } = await supabase.rpc('delete_recording', {
    p_event_id: props.eventId,
    p_session_id: item.kind === 'session' ? item.key : null,
    p_day: item.kind === 'day' ? sgtParts(item.startsAt).date : null,
  })
  busyKey.value = null
  if (error) return toast(error.message, 'danger', 8000)
  toast('Recording deleted' + (data ? ' (' + data.toLocaleString() + (data === 1 ? ' reading).' : ' readings).') : '.'))
  loadList()
}

async function download(item) {
  const recording = player.value && player.value.item === item ? player.value.recording : await fetchRecording(item)
  if (!recording) return
  try {
    await downloadText(recordingToCsv(recording, props.eventName), csvFileName(props.eventName, recording.from, recording.to))
  } catch (e) {
    toast('The CSV file could not be saved: ' + (e && e.message ? e.message : e), 'danger', 8000)
  }
}

// ---------- Live rewind: keep adding new readings ----------
let liveTimer = null
const peopleFromMembers = computed(() => {
  const people = {}
  for (const m of props.members) people[m.id] = { name: m.display_name, username: m.username }
  return people
})

function startLiveRefresh() {
  clearInterval(liveTimer)
  liveTimer = setInterval(async () => {
    const p = player.value
    if (!p || !p.live) return
    try {
      const now = Date.now()
      const rows = await loadNewRows(props.eventId, p.recording.from, now, p.recording.maxId)
      addRows(p.recording, rows, peopleFromMembers.value)
      p.recording.to = now
      p.version++
    } catch {
      // try again next time
    }
  }, LIVE_REFRESH_MS)
}

function closePlayer() {
  clearInterval(liveTimer)
  player.value = null
  infoMsg.value = ''
  loadList()
}

function goLive() {
  closePlayer()
  emit('go-live')
}

// ---------- Replay from a CSV file ----------
const fileInput = ref(null)

async function openFile(event) {
  const file = event.target.files[0]
  event.target.value = '' // choosing the same file again still triggers
  if (!file) return
  errorMsg.value = ''
  infoMsg.value = ''
  try {
    const { recording, eventName, skipped } = csvToRecording(await file.text())
    const notes = []
    if (skipped) notes.push('Skipped ' + skipped + (skipped === 1 ? ' row' : ' rows') + " that couldn't be read.")
    if (eventName && eventName !== props.eventName) notes.push('This file is from the event "' + eventName + '".')
    infoMsg.value = notes.join(' ')
    player.value = {
      recording: markRaw(recording),
      version: 0,
      title: (eventName || 'Recording') + ': ' + itemTitle('session', new Date(recording.from), new Date(recording.to)),
      live: false,
      fileName: file.name,
      item: null,
    }
  } catch (err) {
    errorMsg.value = err.message
  }
}

watch(
  () => props.active,
  (active) => {
    if (active && !player.value) loadList()
  },
)
onMounted(loadList)
onUnmounted(() => clearInterval(liveTimer))
</script>

<template>
  <div data-testid="playback-panel">
    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="playback-error">{{ errorMsg }}</div>
    <div v-if="infoMsg" class="alert alert-warning py-2" role="status" data-testid="playback-info">{{ infoMsg }}</div>

    <PlaybackPlayer
      v-if="player"
      :key="player.title + player.fileName"
      :recording="player.recording"
      :version="player.version"
      :live="player.live"
      :title="player.title"
      :file-name="player.fileName"
      :can-download="!player.fileName"
      :active="active"
      @close="closePlayer"
      @go-live="goLive"
      @download="download(player.item)"
    />

    <template v-else>
      <p class="small text-muted">
        Recordings stay online until 11:59 pm, 7 days after the day they ended. Download a CSV to keep one longer.
      </p>
      <p v-if="loadingList && !items.length" class="text-muted small">Loading...</p>
      <p v-else-if="!items.length" class="text-muted small" data-testid="no-recordings">
        No recordings yet. They appear here once the event has been started and ICs share their location.
      </p>

      <ul class="list-group mb-3" data-testid="recording-list">
        <li v-for="item in items" :key="item.key" class="list-group-item" :data-testid="'recording-' + item.kind">
          <div class="d-flex flex-wrap align-items-center gap-2">
            <div class="flex-grow-1">
              <span v-if="item.live" class="badge text-bg-danger me-1">● Live</span>
              <strong>{{ item.title }}</strong>
              <div v-if="item.ranWith" class="small" data-testid="ran-with">Ran with: {{ item.ranWith }}</div>
              <div class="small text-muted">
                <template v-if="item.expired">Deleted after {{ untilText(item) }}. Replay it from your CSV file.</template>
                <template v-else>
                  {{ item.people }} {{ item.people === 1 ? 'person' : 'people' }} · {{ item.readings.toLocaleString() }} {{ item.readings === 1 ? 'reading' : 'readings' }}
                  <template v-if="item.availableUntil"> · available until {{ untilText(item) }}</template>
                  <template v-if="item.endReason === 'auto'"> · ended automatically (no uploads for 24 h)</template>
                </template>
                <span v-if="!item.expired && item.expiresSoon" class="badge text-bg-warning ms-1">Download to keep</span>
              </div>
            </div>
            <template v-if="!item.expired">
              <span v-if="busyKey === item.key" class="small text-muted">{{ progress }}</span>
              <button
                class="btn btn-sm"
                :class="item.live ? 'btn-outline-danger' : 'btn-primary'"
                :disabled="busyKey !== null || item.readings === 0"
                data-testid="play-recording-btn"
                @click="play(item)"
              >
                {{ item.live ? 'Rewind' : '▶ Play' }}
              </button>
              <button
                v-if="!item.live"
                class="btn btn-sm btn-outline-secondary"
                :disabled="busyKey !== null || item.readings === 0"
                data-testid="download-csv-btn"
                @click="download(item)"
              >
                Download CSV
              </button>
            </template>
            <button
              v-if="!item.live"
              class="btn btn-sm btn-outline-danger"
              :disabled="busyKey !== null"
              title="Delete this recording"
              data-testid="delete-recording-btn"
              @click="remove(item)"
            >
              Delete
            </button>
          </div>
        </li>
      </ul>

      <div class="card">
        <div class="card-body py-2">
          <h3 class="h6 mb-1">Replay from a CSV file</h3>
          <p class="small text-muted mb-2">For recordings older than 7 days. The file is read on this computer, not uploaded.</p>
          <input ref="fileInput" type="file" accept=".csv,text/csv" class="form-control form-control-sm" data-testid="csv-input" @change="openFile" />
        </div>
      </div>
    </template>
  </div>
</template>
