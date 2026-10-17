// useGroupMessages - messages from the ops view to my group (merger Stage 7, group_messages): "Please head to
// FORMATION_1 now". The group's admins and ICs see the newest one on the event page while the event is live, and a
// toast when it arrives. (A push when the app is closed comes with Stage 8.)
import { ref, watch, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'

export function useGroupMessages(groupIdRef, sessionIdRef, { onMessage } = {}) {
  const latest = ref(null) // { id, body, at: Date, from }
  let channel = null

  async function load() {
    const gid = groupIdRef.value
    const sid = sessionIdRef.value
    if (!gid || !sid) {
      latest.value = null
      return
    }
    const { data, error } = await supabase
      .from('group_messages')
      .select('id, body, at, from_name')
      .eq('group_id', gid)
      .eq('session_id', sid)
      .order('at', { ascending: false })
      .limit(1)
    if (error || gid !== groupIdRef.value) return
    const row = (data || [])[0]
    latest.value = row ? toMessage(row) : null
  }

  function toMessage(row) {
    return { id: row.id, body: row.body, at: new Date(row.at), from: row.from_name || 'A planner' }
  }

  function subscribe(gid) {
    if (channel) supabase.removeChannel(channel)
    channel = null
    if (!gid) return
    channel = supabase
      .channel('group-messages-' + gid + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'group_messages', filter: 'group_id=eq.' + gid }, async (payload) => {
        if (!payload.new || payload.new.session_id !== sessionIdRef.value) return
        await load()
        if (latest.value && latest.value.id === payload.new.id && onMessage) onMessage(latest.value)
      })
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })
  }

  watch(groupIdRef, subscribe, { immediate: true })
  watch(sessionIdRef, load)
  onUnmounted(() => {
    if (channel) supabase.removeChannel(channel)
  })

  return { latest, reload: load }
}
