<script setup>
// Playback tab (root and planners only; the database checks this too).
// Lists the event's recordings, newest first:
//   - the live session (Rewind: replay up to now, then back to the live map)
//   - finished sessions (Start -> End), kept online until 23:59 seven days after the day they ended
//   - days with readings from before Start/End existed
// Each can be played or downloaded as CSV. After the 7 days, a downloaded CSV can be replayed
// here: the file is read in the browser and never uploaded.
import { ref, computed, watch, markRaw, nextTick, onMounted, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { loadRecording, loadNewRows } from '../composables/usePlaybackHistory'
import { addRows, recordingToCsv, csvToRecording, csvFileName, downloadText } from '../utils/playback'
import { formatTime, formatDay, formatDayTime, sgtParts } from '../utils/time'
import { askConfirm, toast } from '../composables/useNotify'
import PlaybackPlayer from './PlaybackPlayer.vue'
import SkeletonLoader from './SkeletonLoader.vue'
import EmptyState from './EmptyState.vue'
import { useLoadGate } from '../composables/usePageReady'
import { useOpenMenu } from '../composables/useOpenMenu'

const props = defineProps({
  eventId: { type: String, required: true },
  eventName: { type: String, default: '' },
  members: { type: Array, default: () => [] }, // names for people who start sharing during a live rewind
  active: { type: Boolean, default: true }, // tab visible
  // The event page's live session id: the Live badge shows only on that session's recording, and only while it is live
  liveSessionId: { type: String, default: null },
})
const emit = defineEmits(['go-live'])

const LIVE_REFRESH_MS = 30000 // live rewind: fetch new readings every 30 s (phones send every 30 s)
const DAY_MS = 24 * 3600 * 1000

const items = ref([])
const loadingList = ref(false)
// Until its first answer, this holds the event page's one-shot skeleton (usePageReady)
useLoadGate(() => loadingList.value)
const errorMsg = ref('')
const infoMsg = ref('')
const busyKey = ref(null) // which item is loading
const progress = ref('')
const player = ref(null) // { recording, version, title, live, fileName, item }

// ---------- List ----------
async function loadList() {
  loadingList.value = true
  const [{ data, error }, named] = await Promise.all([
    supabase.rpc('playback_list', { p_event_id: props.eventId }),
    supabase.from('recording_names').select('key, name').eq('event_id', props.eventId),
  ])
  loadingList.value = false
  const names = Object.fromEntries(((named && named.data) || []).map((n) => [n.key, n.name]))
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
      nameKey: row.session_id || 'day-' + sgtParts(startsAt).date, // what a name is kept under (086)
      name: names[row.session_id || 'day-' + sgtParts(startsAt).date] || '',
      timesTitle: itemTitle(row.kind, startsAt, endedAt),
      title: names[row.session_id || 'day-' + sgtParts(startsAt).date] || itemTitle(row.kind, startsAt, endedAt),
    }
  })
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

// Rename a recording (root / planners, rename_recording 086). An empty name puts the times back.
const renamingKey = ref(null)
const renameText = ref('')
function startRename(item) {
  renamingKey.value = item.key
  renameText.value = item.name
  nextTick(() => {
    const el = document.querySelector('[data-testid="rename-recording-input"]')
    if (el) el.focus()
  })
}
async function saveRename(item) {
  if (renamingKey.value !== item.key) return
  const name = renameText.value.trim()
  renamingKey.value = null
  if (name === item.name) return
  const { error } = await supabase.rpc('rename_recording', { p_event_id: props.eventId, p_key: item.nameKey, p_name: name })
  if (error) return toast(error.message, 'danger', 8000)
  toast(name ? 'Recording renamed.' : 'Recording name cleared.', 'success', 3000)
  loadList()
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
const { openMenu, toggleMenu, closeMenu } = useOpenMenu()
onUnmounted(() => clearInterval(liveTimer))
</script>

<template>
  <div class="kp-stack" data-testid="playback-panel">
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
      :event-id="eventId"
      @close="closePlayer"
      @go-live="goLive"
      @download="download(player.item)"
    />

    <template v-else>
      <div class="k k2-h" style="margin-bottom: 0">
        <h1>Playback</h1>
        <span v-if="items.length" class="cnt">{{ items.length }}</span>
        <span class="sp"></span>
        <span class="mut" style="font-size: 13px; font-weight: 700">Recordings are kept for 7 days</span>
      </div>

      <section class="k k2-card">
        <SkeletonLoader v-if="loadingList && !items.length" :rows="3" label="Loading recordings…" />
        <EmptyState v-else-if="!items.length" compact icon="play" title="No recordings yet" text="Each time the event runs, a recording appears here." data-testid="no-recordings" />

        <div data-testid="recording-list">
          <div v-for="item in items" :key="item.key" class="k2-rec" :data-testid="'recording-' + item.kind">
            <button
              v-if="!item.expired"
              type="button"
              class="rp-play"
              :disabled="busyKey !== null || item.readings === 0"
              :aria-label="item.live ? 'Rewind' : 'Play'"
              :title="item.readings === 0 ? 'Nothing to play — no readings' : item.live ? 'Rewind' : 'Play'"
              data-testid="play-recording-btn"
              @click="play(item)"
            >
              <svg v-if="item.live" class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M11 17 6 12l5-5M18 17l-5-5 5-5"></path></svg>
              <svg v-else class="ki" viewBox="0 0 24 24" aria-hidden="true" style="fill: currentColor; stroke: none"><path d="M7 4.5v15l12-7.5z"></path></svg>
            </button>
            <span v-else></span>
            <div style="min-width: 0">
              <div class="row" style="gap: 8px; flex-wrap: wrap">
                <span v-if="item.live && item.key === liveSessionId" class="chip chip-ink" style="height: 22px"><i class="dot pulse" style="background: var(--lime)"></i>Live</span>
                <form v-if="renamingKey === item.key" class="row" style="gap: 6px; flex-wrap: nowrap" @submit.prevent="saveRename(item)">
                  <label class="visually-hidden" :for="'rec-name-' + item.key">Recording name</label>
                  <input :id="'rec-name-' + item.key" v-model="renameText" class="kin" style="min-width: 0; width: 260px; max-width: 100%" maxlength="80" :placeholder="item.timesTitle" data-testid="rename-recording-input" @keydown.esc.prevent="renamingKey = null" />
                  <button type="submit" class="kb kb-ink kb-sm" data-testid="rename-recording-save">Save</button>
                  <button type="button" class="kb kb-line kb-sm" @click="renamingKey = null">Cancel</button>
                </form>
                <b v-else>{{ item.title }}</b>
                <span v-if="renamingKey !== item.key && item.name" class="mut" style="font-size: 12px">{{ item.timesTitle }}</span>
                <span v-if="!item.expired && item.expiresSoon" class="chip chip-warn" style="height: 22px">Download to keep</span>
              </div>
              <div class="mut" style="font-size: 13px">
                <template v-if="item.expired">Deleted after {{ untilText(item) }}. Replay it from your CSV.</template>
                <template v-else>
                  {{ item.people }} {{ item.people === 1 ? 'person' : 'people' }} · {{ item.readings.toLocaleString() }} {{ item.readings === 1 ? 'reading' : 'readings' }}
                  <template v-if="item.endReason === 'auto'"> · ended automatically</template>
                  <template v-if="busyKey === item.key"> · {{ progress }}</template>
                </template>
              </div>
            </div>
            <span class="mut k2-hm" style="font-size: 13px"><template v-if="!item.expired && item.availableUntil">Until {{ untilText(item) }}</template></span>
            <button
              v-if="!item.live && !item.expired"
              type="button"
              class="ib"
              :disabled="busyKey !== null || item.readings === 0"
              aria-label="Download this recording as a CSV file"
              data-testid="download-csv-btn"
              title="Download this recording as a CSV file"
              @click="download(item)"
            ><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v12M7 11l5 5 5-5M4 20h16"></path></svg></button>
            <span v-else></span>
            <div v-if="!item.live" class="wrapm" data-menu>
              <button type="button" class="ib" aria-label="Recording options" :aria-expanded="openMenu === item.key ? 'true' : 'false'" data-testid="recording-menu" @click="toggleMenu(item.key)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true" style="stroke-width: 3"><path d="M5 12h.01M12 12h.01M19 12h.01"></path></svg></button>
              <div v-if="openMenu === item.key" class="menu r" role="menu">
                <button type="button" role="menuitem" :disabled="busyKey !== null" data-testid="rename-recording-btn" @click="closeMenu(); startRename(item)">Rename</button>
                <button type="button" role="menuitem" class="danger" :disabled="busyKey !== null" data-testid="delete-recording-btn" @click="closeMenu(); remove(item)">Delete recording</button>
              </div>
            </div>
            <span v-else></span>
          </div>
        </div>
        <p class="k2-hint">Download a CSV to keep one longer.</p>
      </section>

      <section class="k k2-card">
        <div class="k2-sub">Replay a CSV</div>
        <input ref="fileInput" type="file" accept=".csv,text/csv" class="form-control" aria-label="CSV file to replay" data-testid="csv-input" @change="openFile" />
        <p class="k2-hint">The file stays on this device.</p>
      </section>
    </template>
  </div>
</template>
