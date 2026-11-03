<script setup>
// The event's People page: everyone in the event with their role, group and IC tag. Controls appear only for what MY
// role may do to each person (src/utils/permissions.js); the database checks every change again (033).
//   Root          : add people; make planners, group admins, members; remove anyone
//   Planner       : the same for people below planner
//   Group admin   : add people to their own group; removing members of their own group
// ICs and members do not have this page: they see only their own group, on the Groups page (073).
// IC (a duty of a member) is switched on the Groups page (MembersPanel.vue); here it is a badge only.
// An IC's arrival radius (063) stays here, beside the IC it belongs to.
import { ref, computed, watch } from 'vue'
import EmptyState from './EmptyState.vue'
import { initials } from '../utils/people'
import { ROLE_RANK, ROLE_LABEL, topRole, canManage, assignableRoles, canSetIC, canRemove } from '../utils/permissions'
import { addEventMember, setMemberRole, setArrivalTolerance, removeEventMember } from '../services/memberService'
import { findPersonByEmail, looksLikeEmail } from '../services/eventService'
import { askConfirm, toast } from '../composables/useNotify'
import BenchAlert from './BenchAlert.vue'
import { useOpenMenu } from '../composables/useOpenMenu'

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
const adding = ref(false) // the Add person row is open
const { openMenu, toggleMenu, closeMenu } = useOpenMenu()

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
  if (myRole.value === 'root') return 'You can change roles and remove people. Set ICs on the Groups page.'
  if (myRole.value === 'planner') return 'You can change the roles of group admins and members, and remove them. Set ICs on the Groups page.'
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
  <div class="k kp-stack" :aria-busy="busy ? 'true' : null">
    <BenchAlert v-if="errorMsg" data-testid="people-error" @dismiss="errorMsg = ''">{{ errorMsg }}</BenchAlert>

    <div class="k2-h" style="margin-bottom: 0">
      <h1>People</h1>
      <span class="cnt">{{ members.length }}</span>
      <span class="sp"></span>
      <button v-if="canAddPeople" type="button" class="kb kb-ink kb-sm" :aria-expanded="adding ? 'true' : 'false'" data-testid="add-person-btn" @click="adding = !adding">
        <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>Add person
      </button>
    </div>

    <!-- Add an existing account by their full email: nothing suggested, no one's email shown -->
    <div v-if="canAddPeople && adding" class="k2-card" data-testid="add-person">
      <form class="k2-addrow" :class="{ 'has-group': managesAll }" @submit.prevent="addByEmail">
        <div>
          <label for="add-email" class="visually-hidden">Their email address</label>
          <input id="add-email" v-model="addEmail" type="email" class="kin" style="width: 100%" placeholder="Their exact email" autocomplete="off" autocapitalize="off" spellcheck="false" inputmode="email" data-testid="add-email" />
        </div>
        <div v-if="managesAll" class="ksel" style="width: 100%">
          <select v-model="addGroupId" style="width: 100%" aria-label="Group" data-testid="add-group">
            <option value="">No group yet</option>
            <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
          </select>
        </div>
        <button type="submit" class="kb kb-lime" :disabled="!canFind" data-testid="add-email-btn">{{ finding ? 'Checking...' : 'Add' }}</button>
      </form>
      <p v-if="addMessage" class="k2-err" role="status" data-testid="add-none">{{ addMessage }}</p>
      <p v-if="!managesAll" class="k2-hint">They join {{ myAdminGroupName }}.</p>
    </div>

    <div class="k2-filterrow">
      <div style="flex: 1 1 220px">
        <label for="people-search" class="visually-hidden">Search by name</label>
        <input id="people-search" v-model="search" type="search" class="kin" style="width: 100%" placeholder="Search by name" data-testid="people-search" />
      </div>
      <div class="ksel">
        <label for="people-group" class="visually-hidden">Filter by group</label>
        <select id="people-group" v-model="groupFilter"  data-testid="people-group-filter">
          <option value="">All groups</option>
          <option v-for="g in groups" :key="g.id" :value="g.id">{{ g.name }}</option>
          <option value="none">No group</option>
        </select>
      </div>
    </div>

    <div class="k2-card">
      <EmptyState v-if="!rows.length" compact icon="search" title="No one matches" text="Try another name or filter." data-testid="people-empty" />
      <template v-else>
        <div class="k2-pp hd" aria-hidden="true"><span>Person</span><span>Role</span><span>IC radius</span><span></span></div>
        <div data-testid="people-list">
          <div v-for="r in rows" :key="r.m.id" class="k2-pp" :data-testid="'person-' + r.m.username">
            <div class="row" style="gap: 10px; min-width: 0">
              <span class="av" :style="{ backgroundColor: groupColour(r.m.groupId), color: '#fff' }" aria-hidden="true">{{ initials(r.m.display_name) }}</span>
              <div style="min-width: 0">
                <b class="d-block text-truncate" style="font-size: 14px">{{ r.m.display_name }}<span v-if="r.isMe" class="mut" style="font-weight: 500"> (you)</span></b>
                <span class="mut d-block text-truncate" style="font-size: 12px">{{ groupName(r.m.groupId) }}<template v-if="r.m.isAdmin && r.role !== 'admin'"> · Group admin</template></span>
              </div>
            </div>
            <div>
              <template v-if="r.actions.role">
                <label :for="'role-' + r.m.id" class="visually-hidden">Role of {{ r.m.display_name }}</label>
                <div class="ksel" style="width: 100%">
                  <select :id="'role-' + r.m.id" class="k2-sel-sm" style="width: 100%" :value="r.role" :disabled="busy" :data-testid="'person-role-select-' + r.m.username" @change="changeRole(r.m, $event.target)">
                    <option v-for="role in myRoleOptions" :key="role" :value="role" :disabled="role === 'admin' && !r.m.groupId">
                      {{ ROLE_LABEL[role] }}{{ role === 'admin' && !r.m.groupId ? ' (needs a group)' : '' }}
                    </option>
                  </select>
                </div>
              </template>
              <span v-else class="chip" :class="r.role === 'root' ? 'chip-ink' : r.role === 'planner' ? 'chip-mint' : 'chip-soft'" :data-testid="'person-role-' + r.m.username">{{ ROLE_LABEL[r.role] }}</span>
            </div>
            <div class="k2-ic">
              <template v-if="r.m.isIC">
                <span class="chip chip-soft" style="height: 24px" :data-testid="'person-ic-' + r.m.username">IC</span>
                <!-- An IC's arrival radius: how close their phone must be for a moment to close itself (063). -->
                <span v-if="r.actions.radius" class="k2-rad">
                  <label :for="'tol-' + r.m.id" class="visually-hidden">IC radius of {{ r.m.display_name }}</label>
                  <input :id="'tol-' + r.m.id" type="number" min="5" max="100" step="5" :value="r.m.toleranceM" :disabled="busy" :data-testid="'person-tolerance-' + r.m.username" @change="changeTolerance(r.m, $event.target)" />m
                </span>
                <span v-else-if="r.m.toleranceM != null" class="mut" style="font-size: 13px; font-weight: 700">{{ r.m.toleranceM }} m</span>
              </template>
              <span v-else class="mut">—</span>
            </div>
            <div v-if="r.actions.remove" class="wrapm" data-menu>
              <button type="button" class="ib" :aria-label="'Options for ' + r.m.display_name" :aria-expanded="openMenu === r.m.id ? 'true' : 'false'" :data-testid="'person-menu-' + r.m.username" @click="toggleMenu(r.m.id)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true" style="stroke-width: 3"><path d="M5 12h.01M12 12h.01M19 12h.01"></path></svg></button>
              <div v-if="openMenu === r.m.id" class="menu r" role="menu">
                <button type="button" role="menuitem" class="danger" :disabled="busy" :data-testid="'person-remove-' + r.m.username" @click="closeMenu(); remove(r.m)">Remove from event</button>
              </div>
            </div>
            <span v-else></span>
          </div>
        </div>
      </template>
      <p v-if="rows.length" class="k2-hint" data-testid="people-scope">
        <template v-if="mode === 'edit'">ICs are set on the <RouterLink class="k2-link" :to="{ name: 'event', params: { id: eventId, page: 'groups' } }">Groups</RouterLink> page.</template>
        <template v-else>{{ myScope }}</template>
      </p>
    </div>
  </div>
</template>
