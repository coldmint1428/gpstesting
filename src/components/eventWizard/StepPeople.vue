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
    <div class="kp-card-head">
      <h2 class="kp-title">Add people</h2>
      <span class="kp-chip">{{ wizard.people.length }} added</span>
    </div>

    <label for="people-email" class="form-label">Add by exact email</label>
    <form class="kp-inline" @submit.prevent="addByEmail">
      <input id="people-email" v-model="email" type="email" class="form-control" placeholder="name@example.com" autocomplete="off" autocapitalize="off" spellcheck="false" inputmode="email" data-testid="wiz-email" />
      <button type="submit" class="btn btn-primary" :disabled="!canFind" data-testid="wiz-email-add">
        {{ finding ? 'Checking...' : 'Add' }}
      </button>
    </form>
    <p class="kp-note">People can also join later with the event code.</p>
    <p v-if="message" class="small mt-2 mb-0" :class="messageKind === 'error' ? 'text-danger' : 'text-success'" role="status" data-testid="wiz-email-result">
      {{ message }}
    </p>

    <p v-if="wizard.people.length === 0" class="kp-empty">No one yet.</p>
    <ul v-else class="kp-list mt-3" data-testid="wiz-people">
      <li v-for="p in wizard.people" :key="p.id" class="kp-row">
        <div class="kp-row-main">
          <strong>{{ p.display_name }}</strong>
          <span v-if="p.email">{{ p.email }}</span>
        </div>
        <div class="kp-row-actions">
          <label class="visually-hidden" :for="'role-' + p.id">Role for {{ p.display_name }}</label>
          <select :id="'role-' + p.id" v-model="p.role" class="form-select form-select-sm kp-stepped" @change="roleChanged(p)">
            <option v-for="r in ROLE_OPTIONS" :key="r.value" :value="r.value">{{ r.label }}</option>
          </select>
          <button type="button" class="btn btn-sm btn-ghost-danger" @click="wizard.removePerson(p.id)">Remove</button>
        </div>
      </li>
    </ul>
  </section>
</template>
