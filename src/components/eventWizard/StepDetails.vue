<script setup>
// Wizard step 1: event details
import { useEventWizardStore } from '../../stores/eventWizard'
import KDateTimePicker from '../kinetic/KDateTimePicker.vue'

defineProps({ errors: { type: Object, default: () => ({}) } })
const wizard = useEventWizardStore()

</script>

<template>
  <section class="kp-fields">
    <h2 class="kp-title">Event details</h2>

    <div>
      <label for="ev-name" class="form-label">Name <span class="text-danger">*</span></label>
      <input id="ev-name" v-model="wizard.details.name" class="form-control" :class="{ 'is-invalid': errors.name }" maxlength="80" placeholder="e.g. Sports Day 2026" data-testid="wiz-name" />
      <div v-if="errors.name" class="invalid-feedback">{{ errors.name }}</div>
    </div>

    <div>
      <label for="ev-description" class="form-label">Description</label>
      <textarea id="ev-description" v-model="wizard.details.description" class="form-control" :class="{ 'is-invalid': errors.description }" rows="3" maxlength="1000" data-testid="wiz-description"></textarea>
      <div v-if="errors.description" class="invalid-feedback">{{ errors.description }}</div>
    </div>

    <div>
      <label for="ev-venue" class="form-label">Venue</label>
      <input id="ev-venue" v-model="wizard.details.venue" class="form-control" :class="{ 'is-invalid': errors.venue }" maxlength="120" placeholder="e.g. Padang" data-testid="wiz-venue" />
      <div v-if="errors.venue" class="invalid-feedback">{{ errors.venue }}</div>
    </div>

    <div class="kp-fields-2">
      <div>
        <label for="ev-start" class="form-label">Starts <span class="text-danger">*</span></label>
        <KDateTimePicker id="ev-start" v-model="wizard.details.startsAt" label="Starts" :invalid="Boolean(errors.startsAt)" testid="wiz-start" />
        <div v-if="errors.startsAt" class="invalid-feedback">{{ errors.startsAt }}</div>
      </div>
      <div>
        <label for="ev-end" class="form-label">Ends <span class="text-danger">*</span></label>
        <KDateTimePicker id="ev-end" v-model="wizard.details.endsAt" label="Ends" :min="wizard.details.startsAt" :invalid="Boolean(errors.endsAt)" testid="wiz-end" />
        <div v-if="errors.endsAt" class="invalid-feedback">{{ errors.endsAt }}</div>
      </div>
    </div>
  </section>
</template>
