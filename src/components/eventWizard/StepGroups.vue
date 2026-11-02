<script setup>
// Wizard step 3: make groups, put people in them (one group each), tick Admin / IC
import { ref, computed } from 'vue'
import { useEventWizardStore } from '../../stores/eventWizard'
import { askConfirm } from '../../composables/useNotify'
import ExpandTransition from '../ExpandTransition.vue'

const props = defineProps({
  errors: { type: Object, default: () => ({}) },
  everyone: { type: Array, required: true }, // [{ id, display_name, email, role }] incl. the creator
})
const wizard = useEventWizardStore()

const newName = ref('')
const newColour = ref(wizard.suggestedColour())
const addError = ref('')
const editingKey = ref(null) // the group whose editor is open
const filter = ref('')

const byId = computed(() => Object.fromEntries(props.everyone.map((p) => [p.id, p])))
// Planners run the whole event and are never in a group (036)
const unassigned = computed(() => props.everyone.filter((p) => !wizard.groupOf[p.id] && p.role !== 'planner'))

// Unassigned people matching the filter, for the open group's "Add" list
const addable = computed(() => {
  const f = filter.value.trim().toLowerCase()
  return unassigned.value.filter(
    (p) => !f || p.display_name.toLowerCase().includes(f),
  )
})

function addGroup() {
  addError.value = wizard.addGroup(newName.value, newColour.value)
  if (addError.value) return
  editingKey.value = wizard.groups[wizard.groups.length - 1].key // open the new group straight away
  newName.value = ''
  newColour.value = wizard.suggestedColour()
}

function toggleEdit(key) {
  editingKey.value = editingKey.value === key ? null : key
  filter.value = ''
}

function addAllUnassigned(key) {
  for (const p of addable.value) wizard.addToGroup(key, p.id)
}

async function removeGroup(group) {
  if (group.members.length) {
    const ok = await askConfirm({
      title: 'Delete "' + group.name + '"?',
      message: 'Its ' + group.members.length + ' people will have no group.',
      confirmText: 'Delete group',
      danger: true,
    })
    if (!ok) return
  }
  wizard.removeGroup(group.key)
}
</script>

<template>
  <section>
    <div class="kp-card-head">
      <h2 class="kp-title">Groups</h2>
      <span class="kp-chip">{{ unassigned.length }} without a group</span>
    </div>
    <p class="kp-sub mb-3">Each group with people needs at least one IC, the phone that shares its location.</p>

    <form class="mb-3" @submit.prevent="addGroup">
      <label for="new-group-name" class="form-label">New group</label>
      <div class="kp-inline">
        <input id="new-group-colour" v-model="newColour" type="color" class="form-control form-control-color kp-colour" aria-label="Colour" />
        <input id="new-group-name" v-model="newName" class="form-control" :class="{ 'is-invalid': addError }" maxlength="50" placeholder="e.g. Scouts" data-testid="wiz-group-name" />
        <button type="submit" class="btn btn-success" data-testid="wiz-add-group">Add</button>
      </div>
      <div v-if="addError" class="text-danger small mt-1">{{ addError }}</div>
    </form>

    <p v-if="wizard.groups.length === 0" class="kp-empty">No groups yet. You can add them later.</p>

    <ul class="kp-list" data-testid="wiz-groups">
      <li v-for="g in wizard.groups" :key="g.key" class="kp-group-row">
        <div class="kp-inline">
          <span class="kp-dot" :style="{ background: g.colour }" aria-hidden="true"></span>
          <strong class="me-auto text-truncate">{{ g.name || '(no name)' }}</strong>
          <span class="kp-chip">{{ g.members.length }}</span>
          <button type="button" class="btn btn-sm btn-outline-secondary" :aria-expanded="editingKey === g.key" @click="toggleEdit(g.key)">
            {{ editingKey === g.key ? 'Done' : 'Edit' }}
          </button>
        </div>
        <p v-if="errors['group-' + g.key]" class="text-danger small mb-0 mt-2">{{ errors['group-' + g.key] }}</p>

        <ExpandTransition>
          <div v-if="editingKey === g.key">
            <div class="pt-3">
              <label :for="'group-name-' + g.key" class="form-label">Name</label>
              <div class="kp-inline mb-3">
                <input :id="'group-colour-' + g.key" v-model="g.colour" type="color" class="form-control form-control-color kp-colour" aria-label="Colour" />
                <input :id="'group-name-' + g.key" v-model="g.name" class="form-control" maxlength="50" />
                <button type="button" class="btn btn-sm btn-ghost-danger" @click="removeGroup(g)">Delete</button>
              </div>

              <p v-if="g.members.length === 0" class="kp-note mb-3">No one in this group yet.</p>
              <ul v-else class="kp-list mb-3">
                <li v-for="m in g.members" :key="m.userId" class="kp-row">
                  <div class="kp-row-main">
                    <strong>{{ byId[m.userId].display_name }}</strong>
                    <span v-if="byId[m.userId].email">{{ byId[m.userId].email }}</span>
                  </div>
                  <div class="kp-row-actions">
                    <div class="form-check form-check-inline m-0">
                      <input :id="'ic-' + m.userId" v-model="m.isIC" class="form-check-input" type="checkbox" />
                      <label class="form-check-label small" :for="'ic-' + m.userId">IC</label>
                    </div>
                    <div class="form-check form-check-inline m-0">
                      <input :id="'admin-' + m.userId" v-model="m.isAdmin" class="form-check-input" type="checkbox" />
                      <label class="form-check-label small" :for="'admin-' + m.userId">Admin</label>
                    </div>
                    <button type="button" class="btn btn-sm btn-ghost" @click="wizard.removeFromGroups(m.userId)">Remove</button>
                  </div>
                </li>
              </ul>

              <label :for="'group-filter-' + g.key" class="form-label">Add people</label>
              <input :id="'group-filter-' + g.key" v-model="filter" type="search" class="form-control mb-2" placeholder="Filter by name" autocomplete="off" />
              <p v-if="unassigned.length === 0" class="kp-note mb-0">Everyone has a group.</p>
              <template v-else>
                <ul class="kp-list kp-pick mb-2">
                  <li v-for="p in addable" :key="p.id" class="kp-row py-2">
                    <span class="me-auto text-truncate small">
                      {{ p.display_name }} <span v-if="p.email" class="text-muted">{{ p.email }}</span>
                      <span v-if="p.role === 'root'" class="kp-chip kp-chip-ink ms-1">You</span>
                    </span>
                    <button type="button" class="btn btn-sm btn-primary" @click="wizard.addToGroup(g.key, p.id)">Add</button>
                  </li>
                  <li v-if="addable.length === 0" class="kp-row small text-muted">No match.</li>
                </ul>
                <button v-if="addable.length > 1" type="button" class="btn btn-sm btn-outline-secondary" @click="addAllUnassigned(g.key)">
                  Add all {{ addable.length }} shown
                </button>
              </template>
            </div>
          </div>
        </ExpandTransition>
      </li>
    </ul>

    <p v-if="unassigned.length" class="kp-note" data-testid="wiz-unassigned">
      Not in a group: {{ unassigned.map((p) => p.display_name).join(', ') }}
    </p>
  </section>
</template>
