// useEventData - loads one event: its groups, members (with roles) and what *I* am allowed to do.
// Everything here is also enforced by the database (RLS + functions); the computed
// "can..." values only decide which buttons to show.
import { ref, computed, onUnmounted } from 'vue'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'

export function useEventData(eventId) {
  const auth = useAuthStore()

  const event = ref(null) // { id, name, join_code }
  const groups = ref([]) // [{ id, name, colour }]
  const members = ref([]) // [{ id, username, display_name, roles, groupId, isAdmin, isIC }]
  const loading = ref(true)
  const errorMsg = ref('')

  async function load() {
    errorMsg.value = ''
    // Run the 4 queries at the same time
    const [ev, gr, roles, gm] = await Promise.all([
      supabase.from('events').select('id, name, join_code').eq('id', eventId).maybeSingle(),
      supabase.from('groups').select('id, name, colour').eq('event_id', eventId).order('created_at'),
      supabase.from('event_roles').select('user_id, role, profiles (username, display_name)').eq('event_id', eventId),
      supabase.from('group_members').select('group_id, user_id, is_admin, is_ic').eq('event_id', eventId),
    ])
    loading.value = false

    const failed = [ev, gr, roles, gm].find((r) => r.error)
    if (failed) {
      errorMsg.value = failed.error.message
      return
    }
    if (!ev.data) {
      errorMsg.value = 'Event not found, or you are not a member.'
      return
    }

    event.value = ev.data
    groups.value = gr.data

    // Merge role rows + group rows into one entry per person
    const byId = {}
    for (const row of roles.data) {
      if (!byId[row.user_id]) {
        byId[row.user_id] = {
          id: row.user_id,
          username: row.profiles.username,
          display_name: row.profiles.display_name,
          roles: [],
          groupId: null,
          isAdmin: false,
          isIC: false,
        }
      }
      byId[row.user_id].roles.push(row.role)
    }
    for (const row of gm.data) {
      const m = byId[row.user_id]
      if (m) {
        m.groupId = row.group_id
        m.isAdmin = row.is_admin
        m.isIC = row.is_ic
      }
    }
    members.value = Object.values(byId).sort((a, b) => a.display_name.localeCompare(b.display_name))
  }

  // ---------- What can I do? ----------
  const me = computed(() => members.value.find((m) => auth.user && m.id === auth.user.id) || null)
  const myRoles = computed(() => (me.value ? me.value.roles : []))
  const isRoot = computed(() => myRoles.value.includes('root'))
  const canManage = computed(() => isRoot.value || myRoles.value.includes('planner')) // root or planner
  const seesWholeEvent = computed(() => canManage.value || myRoles.value.includes('marshal'))
  const myGroup = computed(() => (me.value ? groups.value.find((g) => g.id === me.value.groupId) || null : null))
  const amAdminOf = (groupId) => !!(me.value && me.value.isAdmin && me.value.groupId === groupId)

  function groupById(groupId) {
    return groups.value.find((g) => g.id === groupId) || null
  }

  // ---------- Live refresh when members/groups change ----------
  // Note: Supabase Realtime does not deliver filtered DELETE events, so we also
  // reload after every action we make ourselves.
  let reloadTimer = null
  function reloadSoon() {
    clearTimeout(reloadTimer)
    reloadTimer = setTimeout(load, 300) // several changes at once = one reload
  }
  const channel = supabase
    // Unique name per page: supabase.channel() returns an EXISTING channel with the same name,
    // and adding listeners to an already-subscribed channel throws (blank page when switching pages)
    .channel('event-members-' + eventId + '-' + Math.random().toString(36).slice(2))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'group_members', filter: 'event_id=eq.' + eventId }, reloadSoon)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'event_roles', filter: 'event_id=eq.' + eventId }, reloadSoon)
    .subscribe()

  onUnmounted(() => {
    clearTimeout(reloadTimer)
    supabase.removeChannel(channel)
  })

  load()

  return {
    event,
    groups,
    members,
    loading,
    errorMsg,
    load,
    me,
    myRoles,
    isRoot,
    canManage,
    seesWholeEvent,
    myGroup,
    amAdminOf,
    groupById,
  }
}
