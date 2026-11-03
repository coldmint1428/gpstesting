// useRehearsals - an event's rehearsals (079, 080), which one is next, and "not available" requests.
// Everyone in the event reads the rehearsals; the database lets only the root and planners add or remove one. A person
// reads their own requests and the root and planners read everyone's, so `absences` holds whatever this person may see.
import { computed, onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'

const TICK_MS = 30000 // "next" moves on when a rehearsal's time passes

export function useRehearsals(eventId, myUserIdRef = null) {
  const rehearsals = ref([]) // soonest first: { id, startsAt: Date, endsAt: Date|null, note }
  const absences = ref([]) // { id, rehearsalId, userId, reason, status, decidedBy, decidedAt: Date|null, createdAt: Date }
  const errorMsg = ref('')
  const busy = ref(false)
  const now = ref(Date.now())

  // The next rehearsal this person is expected at: one they have been excused from is not "next" for them
  const excused = (r) => !!myUserIdRef && absences.value.some((a) => a.rehearsalId === r.id && a.userId === myUserIdRef.value && a.status === 'approved')
  const next = computed(() => rehearsals.value.find((r) => r.startsAt.getTime() > now.value && !excused(r)) || null)

  async function load() {
    const [times, requests] = await Promise.all([
      supabase.from('event_rehearsals').select('id, starts_at, ends_at, note').eq('event_id', eventId).order('starts_at'),
      supabase
        .from('rehearsal_absences')
        .select('id, rehearsal_id, user_id, reason, status, decided_by, decided_at, created_at')
        .eq('event_id', eventId),
    ])
    if (times.error || requests.error) {
      errorMsg.value = 'Could not load the rehearsals.'
      return
    }
    errorMsg.value = ''
    now.value = Date.now()
    rehearsals.value = times.data.map((r) => ({
      id: r.id,
      startsAt: new Date(r.starts_at),
      endsAt: r.ends_at ? new Date(r.ends_at) : null,
      note: r.note || '',
    }))
    absences.value = requests.data.map((a) => ({
      id: a.id,
      rehearsalId: a.rehearsal_id,
      userId: a.user_id,
      reason: a.reason,
      status: a.status,
      decidedBy: a.decided_by,
      decidedAt: a.decided_at ? new Date(a.decided_at) : null,
      createdAt: new Date(a.created_at),
    }))
  }

  function messageOf(error) {
    if (error.code === '23505') return 'There is already a rehearsal at that time.'
    if (error.code === '23514') return 'The end time must be after the start, and notes can be up to 500 characters.'
    if (error.code === '42501' && !error.message.includes('.')) return 'Only the root and planners can schedule a rehearsal, and only in the future.'
    return error.message
  }

  // Each write answers its error in words ('' when it worked), then reads the list back
  async function write(request) {
    busy.value = true
    try {
      const { error } = await request
      if (error) return messageOf(error)
      await load()
      return ''
    } finally {
      busy.value = false
    }
  }
  const add = ({ startsAt, endsAt, note }) =>
    write(
      supabase.from('event_rehearsals').insert({
        event_id: eventId,
        starts_at: new Date(startsAt).toISOString(),
        ends_at: endsAt ? new Date(endsAt).toISOString() : null,
        note: note || null,
      }),
    )
  // Change one (085): the time, the end and the note. Its absence requests stay attached.
  const update = (id, { startsAt, endsAt, note }) =>
    write(
      supabase.rpc('update_rehearsal', {
        p_id: id,
        p_starts_at: new Date(startsAt).toISOString(),
        p_ends_at: endsAt ? new Date(endsAt).toISOString() : null,
        p_note: note || null,
      }),
    )
  const remove = (id) => write(supabase.from('event_rehearsals').delete().eq('id', id))
  const requestAbsence = (rehearsalId, reason) => write(supabase.rpc('rehearsal_absence_request', { p_rehearsal: rehearsalId, p_reason: reason }))
  const withdrawAbsence = (rehearsalId) => write(supabase.rpc('rehearsal_absence_withdraw', { p_rehearsal: rehearsalId }))
  const decideAbsence = (id, approve) => write(supabase.rpc('rehearsal_absence_decide', { p_id: id, p_approve: approve }))

  load() // the calendar once: the page's badge and the "Next rehearsal" line need it before any tab is opened

  // The Realtime channel opens the first time the Rehearsals tab is shown, not when the event page opens: most visits
  // never look at the calendar, and a channel per event page is a cost on a phone. `start` is safe to call twice.
  let channel = null
  function start() {
    if (channel) return
    channel = supabase
      .channel('event-rehearsals-' + eventId + '-' + Math.random().toString(36).slice(2)) // unique name (see useEventData.js)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'event_rehearsals', filter: 'event_id=eq.' + eventId }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rehearsal_absences', filter: 'event_id=eq.' + eventId }, load)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load() // (re)connected: nothing missed
      })
  }

  const timer = setInterval(() => {
    now.value = Date.now()
  }, TICK_MS)
  function onVisible() {
    if (!document.hidden) load()
  }
  document.addEventListener('visibilitychange', onVisible)

  onUnmounted(() => {
    clearInterval(timer)
    document.removeEventListener('visibilitychange', onVisible)
    if (channel) supabase.removeChannel(channel)
  })

  return { rehearsals, absences, next, errorMsg, busy, now, add, update, remove, requestAbsence, withdrawAbsence, decideAbsence, start }
}
