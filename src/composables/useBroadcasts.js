// useBroadcasts - "Message everyone" (032_broadcasts.sql). One planner message to many people at once: everyone in the
// event, every group, all ICs, the staff, one sector or one category. Recipients see it as a banner on the event page
// (and a push) until they press Got it or a planner clears it; root and planners see who has and has not seen it.
//
//   mine      messages to me that are still up: [{ id, body, urgent, from, at: Date, seen, acked }], newest first
//   sent      this event's messages of the last 24 h (staff only): [{ id, body, urgent, from, at, audience, value, cleared }]
//   send({ audience, value, body, urgent, dry })  -> { recipients, id } or { error }
//   ack(id), markSeen(id), clear(id), status(id) -> { total, seen, acked, waiting: [{ name, group, radio, ic, seen }] }
import { ref, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export const AUDIENCES = [
  { value: 'everyone', label: 'Everyone in the event' },
  { value: 'groups', label: "Every group's members" },
  { value: 'ics', label: 'ICs and group admins' },
  { value: 'staff', label: 'Planners and marshals' },
  { value: 'sector', label: 'One sector…' },
  { value: 'category', label: 'One category…' },
]

// "everyone" / "sector North" / "every Contingent group": how a message's audience is said back
export function audienceText(audience, value) {
  if (audience === 'sector') return 'sector ' + value
  if (audience === 'category') return 'every ' + value + ' group'
  const a = AUDIENCES.find((x) => x.value === audience)
  return a ? a.label.toLowerCase() : audience
}

const DAY = 24 * 60 * 60 * 1000
const STILL_UP = 12 * 60 * 60 * 1000 // a message older than this no longer shows as a banner

export function useBroadcasts(eventIdRef, { myUserIdRef, staffRef, onNew } = {}) {
  const mine = ref([])
  const sent = ref([])
  const busy = ref(false)
  let channel = null

  async function loadMine() {
    const eid = eventIdRef.value
    const uid = myUserIdRef ? myUserIdRef.value : null
    if (!eid || !uid) {
      mine.value = []
      return
    }
    const { data, error } = await supabase
      .from('broadcasts')
      .select('id, body, urgent, from_name, at, broadcast_recipients!inner(user_id, seen_at, acked_at)')
      .eq('event_id', eid)
      .eq('broadcast_recipients.user_id', uid)
      .is('cleared_at', null)
      .gte('at', new Date(Date.now() - STILL_UP).toISOString())
      .order('at', { ascending: false })
      .limit(10)
    if (error || eid !== eventIdRef.value) return
    mine.value = (data || [])
      .map((b) => {
        const r = (b.broadcast_recipients || [])[0] || {}
        return { id: b.id, body: b.body, urgent: b.urgent, from: b.from_name || 'A planner', at: new Date(b.at), seen: !!r.seen_at, acked: !!r.acked_at }
      })
      .filter((b) => !b.acked)
  }

  async function loadSent() {
    const eid = eventIdRef.value
    if (!eid || !(staffRef && staffRef.value)) {
      sent.value = []
      return
    }
    const { data, error } = await supabase
      .from('broadcasts')
      .select('id, body, urgent, from_name, at, audience, audience_value, cleared_at')
      .eq('event_id', eid)
      .gte('at', new Date(Date.now() - DAY).toISOString())
      .order('at', { ascending: false })
      .limit(10)
    if (error || eid !== eventIdRef.value) return
    sent.value = (data || []).map((b) => ({
      id: b.id,
      body: b.body,
      urgent: b.urgent,
      from: b.from_name || 'A planner',
      at: new Date(b.at),
      audience: b.audience,
      value: b.audience_value,
      cleared: !!b.cleared_at,
    }))
  }

  const load = () => Promise.all([loadMine(), loadSent()])

  function subscribe() {
    if (channel) supabase.removeChannel(channel)
    channel = null
    const eid = eventIdRef.value
    const uid = myUserIdRef ? myUserIdRef.value : null
    if (!eid) return
    channel = supabase.channel('broadcasts-' + eid + '-' + Math.random().toString(36).slice(2))
    if (uid) {
      // a new message to me (my receipt row is created with it), or Got it pressed on my other device
      channel.on('postgres_changes', { event: '*', schema: 'public', table: 'broadcast_recipients', filter: 'user_id=eq.' + uid }, async (payload) => {
        await loadMine()
        if (payload.eventType !== 'INSERT') return
        const b = mine.value.find((x) => payload.new && x.id === payload.new.broadcast_id)
        if (b && onNew) onNew(b)
      })
    }
    // sent (staff) or cleared by a planner (everyone it reached)
    channel
      .on('postgres_changes', { event: '*', schema: 'public', table: 'broadcasts', filter: 'event_id=eq.' + eid }, () => load())
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }

  async function markSeen(id) {
    const b = mine.value.find((x) => x.id === id)
    if (!b || b.seen) return
    b.seen = true
    await supabase.rpc('broadcast_mark', { p_id: id, p_ack: false })
  }

  async function ack(id) {
    mine.value = mine.value.filter((x) => x.id !== id)
    const { error } = await supabase.rpc('broadcast_mark', { p_id: id, p_ack: true })
    return error ? error.message : ''
  }

  async function send({ audience, value, body, urgent, dry = false }) {
    busy.value = true
    const { data, error } = await supabase.rpc('broadcast_send', {
      p_event: eventIdRef.value,
      p_audience: audience,
      p_value: value || null,
      p_body: body,
      p_urgent: !!urgent,
      p_dry: dry,
    })
    busy.value = false
    if (error) return { error: error.message }
    if (!dry) loadSent()
    return { recipients: data.recipients, id: data.id }
  }

  async function clear(id) {
    const { error } = await supabase.rpc('broadcast_clear', { p_id: id })
    if (!error) await loadSent()
    return error ? error.message : ''
  }

  async function status(id) {
    const { data, error } = await supabase.rpc('broadcast_status', { p_id: id })
    return error ? { error: error.message } : data
  }

  watch(
    () => [eventIdRef.value, myUserIdRef ? myUserIdRef.value : null],
    () => subscribe(),
    { immediate: true },
  )
  if (staffRef) watch(staffRef, loadSent)
  onUnmounted(() => {
    if (channel) supabase.removeChannel(channel)
  })

  return { mine, sent, busy, load, send, ack, markSeen, clear, status }
}
