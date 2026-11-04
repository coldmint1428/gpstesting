<script setup>
// A date and time field made of the design's two pickers. The value stays what <input type="datetime-local"> gives:
// 'YYYY-MM-DDTHH:mm', or '' for none. The input itself stays in the page, out of sight, so a form and its tests can
// still set the value directly.
import { computed } from 'vue'
import KDatePicker from './KDatePicker.vue'
import KTimePicker from './KTimePicker.vue'

const props = defineProps({
  modelValue: { type: String, default: '' },
  id: { type: String, default: null },
  label: { type: String, required: true },
  min: { type: String, default: '' }, // 'YYYY-MM-DDTHH:mm': days before it are disabled
  before: { type: String, default: '' }, // 'YYYY-MM-DD': it and the days after it are disabled
  invalid: { type: Boolean, default: false },
  clearable: { type: Boolean, default: false },
  testid: { type: String, default: null },
})
const emit = defineEmits(['update:modelValue'])

const DEFAULT_TIME = '09:00'
const date = computed(() => (props.modelValue || '').slice(0, 10))
const time = computed(() => (props.modelValue || '').slice(11, 16))

function pad(n) {
  return String(n).padStart(2, '0')
}
function today() {
  const d = new Date()
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
}
function setDate(value) {
  emit('update:modelValue', value + 'T' + (time.value || DEFAULT_TIME))
}
function setTime(value) {
  emit('update:modelValue', (date.value || today()) + 'T' + value)
}
</script>

<template>
  <div class="k k2-dtfield" :class="{ 'is-invalid': invalid }">
    <input
      :id="id"
      class="visually-hidden"
      type="datetime-local"
      tabindex="-1"
      aria-hidden="true"
      :value="modelValue"
      :data-testid="testid"
      @input="emit('update:modelValue', $event.target.value)"
    />
    <div class="k2-dt">
      <KDatePicker :model-value="date" :label="label + ': date'" :min="(min || '').slice(0, 10)" :before="before" @update:model-value="setDate" />
      <KTimePicker :model-value="time" :label="label + ': time'" @update:model-value="setTime" />
    </div>
    <button v-if="clearable && modelValue" type="button" class="k2-link" style="margin-top: 6px" @click="emit('update:modelValue', '')">Clear</button>
  </div>
</template>
