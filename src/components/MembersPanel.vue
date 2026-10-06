<script setup>
// Members & groups of one event. Which controls appear depends on MY role:
//   Root          : everything, incl. making planners / marshals
//   Planner       : create groups, add people, assign groups, make admins / ICs
//   Group admin   : add/remove people in their own group, promote ICs
//   Everyone else : read-only list
// The database checks every action again (see 002_users_events_groups.sql).
import { ref, computed } from 'vue'
import { supabase } from '../lib/supabase'
import { initials } from '../utils/people'

const props = defineProps({
  eventId: { type: String, required: true },
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  me: { type: Object, default: null },
  isRoot: { type: Boolean, default: false },
  canManage: { type: Boolean, default: false },
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

function setEventRole(member, role, enabled) {
  return run('set_event_role', { p_event_id: props.eventId, p_user_id: member.id, p_role: role, p_enabled: enabled })
}

function removeMember(member) {
  if (!confirm('Remove ' + member.display_name + ' from this event?')) return
  return run('remove_member', { p_event_id: props.eventId, p_user_id: member.id })
}

// ---------- Per-member permission checks (decide which controls to show) ----------
const canSetIC = (m) => m.groupId && (props.canManage || m.groupId === myAdminGroupId.value)
const adminCanAdd = (m) => !props.canManage && myAdminGroupId.value && !m.groupId
const adminCanRemove = (m) => !props.canManage && myAdminGroupId.value && m.groupId === myAdminGroupId.value
const canRemove = (m) => props.canManage && !m.roles.includes('root') && (!props.me || m.id !== props.me.id)
</script>

<template>
  <div>
    <div v-if="errorMsg" class="alert alert-danger py-2" role="alert" data-testid="members-error">{{ errorMsg }}</div>

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
    <div v-if="groups.length" class="d-flex flex-wrap gap-2 mb-3">
      <span v-for="g in groups" :key="g.id" class="badge rounded-pill" :style="{ backgroundColor: g.colour }">
        {{ g.name }} · {{ members.filter((m) => m.groupId === g.id).length }}
      </span>
    </div>

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
              <span v-for="r in m.roles" :key="r" class="badge text-bg-secondary me-1 text-capitalize">{{ r }}</span>
              <span v-if="m.isAdmin" class="badge text-bg-info me-1">Group admin</span>
              <span v-if="m.isIC" class="badge text-bg-success me-1">IC</span>
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
