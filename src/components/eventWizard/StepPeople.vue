<script setup>
// Wizard step 2: add people by their full email address, then choose their role. Nothing is suggested while typing
// and no list of accounts is ever shown (068): you must already know the exact address, as with email to someone
// outside your organisation.
import { ref, computed, watch } from 'vue'
import { useEventWizardStore, ROLE_OPTIONS } from '../../stores/eventWizard'
import { findPersonByEmail, looksLikeEmail } from '../../services/eventService'

const wizard = useEventWizardStore()

const email = ref('')
const finding = ref(false)
const message = ref('') // the answer to the last Add, shown under the field
const messageKind = ref('') // 'error' | 'ok'

const canFind = computed(() => looksLikeEmail(email.value) && !finding.value)

// A new address is a new question: the last answer no longer applies (but emptying the field after an add does not
// take back the "added" it just said)
watch(email, (value) => {
  if (value) message.value = ''
})

async function addByEmail() {
  if (!canFind.value) return
  const typed = email.value.trim()
  finding.value = true
  message.value = ''
  try {
    const person = await findPersonByEmail(typed)
    if (!person) {
      messageKind.value = 'error'
      message.value = 'No account uses that email. Check the address, or send them the event code once it is made.'
      return
    }
    if (wizard.people.some((p) => p.id === person.id)) {
      messageKind.value = 'error'
      message.value = person.display_name + ' is already added.'
      return
    }
    // The email shown beside them is the one you typed, not one the app looked up
    wizard.addPerson({ ...person, email: typed })
    messageKind.value = 'ok'
    message.value = person.display_name + ' added.'
    email.value = ''
  } catch (error) {
    messageKind.value = 'error'
    message.value = error.message
  } finally {
    finding.value = false
  }
}

// Planners are never in a group (036): a new planner leaves the group they were put in at step 3
function roleChanged(p) {
  if (p.role === 'planner') wizard.removeFromGroups(p.id)
}
</script>

<template>
  <section>
    <h2 class="h5 mb-1">Add people</h2>
    <p class="text-muted small mb-3">You are the event's Root automatically. People can also join later with the event's code.</p>

    <label for="people-email" class="form-label">Add by email</label>
    <form class="d-flex gap-2" @submit.prevent="addByEmail">
      <input
        id="people-email"
        v-model="email"
        type="email"
        class="form-control"
        placeholder="name@example.com"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
        inputmode="email"
        data-testid="wiz-email"
      />
      <button type="submit" class="btn btn-primary flex-shrink-0" :disabled="!canFind" data-testid="wiz-email-add">
        {{ finding ? 'Checking...' : 'Add' }}
      </button>
    </form>
    <div class="form-text">Type their full email address. For privacy, nobody is suggested and no one's email is shown.</div>
    <p
      v-if="message"
      class="small mt-2 mb-0"
      :class="messageKind === 'error' ? 'text-danger' : 'text-success'"
      role="status"
      data-testid="wiz-email-result"
    >
      {{ message }}
    </p>

    <h3 class="h6 mt-4">Added ({{ wizard.people.length }})</h3>
    <p v-if="wizard.people.length === 0" class="text-muted small">No one yet.</p>
    <ul v-else class="list-group" data-testid="wiz-people">
      <li v-for="p in wizard.people" :key="p.id" class="list-group-item">
        <div class="d-flex flex-wrap align-items-center gap-2">
          <span class="me-auto text-truncate">
            {{ p.display_name }} <span v-if="p.email" class="text-muted small">{{ p.email }}</span>
          </span>
          <label class="visually-hidden" :for="'role-' + p.id">Role for {{ p.display_name }}</label>
          <select :id="'role-' + p.id" v-model="p.role" class="form-select form-select-sm w-auto" @change="roleChanged(p)">
            <option v-for="r in ROLE_OPTIONS" :key="r.value" :value="r.value">{{ r.label }}</option>
          </select>
          <button type="button" class="btn btn-sm btn-outline-danger" @click="wizard.removePerson(p.id)">Remove</button>
        </div>
      </li>
    </ul>
    <p class="form-text">
      Planners set up the map and timings, and are not in a group. Marshals see every group on the live map.
      Group Admin and IC are chosen in the next step.
    </p>
  </section>
</template>
