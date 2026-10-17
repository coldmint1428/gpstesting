<script setup>
// Members & groups of one event. Which controls appear depends on MY role:
//   Root          : everything, incl. making planners / marshals
//   Planner       : create groups, add people, assign groups, make admins / ICs
//   Group admin   : add/remove people in their own group, promote ICs
//   Everyone else : read-only list
// The database checks every action again (see 002_users_events_groups.sql).
import { ref, computed, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { initials, eventRoleLabel } from '../utils/people'
import BenchAlert from './BenchAlert.vue'
import { askConfirm, toast } from '../composables/useNotify'

const props = defineProps({
  eventId: { type: String, required: true },
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  me: { type: Object, default: null },
  isRoot: { type: Boolean, default: false },
  canManage: { type: Boolean, default: false },
  sharingStatus: { type: Object, default: () => ({}) }, // live only: { userId: true (sharing) | false }
})
const emit = defineEmits(['changed'])

const errorMsg = ref('')
const busy = ref(false)

const newGroupName = ref('')
const newGroupColour = ref('#0d6efd')
const addUsername = ref('')
const addGroupId = ref('') // '' = no group

// Group I am admin of (null if none)
const myAdminGroupId = computed(() => (props.me && props.me.isAdmin ? props.me.groupId : null))
const canAddPeople = computed(() => props.canManage || myAdminGroupId.value !== null)

function groupName(groupId) {
  const g = props.groups.find((x) => x.id === groupId)
  return g ? g.name : 'No group'
}
function groupColour(groupId) {
  const g = props.groups.find((x) => x.id === groupId)
  return g ? g.colour : '#6c757d'
}

// Run one database action, show its error, then tell the parent to reload
async function run(fnName, params) {
  errorMsg.value = ''
  busy.value = true
  const { error } = await supabase.rpc(fnName, params)
  busy.value = false
  if (error) {
    errorMsg.value = error.message
    return false
  }
  emit('changed')
  return true
}

// ---------- Group details for the run sheet (merger Stage 4): code, category, sector, headcount ----------
// A movement can be for a whole category ("every Contingent group"), so groups need one.
const showDetails = ref(false)
const details = ref({}) // groupId -> { code, category, sector, headcount }
const detailSaved = ref('') // groupId just saved
const justSaved = new Set() // rows to refresh from the next reload
function detailsOf(g) {
  return { code: g.code || '', category: g.category || '', sector: g.sector || '', headcount: g.headcount == null ? '' : String(g.headcount) }
}
function openDetails() {
  showDetails.value = !showDetails.value
  details.value = Object.fromEntries(props.groups.map((g) => [g.id, detailsOf(g)]))
}
// Groups reloaded (a save, or someone else): refresh rows that are not being edited, add new groups
watch(
  () => props.groups,
  (list, old) => {
    if (!showDetails.value) return
    const before = Object.fromEntries((old || []).map((g) => [g.id, g]))
    for (const g of list) {
      const d = details.value[g.id]
      const prev = before[g.id]
      const untouched = d && prev && JSON.stringify(d) === JSON.stringify(detailsOf(prev))
      // just saved: show what the database stored (codes are stored in capitals, spaces as _)
      if (!d || untouched || justSaved.has(g.id)) details.value[g.id] = detailsOf(g)
      justSaved.delete(g.id)
    }
  },
)
const groupCategories = computed(() => [...new Set(props.groups.map((g) => g.category).filter(Boolean))].sort())
function detailsChanged(g) {
  const d = details.value[g.id]
  if (!d) return false
  return (
    d.code !== (g.code || '') ||
    d.category !== (g.category || '') ||
    d.sector !== (g.sector || '') ||
    d.headcount !== (g.headcount == null ? '' : String(g.headcount))
  )
}
async function saveDetails(g) {
  const d = details.value[g.id]
  const head = String(d.headcount).trim()
  if (head !== '' && !/^\d+$/.test(head)) {
    errorMsg.value = 'Headcount for ' + g.name + ' must be a whole number.'
    return
  }
  const ok = await run('update_group_details', {
    p_group: g.id,
    p_code: d.code,
    p_category: d.category,
    p_sector: d.sector,
    p_headcount: head === '' ? null : Number(head),
  })
  if (ok) {
    justSaved.add(g.id)
    detailSaved.value = g.id
    setTimeout(() => (detailSaved.value === g.id ? (detailSaved.value = '') : null), 2500)
  }
}

async function createGroup() {
  const ok = await run('create_group', {
    p_event_id: props.eventId,
    p_name: newGroupName.value,
    p_colour: newGroupColour.value,
  })
  if (ok) newGroupName.value = ''
}

async function addMember() {
  // Group admins can only add into their own group
  const groupId = props.canManage ? addGroupId.value || null : myAdminGroupId.value
  const ok = await run('add_member_by_username', {
    p_event_id: props.eventId,
    p_username: addUsername.value,
    p_group_id: groupId,
  })
  if (ok) addUsername.value = ''
}

function assignGroup(member, groupId) {
  return run('assign_group', { p_event_id: props.eventId, p_user_id: member.id, p_group_id: groupId || null })
}

function setFlags(member, isAdmin, isIC) {
  return run('set_group_flags', {
    p_group_id: member.groupId,
    p_user_id: member.id,
    p_is_admin: isAdmin,
    p_is_ic: isIC,
  })
}

// A marshal's sector (merger Stage 7): the ops view opens filtered to it
const sectorChoices = computed(() => [...new Set(props.groups.map((g) => g.sector).filter(Boolean))].sort())
async function setSector(member, value) {
  if ((value || '') === (member.sector || '')) return
  if (await run('set_marshal_sector', { p_event: props.eventId, p_user: member.id, p_sector: value })) {
    toast(member.display_name + (value.trim() ? ' marshals sector ' + value.trim() + '.' : ' marshals every sector.'), 'success', 3000)
  }
}

function setEventRole(member, role, enabled) {
  return run('set_event_role', { p_event_id: props.eventId, p_user_id: member.id, p_role: role, p_enabled: enabled })
}

// Stop an IC's phone sharing remotely (e.g. they forgot after a rehearsal).
// Cancels their tracking pass: the phone's next upload is refused and the map shows "Stopped sharing".
async function stopSharing(member) {
  const ok = await askConfirm({
    title: 'Stop ' + member.display_name + "'s location sharing?",
    message: 'Their phone stops uploading and the map shows "Stopped sharing".',
    confirmText: 'Stop sharing',
    danger: true,
  })
  if (!ok) return
  errorMsg.value = ''
  busy.value = true
  const { data: wasSharing, error } = await supabase.rpc('stop_member_sharing', {
    p_event_id: props.eventId,
    p_user_id: member.id,
  })
  busy.value = false
  if (error) errorMsg.value = error.message
  else if (wasSharing) toast('Stopped ' + member.display_name + "'s location sharing.")
  else toast(member.display_name + ' was not sharing from the phone app.', 'warning')
}

async function removeMember(member) {
  const ok = await askConfirm({ title: 'Remove ' + member.display_name + ' from this event?', confirmText: 'Remove', danger: true })
  if (!ok) return
  return run('remove_member', { p_event_id: props.eventId, p_user_id: member.id })
}

// ---------- Per-member permission checks (decide which controls to show) ----------
const canSetIC = (m) => m.groupId && (props.canManage || m.groupId === myAdminGroupId.value)
// Same people who may change IC may stop an IC's sharing (not yourself: use your own Stop button)
const canStopSharing = (m) => m.isIC && canSetIC(m) && (!props.me || m.id !== props.me.id)
const adminCanAdd = (m) => !props.canManage && myAdminGroupId.value && !m.groupId
const adminCanRemove = (m) => !props.canManage && myAdminGroupId.value && m.groupId === myAdminGroupId.value
const canRemove = (m) => props.canManage && !m.roles.includes('root') && (!props.me || m.id !== props.me.id)
</script>

<template>
  <div>
    <BenchAlert v-if="errorMsg" data-testid="members-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <!-- Create group (root / planner) -->
    <form v-if="canManage" class="card mb-3" @submit.prevent="createGroup">
      <div class="card-body">
        <h2 class="h6">Create a group</h2>
        <div class="input-group">
          <input
            v-model="newGroupColour"
            type="color"
            class="form-control form-control-color flex-grow-0"
            title="Group colour"
            aria-label="Group colour"
          />
          <input
            v-model="newGroupName"
            class="form-control"
            placeholder="e.g. Contingent A"
            maxlength="50"
            required
            aria-label="Group name"
            data-testid="new-group-name"
          />
          <button class="btn btn-success" type="submit" :disabled="busy" data-testid="create-group-btn">Add</button>
        </div>
      </div>
    </form>

    <!-- Add an existing account by username -->
    <form v-if="canAddPeople" class="card mb-3" @submit.prevent="addMember">
      <div class="card-body">
        <h2 class="h6">Add a person by username</h2>
        <div class="row g-2">
          <div class="col-12 col-sm">
            <input
              v-model="addUsername"
              class="form-control"
              placeholder="username"
              autocapitalize="none"
              required
              aria-label="Username"
              data-testid="add-username"
            />
          </div>
          <div v-if="canManage" class="col-12 col-sm">
            <select v-model="addGroupId" class="form-select" aria-label="Group" data-testid="add-group">
              <option value="">No group yet</option>
              <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
            </select>
          </div>
          <div class="col-12 col-sm-auto">
            <button class="btn btn-primary w-100" type="submit" :disabled="busy" data-testid="add-member-btn">Add</button>
          </div>
        </div>
        <div v-if="!canManage" class="form-text">They will be added to {{ groupName(myAdminGroupId) }}.</div>
      </div>
    </form>

    <!-- Groups summary -->
    <div v-if="groups.length" class="d-flex flex-wrap gap-2 mb-3 align-items-center">
      <span v-for="g in groups" :key="g.id" class="badge rounded-pill" :style="{ backgroundColor: g.colour }">
        {{ g.name }} · {{ members.filter((m) => m.groupId === g.id).length }}
      </span>
      <button v-if="canManage" class="btn btn-sm btn-link" data-testid="group-details-btn" @click="openDetails">
        {{ showDetails ? 'Hide group details' : 'Group details (category, code…)' }}
      </button>
    </div>

    <!-- Group details (root / planner): used by the run sheet's category movements -->
    <div v-if="canManage && showDetails && groups.length" class="card mb-3" data-testid="group-details">
      <div class="card-body">
        <p class="small text-muted mb-2">
          A run sheet movement can be for a whole <strong>category</strong> (for example every "Contingent" group).
          Code, sector and headcount are for reference.
        </p>
        <datalist id="group-categories"><option v-for="c in groupCategories" :key="c" :value="c" /></datalist>
        <div class="table-responsive">
          <table class="table table-sm align-middle mb-0">
            <thead>
              <tr>
                <th scope="col">Group</th>
                <th scope="col">Category</th>
                <th scope="col">Code</th>
                <th scope="col">Sector</th>
                <th scope="col">Headcount</th>
                <th scope="col"><span class="visually-hidden">Save</span></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="g in groups.filter((x) => details[x.id])" :key="g.id" :data-testid="'group-details-' + g.name">
                <td class="text-nowrap"><span class="dot-sm" :style="{ backgroundColor: g.colour }"></span>{{ g.name }}</td>
                <td><input v-model="details[g.id].category" class="form-control form-control-sm" list="group-categories" maxlength="50" :aria-label="'Category of ' + g.name" data-testid="gd-category" /></td>
                <td><input v-model="details[g.id].code" class="form-control form-control-sm" maxlength="40" :aria-label="'Code of ' + g.name" data-testid="gd-code" /></td>
                <td><input v-model="details[g.id].sector" class="form-control form-control-sm" maxlength="50" :aria-label="'Sector of ' + g.name" /></td>
                <td style="max-width: 6rem"><input v-model="details[g.id].headcount" class="form-control form-control-sm" inputmode="numeric" :aria-label="'Headcount of ' + g.name" data-testid="gd-headcount" /></td>
                <td class="text-nowrap">
                  <span v-if="detailSaved === g.id" class="small text-success">Saved ✓</span>
                  <button v-else class="btn btn-sm btn-outline-primary" :disabled="busy || !detailsChanged(g)" data-testid="gd-save" @click="saveDetails(g)">Save</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <datalist :id="'sectors-' + eventId">
      <option v-for="s in sectorChoices" :key="s" :value="s"></option>
    </datalist>

    <!-- One card per member (cards stack nicely on phones) -->
    <div class="row g-2" data-testid="member-list">
      <div v-for="m in members" :key="m.id" class="col-12 col-md-6">
        <div class="card h-100" :data-testid="'member-' + m.username">
          <div class="card-body py-2">
            <div class="d-flex align-items-center gap-2 mb-1">
              <span class="avatar" :style="{ backgroundColor: groupColour(m.groupId) }">
                {{ initials(m.display_name) }}
              </span>
              <div class="flex-grow-1 text-truncate">
                <strong>{{ m.display_name }}</strong>
                <span v-if="me && m.id === me.id" class="text-muted small"> (you)</span>
                <div class="small text-muted">@{{ m.username }} · {{ groupName(m.groupId) }}</div>
              </div>
            </div>

            <div class="mb-2">
              <span class="badge text-bg-secondary me-1" :data-testid="'role-badge-' + m.username">{{ eventRoleLabel(m.roles) }}</span>
              <span v-if="m.isAdmin" class="badge text-bg-info me-1">Group admin</span>
              <span v-if="m.isIC" class="badge text-bg-success me-1">IC</span>
              <span v-if="sharingStatus[m.id] === true" class="badge text-bg-light border border-success text-success me-1" data-testid="badge-sharing">
                ● Sharing
              </span>
              <span v-else-if="sharingStatus[m.id] === false" class="badge text-bg-warning me-1" :data-testid="'badge-not-sharing-' + m.username">
                Not sharing yet
              </span>
            </div>

            <!-- Group (root / planner) -->
            <select
              v-if="canManage"
              class="form-select form-select-sm mb-2"
              :value="m.groupId || ''"
              :disabled="busy"
              aria-label="Group"
              :data-testid="'group-select-' + m.username"
              @change="assignGroup(m, $event.target.value)"
            >
              <option value="">No group</option>
              <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
            </select>
            <!-- Group admin: add to / remove from own group -->
            <button v-if="adminCanAdd(m)" class="btn btn-sm btn-outline-primary mb-2 me-1" :disabled="busy" @click="assignGroup(m, myAdminGroupId)">
              Add to my group
            </button>
            <button v-if="adminCanRemove(m) && m.id !== me.id" class="btn btn-sm btn-outline-secondary mb-2 me-1" :disabled="busy" @click="assignGroup(m, null)">
              Remove from my group
            </button>

            <div class="d-flex flex-wrap gap-3 small">
              <div v-if="canSetIC(m)" class="form-check form-switch">
                <input
                  :id="'ic-' + m.id"
                  class="form-check-input"
                  type="checkbox"
                  :checked="m.isIC"
                  :disabled="busy"
                  :data-testid="'ic-toggle-' + m.username"
                  @change="setFlags(m, m.isAdmin, $event.target.checked)"
                />
                <label class="form-check-label" :for="'ic-' + m.id">IC (shares GPS)</label>
              </div>
              <div v-if="canManage && m.groupId" class="form-check form-switch">
                <input
                  :id="'admin-' + m.id"
                  class="form-check-input"
                  type="checkbox"
                  :checked="m.isAdmin"
                  :disabled="busy"
                  @change="setFlags(m, $event.target.checked, m.isIC)"
                />
                <label class="form-check-label" :for="'admin-' + m.id">Group admin</label>
              </div>
              <template v-if="isRoot && !m.roles.includes('root')">
                <div v-for="role in ['planner', 'marshal']" :key="role" class="form-check form-switch">
                  <input
                    :id="role + '-' + m.id"
                    class="form-check-input"
                    type="checkbox"
                    :checked="m.roles.includes(role)"
                    :disabled="busy"
                    @change="setEventRole(m, role, $event.target.checked)"
                  />
                  <label class="form-check-label text-capitalize" :for="role + '-' + m.id">{{ role }}</label>
                </div>
              </template>
            </div>

            <!-- A marshal's sector (root / planners): the ops view opens filtered to it -->
            <div v-if="canManage && m.roles.includes('marshal')" class="input-group input-group-sm mt-2" style="max-width: 18rem">
              <span class="input-group-text">Marshals sector</span>
              <input
                class="form-control"
                :value="m.sector || ''"
                :list="'sectors-' + eventId"
                maxlength="50"
                placeholder="All sectors"
                :disabled="busy"
                :aria-label="'Sector ' + m.display_name + ' marshals'"
                :data-testid="'sector-' + m.username"
                @change="setSector(m, $event.target.value)"
              />
            </div>
            <div v-else-if="m.roles.includes('marshal') && m.sector" class="small text-muted mt-1">Marshals sector {{ m.sector }}</div>

            <button
              v-if="canStopSharing(m)"
              class="btn btn-sm btn-outline-danger mt-2 me-2"
              :disabled="busy"
              :data-testid="'stop-sharing-' + m.username"
              @click="stopSharing(m)"
            >
              Stop sharing
            </button>
            <button v-if="canRemove(m)" class="btn btn-sm btn-link text-danger px-0 mt-1" :disabled="busy" @click="removeMember(m)">
              Remove from event
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.dot-sm {
  display: inline-block;
  width: 0.6rem;
  height: 0.6rem;
  border-radius: 50%;
  margin-right: 0.35rem;
}
.avatar {
  width: 2rem;
  height: 2rem;
  border-radius: 50%;
  color: #fff;
  font-size: 0.75rem;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
</style>
