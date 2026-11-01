<script setup>
// The event's People page: everyone in the event with their role, group and IC tag. Controls appear only for what MY
// role may do to each person (src/utils/permissions.js); the database checks every change again (033).
//   Root          : add people; make planners, group admins, members; remove anyone
//   Planner       : the same for people below planner
//   Group admin   : add people to their own group; removing members of their own group
//   Everyone else : the list only
// Marshal and IC (duties of a member) are switched on the Groups page (MembersPanel.vue); here they are badges only.
// An IC's arrival radius (063) stays here, beside the IC it belongs to.
import { ref, computed, watch } from 'vue'
import { initials } from '../utils/people'
import { ROLE_RANK, ROLE_LABEL, topRole, isMarshal, canManage, assignableRoles, canSetIC, canRemove } from '../utils/permissions'
import { addEventMember, setMemberRole, setArrivalTolerance, removeEventMember } from '../services/memberService'
import { findPersonByEmail, looksLikeEmail } from '../services/eventService'
import { askConfirm, toast } from '../composables/useNotify'
import BenchAlert from './BenchAlert.vue'

const props = defineProps({
  eventId: { type: String, required: true },
  members: { type: Array, required: true },
  groups: { type: Array, required: true },
  me: { type: Object, default: null },
  mode: { type: String, default: 'view' }, // 'edit' | 'view'
})
const emit = defineEmits(['changed'])

const errorMsg = ref('')
const busy = ref(false)
const search = ref('')
const groupFilter = ref('') // '' all | 'none' no group | group id
const open = ref(null) // the card whose actions are open (phone)

const myRole = computed(() => topRole(props.me))
const myRoleOptions = computed(() => assignableRoles(myRole.value))

const groupById = computed(() => Object.fromEntries(props.groups.map((g) => [g.id, g])))
const groupName = (id) => (groupById.value[id] ? groupById.value[id].name : 'No group')
const groupColour = (id) => (groupById.value[id] ? groupById.value[id].colour : '#6c757d')

// Highest role first, then by name
const rows = computed(() => {
  const q = search.value.trim().toLowerCase()
  return props.members
    .filter((m) => !groupFilter.value || (groupFilter.value === 'none' ? !m.groupId : m.groupId === groupFilter.value))
    .filter((m) => !q || m.display_name.toLowerCase().includes(q))
    .map((m) => {
      const role = topRole(m)
      const isMe = !!props.me && m.id === props.me.id
      const edit = props.mode === 'edit'
      const actions = {
        role: edit && !isMe && canManage(myRole.value, role),
        // the IC's arrival radius: whoever may set the IC may set how close they must be
        radius: edit && m.isIC && canSetIC(props.me, m),
        remove: edit && canRemove(props.me, m),
      }
      return { m, role, isMe, actions, any: Object.values(actions).some(Boolean) }
    })
    .sort((a, b) => ROLE_RANK[b.role] - ROLE_RANK[a.role] || a.m.display_name.localeCompare(b.m.display_name))
})

// What I can do here, in one line
const myScope = computed(() => {
  if (props.mode !== 'edit') return 'You can see everyone in this event.'
  if (myRole.value === 'root') return 'You can change roles and remove people. Set marshals and ICs on the Groups page.'
  if (myRole.value === 'planner') return 'You can change the roles of group admins and members, and remove them. Set marshals and ICs on the Groups page.'
  if (myRole.value === 'admin' && props.me.groupId) return 'You can remove members of ' + groupName(props.me.groupId) + '. Set ICs on the Groups page.'
  return 'You are not in a group, so you have no one to manage.'
})

async function run(call, success) {
  errorMsg.value = ''
  busy.value = true
  const message = await call()
  busy.value = false
  if (message) errorMsg.value = message
  else toast(success, 'success', 3000)
  emit('changed') // refused or not: show what the server has now
  return !message
}

// ---------- Add a person (root / planners into any group, a group admin into their own) ----------
const managesAll = computed(() => props.mode === 'edit' && (myRole.value === 'root' || myRole.value === 'planner'))
const myAdminGroupId = computed(() => (props.mode === 'edit' && props.me && props.me.isAdmin ? props.me.groupId : null))
const canAddPeople = computed(() => managesAll.value || myAdminGroupId.value !== null)
const myAdminGroupName = computed(() => groupName(myAdminGroupId.value))

const addEmail = ref('')
const addGroupId = ref('') // '' = no group
// Add an existing account by its full email address (068). Nothing is suggested while typing and no list of accounts
// is shown -- the way email to someone outside your organisation works -- so this page never shows anyone's email.
const finding = ref(false)
const addMessage = ref('')
const canFind = computed(() => looksLikeEmail(addEmail.value) && !finding.value && !busy.value)
watch(addEmail, (value) => {
  if (value) addMessage.value = ''
})

async function addByEmail() {
  if (!canFind.value) return
  finding.value = true
  addMessage.value = ''
  try {
    const person = await findPersonByEmail(addEmail.value)
    if (!person) {
      addMessage.value = 'No account uses that email. Check the address, or send them the event code.'
      return
    }
    if (props.members.some((m) => m.id === person.id)) {
      addMessage.value = person.display_name + ' is already in this event.'
      return
    }
    await addMember(person)
  } catch (error) {
    addMessage.value = error.message
  } finally {
    finding.value = false
  }
}

async function addMember(p) {
  const groupId = managesAll.value ? addGroupId.value || null : myAdminGroupId.value
  const ok = await run(() => addEventMember(props.eventId, p.id, groupId), p.display_name + ' was added to the event.')
  if (ok) addEmail.value = ''
}

async function changeRole(m, select) {
  const role = select.value
  const was = topRole(m)
  if (role === was) return
  if (role === 'planner') {
    const ok = await askConfirm({
      title: 'Make ' + m.display_name + ' a planner?',
      message:
        'Planners edit the timeline and map, run the event and manage everyone below them.' +
        (m.groupId ? ' Planners are not in a group, so they will leave ' + groupName(m.groupId) + '.' : ''),
      confirmText: 'Make planner',
    })
    if (!ok) {
      select.value = was
      return
    }
  }
  const ok = await run(() => setMemberRole(props.eventId, m.id, role), m.display_name + ' is now ' + ROLE_LABEL[role].toLowerCase() + '.')
  if (!ok) select.value = was // refused: the list did not change, so put the menu back by hand
}

async function remove(m) {
  const ok = await askConfirm({
    title: 'Remove ' + m.display_name + ' from this event?',
    message: 'They also leave ' + groupName(m.groupId) + '. They can join again with the invite code.',
    confirmText: 'Remove',
    danger: true,
  })
  if (!ok) return
  await run(() => removeEventMember(props.eventId, m.id), m.display_name + ' was removed from the event.')
}

// How close this IC's phone must be to a moment's point for the tick to close it (063). A planner sets it here; the IC
// sets their own on their "My GPS details" page, and the database refuses anybody outside those three doors.
async function changeTolerance(m, input) {
  const metres = Math.round(Number(input.value))
  if (!Number.isFinite(metres)) {
    input.value = m.toleranceM // not a number: put the stored one back
    return
  }
  const ok = await run(
    () => setArrivalTolerance(props.eventId, m.id, metres),
    m.display_name + ' now counts as arrived within ' + metres + ' m.',
  )
  if (!ok) input.value = m.toleranceM // refused: the list did not change, so put the field back by hand
}
</script>

<template>
  <div>
    <p class="small text-muted mb-2" data-testid="people-scope">{{ myScope }}</p>
    <BenchAlert v-if="errorMsg" data-testid="people-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <!-- Add an existing account by their full email: nothing suggested, no one's email shown -->
    <div v-if="canAddPeople" class="card mb-3" data-testid="add-person">
      <div class="card-body">
        <h2 class="h6">Add a person</h2>
        <form class="row g-2" @submit.prevent="addByEmail">
          <div class="col-12 col-sm">
            <label for="add-email" class="visually-hidden">Their email address</label>
            <input
              id="add-email"
              v-model="addEmail"
              type="email"
              class="form-control"
              placeholder="Their full email address"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              inputmode="email"
              data-testid="add-email"
            />
          </div>
          <div v-if="managesAll" class="col-12 col-sm-4">
            <select v-model="addGroupId" class="form-select" aria-label="Group" data-testid="add-group">
              <option value="">No group yet</option>
              <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
            </select>
          </div>
          <div class="col-12 col-sm-auto">
            <button type="submit" class="btn btn-primary w-100" :disabled="!canFind" data-testid="add-email-btn">
              {{ finding ? 'Checking...' : 'Add' }}
            </button>
          </div>
        </form>
        <p v-if="addMessage" class="text-danger small mt-2 mb-0" role="status" data-testid="add-none">{{ addMessage }}</p>
        <div class="form-text">For privacy, people are added by their exact email only; nobody is suggested.</div>
        <div v-if="!managesAll" class="form-text">They will be added to {{ myAdminGroupName }}.</div>
      </div>
    </div>

    <div class="row g-2 mb-3">
      <div class="col-12 col-sm-7">
        <label for="people-search" class="visually-hidden">Search by name</label>
        <input id="people-search" v-model="search" type="search" class="form-control" placeholder="Search by name" data-testid="people-search" />
      </div>
      <div class="col-12 col-sm-5">
        <label for="people-group" class="visually-hidden">Filter by group</label>
        <select id="people-group" v-model="groupFilter" class="form-select" data-testid="people-group-filter">
          <option value="">All groups</option>
          <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
          <option value="none">No group</option>
        </select>
      </div>
    </div>

    <p v-if="!rows.length" class="text-muted" data-testid="people-empty">No one matches.</p>
    <ul class="list-unstyled d-grid gap-2 mb-0" data-testid="people-list">
      <li v-for="r in rows" :key="r.m.id" class="card" :data-testid="'person-' + r.m.username">
        <div class="card-body py-2 d-flex flex-wrap align-items-center gap-2">
          <span class="avatar" :style="{ backgroundColor: groupColour(r.m.groupId) }" aria-hidden="true">{{ initials(r.m.display_name) }}</span>
          <div class="flex-grow-1 min-w-0">
            <div class="text-truncate">
              <strong>{{ r.m.display_name }}</strong>
              <span v-if="r.isMe" class="text-muted small"> (you)</span>
            </div>
            <div class="small text-muted text-truncate">{{ groupName(r.m.groupId) }}</div>
            <div>
              <span class="badge text-bg-secondary me-1" :data-testid="'person-role-' + r.m.username">{{ ROLE_LABEL[r.role] }}</span>
              <span v-if="r.m.isAdmin && r.role !== 'admin'" class="badge text-bg-info me-1">Group admin</span>
              <span v-if="isMarshal(r.m)" class="badge text-bg-dark me-1" :data-testid="'person-marshal-' + r.m.username">Marshal</span>
              <span v-if="r.m.isIC" class="badge text-bg-success me-1" :data-testid="'person-ic-' + r.m.username">IC</span>
            </div>
          </div>

          <!-- Phone: the actions open from this button; wider screens show them inline -->
          <button
            v-if="r.any"
            type="button"
            class="btn btn-sm btn-outline-secondary d-md-none"
            :aria-expanded="open === r.m.id ? 'true' : 'false'"
            :aria-controls="'actions-' + r.m.id"
            :data-testid="'person-menu-' + r.m.username"
            @click="open = open === r.m.id ? null : r.m.id"
          >
            Manage <span aria-hidden="true">{{ open === r.m.id ? '▴' : '▾' }}</span>
          </button>
          <div
            v-if="r.any"
            :id="'actions-' + r.m.id"
            class="actions align-items-center gap-3 flex-wrap"
            :class="open === r.m.id ? 'd-flex' : 'd-none d-md-flex'"
          >
            <div v-if="r.actions.role">
              <label :for="'role-' + r.m.id" class="visually-hidden">Role of {{ r.m.display_name }}</label>
              <select
                :id="'role-' + r.m.id"
                class="form-select form-select-sm"
                :value="r.role"
                :disabled="busy"
                :data-testid="'person-role-select-' + r.m.username"
                @change="changeRole(r.m, $event.target)"
              >
                <option v-for="role in myRoleOptions" :key="role" :value="role" :disabled="role === 'admin' && !r.m.groupId">
                  {{ ROLE_LABEL[role] }}{{ role === 'admin' && !r.m.groupId ? ' (needs a group)' : '' }}
                </option>
              </select>
            </div>
            <!-- An IC's arrival radius: how close their phone must be for a moment to close itself (063). -->
            <div v-if="r.actions.radius" class="d-flex align-items-center gap-1">
              <label :for="'tol-' + r.m.id" class="small text-muted mb-0">Radius</label>
              <input
                :id="'tol-' + r.m.id"
                type="number"
                min="5"
                max="100"
                step="5"
                class="form-control form-control-sm people-tol"
                :value="r.m.toleranceM"
                :disabled="busy"
                :data-testid="'person-tolerance-' + r.m.username"
                @change="changeTolerance(r.m, $event.target)"
              />
              <span class="small text-muted">m</span>
            </div>
            <button
              v-if="r.actions.remove"
              type="button"
              class="btn btn-sm btn-outline-danger"
              :disabled="busy"
              :data-testid="'person-remove-' + r.m.username"
              @click="remove(r.m)"
            >
              Remove
            </button>
          </div>
        </div>
      </li>
    </ul>
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
.min-w-0 {
  min-width: 0;
}
/* the arrival radius is a number of metres, not a paragraph */
.people-tol {
  width: 5rem;
}
/* phone: the opened actions take the card's full width under the name */
@media (max-width: 767.98px) {
  .actions {
    flex-basis: 100%;
  }
}
</style>
