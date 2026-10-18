// useRunSheets - an event's run sheet versions (merger Stage 4, 024_run_sheets.sql).
//
//   useRunSheetList(eventId)      the versions (name, date, status draft / ready / used, live, scheduled),
//                                  kept up to date; used by the Run sheet tab and the Start / Schedule picker.
//   useRunSheet(sheetIdRef)       one version's cues, movements and check results, kept up to date.
//
// Everything is written through the database functions, which check the role, the lock (a used version is
// read-only) and the values; this file only reads, calls them and reloads.
import { ref, computed, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

function channelName(prefix, id) {
  return prefix + '-' + id + '-' + Math.random().toString(36).slice(2) // unique (see useEventData.js)
}

// ---------- The versions of an event ----------
export function useRunSheetList(eventId, enabledRef) {
  // enabledRef: true once I am known to be root / planner / marshal (others are refused, so don't ask)
  const sheets = ref([])
  const loaded = ref(false)
  const errorMsg = ref('')
  let timer = null
  let channel = null

  async function load() {
    if (enabledRef && !enabledRef.value) return
    const { data, error } = await supabase.rpc('run_sheet_list', { p_event: eventId })
    if (error) {
      errorMsg.value = error.message
      loaded.value = true
      return
    }
    errorMsg.value = ''
    sheets.value = (data || []).map((s) => ({
      id: s.id,
      name: s.name,
      forDate: s.for_date, // 'YYYY-MM-DD' or null
      status: s.status, // draft | ready | used
      usedOn: s.used_on ? new Date(s.used_on) : null,
      scheduledAt: s.scheduled_at ? new Date(s.scheduled_at) : null,
      live: s.live,
      cueCount: s.cue_count,
      movementCount: s.movement_count,
      rev: s.rev,
    }))
    loaded.value = true
  }
  function reloadSoon() {
    clearTimeout(timer)
    timer = setTimeout(load, 300)
  }

  // A version can run when it is Ready, or Used (a record of an order that already ran)
  const runnable = computed(() => sheets.value.filter((s) => s.status !== 'draft'))

  // The version to suggest when starting: dated today, else a Ready one with no date or a date still to come, else none
  // (a past rehearsal's version is never suggested: on show night that would start the wrong plan).
  const suggested = computed(() => {
    const today = isoDate(new Date())
    const list = runnable.value
    return (
      list.find((s) => s.forDate === today && s.status === 'ready') ||
      list.find((s) => s.forDate === today) ||
      list.find((s) => s.status === 'ready' && (!s.forDate || s.forDate >= today)) ||
      null
    )
  })

  function start() {
    if (channel) return
    load()
    channel = supabase
      .channel(channelName('run-sheets', eventId))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'run_sheets', filter: 'event_id=eq.' + eventId }, reloadSoon)
      // A start, end or switch changes which version is used / live
      .on('postgres_changes', { event: '*', schema: 'public', table: 'event_sessions', filter: 'event_id=eq.' + eventId }, reloadSoon)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }
  function stop() {
    if (channel) supabase.removeChannel(channel)
    channel = null
    sheets.value = []
    loaded.value = false
  }
  if (!enabledRef) start()
  else watch(enabledRef, (on) => (on ? start() : stop()), { immediate: true })

  onUnmounted(() => {
    clearTimeout(timer)
    if (channel) supabase.removeChannel(channel)
  })

  return { sheets, loaded, errorMsg, runnable, suggested, load }
}

// ---------- One version ----------
export function useRunSheet(sheetIdRef) {
  const cues = ref([])
  const movements = ref([])
  const problems = ref([]) // { severity: error|warning, itemType, itemId, message }
  const loading = ref(false)
  const errorMsg = ref('')
  let channel = null
  let timer = null
  let loadSeq = 0

  async function load() {
    const id = sheetIdRef.value
    if (!id) {
      cues.value = []
      movements.value = []
      problems.value = []
      return
    }
    const seq = ++loadSeq
    loading.value = true
    const [c, m, p] = await Promise.all([
      supabase.from('cues').select('*').eq('run_sheet_id', id).order('position'),
      supabase.from('movements').select('*').eq('run_sheet_id', id).order('code'),
      supabase.rpc('check_run_sheet', { p_sheet: id }),
    ])
    if (seq !== loadSeq) return // a newer load (another version picked) has started
    loading.value = false
    const failed = [c, m, p].find((r) => r.error)
    if (failed) {
      errorMsg.value = failed.error.message
      return
    }
    errorMsg.value = ''
    cues.value = c.data
    // M2 before M10, M99 before M100
    movements.value = m.data.sort((a, b) => a.code.localeCompare(b.code, undefined, { numeric: true }))
    problems.value = (p.data || []).map((x) => ({ severity: x.severity, itemType: x.item_type, itemId: x.item_id, message: x.message }))
  }
  function reloadSoon() {
    clearTimeout(timer)
    timer = setTimeout(load, 250)
  }

  function subscribe(id) {
    if (channel) supabase.removeChannel(channel)
    channel = null
    if (!id) return
    channel = supabase
      .channel(channelName('run-sheet', id))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'cues', filter: 'run_sheet_id=eq.' + id }, reloadSoon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'movements', filter: 'run_sheet_id=eq.' + id }, reloadSoon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'run_sheets', filter: 'id=eq.' + id }, reloadSoon)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }

  watch(sheetIdRef, (id) => {
    cues.value = []
    movements.value = []
    problems.value = []
    load()
    subscribe(id)
  }, { immediate: true })

  onUnmounted(() => {
    clearTimeout(timer)
    if (channel) supabase.removeChannel(channel)
  })

  // Problems by the row they are about
  const problemsFor = computed(() => {
    const map = {}
    for (const p of problems.value) (map[p.itemId] = map[p.itemId] || []).push(p)
    return map
  })
  const errorCount = computed(() => problems.value.filter((p) => p.severity === 'error').length)
  const warningCount = computed(() => problems.value.filter((p) => p.severity === 'warning').length)

  return { cues, movements, problems, problemsFor, errorCount, warningCount, loading, errorMsg, load }
}

// ---------- Excel (Stage 5): ExcelJS is large, so it is loaded only when a file is read or made ----------
export const loadExcel = () => import('exceljs').then((m) => m.default || m)

// ---------- Calls (each returns { data } or { error: message }) ----------
export async function rsCall(fn, args) {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) return { error: error.message, stale: error.code === 'PT409' } // someone else saved it first (409)
  return { data }
}

// ---------- Time helpers ----------
export function isoDate(d) {
  const z = (n) => String(n).padStart(2, '0')
  return d.getFullYear() + '-' + z(d.getMonth() + 1) + '-' + z(d.getDate())
}

// 'YYYY-MM-DD' -> 'Sat 19 Jul'
export function dayLabel(iso) {
  if (!iso) return ''
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString('en-SG', { weekday: 'short', day: 'numeric', month: 'short' })
}

// seconds -> 'm:ss' (or 'h:mm:ss' from an hour)
export function formatLength(s) {
  const n = Math.max(0, Math.round(Number(s) || 0))
  const h = Math.floor(n / 3600)
  const m = Math.floor((n % 3600) / 60)
  const sec = String(n % 60).padStart(2, '0')
  return h ? h + ':' + String(m).padStart(2, '0') + ':' + sec : m + ':' + sec
}

// 'm:ss', 'h:mm:ss', or plain seconds -> seconds; null when it cannot be read
export function parseLength(text) {
  const t = String(text ?? '').trim()
  if (t === '') return 0
  if (/^\d+$/.test(t)) return Number(t)
  const parts = t.split(':')
  if (parts.length < 2 || parts.length > 3 || parts.some((p) => !/^\d+$/.test(p))) return null
  const nums = parts.map(Number)
  if (nums.slice(1).some((n) => n > 59)) return null
  return parts.length === 2 ? nums[0] * 60 + nums[1] : nums[0] * 3600 + nums[1] * 60 + nums[2]
}

// '17:30:00' + seconds -> '17:40:00' (wraps after midnight)
export function addSeconds(time, s) {
  const [h, m, sec] = String(time || '00:00:00').split(':').map(Number)
  const total = (h * 3600 + m * 60 + (sec || 0) + Number(s || 0)) % 86400
  const z = (n) => String(n).padStart(2, '0')
  return z(Math.floor(total / 3600)) + ':' + z(Math.floor((total % 3600) / 60)) + ':' + z(total % 60)
}

// 'Rehearsal 1' -> 'Rehearsal 2'; 'NDP Day' -> 'NDP Day 2'; never one that is taken
export function nextName(name, taken) {
  const used = new Set((taken || []).map((t) => t.trim().toLowerCase()))
  const m = String(name || 'Version').trim().match(/^(.*?)(\d+)$/)
  let stem = m ? m[1] : String(name || 'Version').trim() + ' '
  let n = m ? Number(m[2]) + 1 : 2
  while (used.has((stem + n).toLowerCase())) n += 1
  return (stem + n).slice(0, 60)
}
