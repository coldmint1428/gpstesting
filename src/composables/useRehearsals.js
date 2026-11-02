// useRehearsals - an event's rehearsal times (079), and which one is next.
// Everyone in the event reads them; the database lets only the root and planners add or remove one.
import { computed, onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'

const TICK_MS = 30000 // "next" moves on when a rehearsal's time passes

export function useRehearsals(eventId) {
  const rehearsals = ref([]) // soonest first: { id, startsAt: Date }
  const errorMsg = ref('')
  const busy = ref(false)
  const now = ref(Date.now())

  const next = computed(() => rehearsals.value.find((r) => r.startsAt.getTime() > now.value) || null)

  async function load() {
    const { data, error } = await supabase
      .from('event_rehearsals')
      .select('id, starts_at')
      .eq('event_id', eventId)
      .order('starts_at')
    if (error) {
      errorMsg.value = 'Could not load the rehearsals.'
      return
    }
    errorMsg.value = ''
    now.value = Date.now()
    rehearsals.value = data.map((r) => ({ id: r.id, startsAt: new Date(r.starts_at) }))
  }

  function messageOf(error) {
    if (error.code === '23505') return 'There is already a rehearsal at that time.'
    if (error.code === '42501') return 'Only the root and planners can schedule a rehearsal, and only in the future.'
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
  const add = (date) => write(supabase.from('event_rehearsals').insert({ event_id: eventId, starts_at: new Date(date).toISOString() }))
  const remove = (id) => write(supabase.from('event_rehearsals').delete().eq('id', id))

  const channel = supabase
    .channel('event-rehearsals-' + eventId + '-' + Math.random().toString(36).slice(2)) // unique name (see useEventData.js)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'event_rehearsals', filter: 'event_id=eq.' + eventId }, load)
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') load() // (re)connected: nothing missed
    })
  load()

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
    supabase.removeChannel(channel)
  })

  return { rehearsals, next, errorMsg, busy, now, add, remove }
}
