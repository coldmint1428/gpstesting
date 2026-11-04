<script setup>
// A time field with the design's three scrolling columns instead of the browser's popup. The value stays 'HH:mm'.
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { usePlacedPopup } from '../../composables/useOpenMenu'

const props = defineProps({
  modelValue: { type: String, default: '' },
  label: { type: String, required: true },
  disabled: { type: Boolean, default: false },
  testid: { type: String, default: null },
})
const emit = defineEmits(['update:modelValue'])

const open = ref(false)
// Opened above the field, or moved in from an edge, when there is no room for all of it below (useOpenMenu)
usePlacedPopup(open)
const wrap = ref(null)
const parts = computed(() => {
  const [h, m] = (props.modelValue || '00:00').split(':').map(Number)
  return { h: h || 0, m: m || 0 }
})
const pm = computed(() => parts.value.h >= 12)
const h12 = computed(() => ((parts.value.h + 11) % 12) + 1)
const text = computed(() => (props.modelValue ? h12.value + ':' + String(parts.value.m).padStart(2, '0') + ' ' + (pm.value ? 'pm' : 'am') : 'Pick a time'))
const HOURS = [12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const minutes = computed(() => {
  const list = Array.from({ length: 12 }, (_, i) => i * 5)
  if (!list.includes(parts.value.m)) list.push(parts.value.m)
  return list.sort((a, b) => a - b)
})
function set(hour24, minute) {
  emit('update:modelValue', String(hour24).padStart(2, '0') + ':' + String(minute).padStart(2, '0'))
}
const setHour = (h) => set((h % 12) + (pm.value ? 12 : 0), parts.value.m)
const setMeridiem = (isPm) => set((parts.value.h % 12) + (isPm ? 12 : 0), parts.value.m)

function onKey(event) {
  if (event.key === 'Escape') {
    event.stopPropagation()
    open.value = false
  }
}
function away(event) {
  if (open.value && wrap.value && !wrap.value.contains(event.target)) open.value = false
}
onMounted(() => document.addEventListener('pointerdown', away))
onBeforeUnmount(() => document.removeEventListener('pointerdown', away))
</script>

<template>
  <div ref="wrap" class="wrapm">
    <button type="button" class="k2-fbtn" :disabled="disabled" :aria-expanded="open ? 'true' : 'false'" :aria-label="label" :data-testid="testid" @click="open = !open">
      <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2"></path></svg><span>{{ text }}</span>
    </button>
    <div v-if="open" class="k2-cal k2-time" role="dialog" aria-label="Choose a time" @keydown="onKey">
      <div class="k2-tcols">
        <div class="col" role="group" aria-label="Hour"><button v-for="h in HOURS" :key="h" type="button" :aria-pressed="h === h12 ? 'true' : 'false'" @click="setHour(h)">{{ h }}</button></div>
        <div class="col" role="group" aria-label="Minute"><button v-for="m in minutes" :key="m" type="button" :aria-pressed="m === parts.m ? 'true' : 'false'" @click="set(parts.h, m)">{{ String(m).padStart(2, '0') }}</button></div>
        <div class="col" role="group" aria-label="am or pm">
          <button type="button" :aria-pressed="!pm ? 'true' : 'false'" @click="setMeridiem(false)">am</button>
          <button type="button" :aria-pressed="pm ? 'true' : 'false'" @click="setMeridiem(true)">pm</button>
        </div>
      </div>
      <div class="row" style="margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--line)">
        <span class="mut" style="font-size: 13px; font-weight: 700">{{ text }}</span>
        <span class="sp"></span>
        <button type="button" class="kb kb-ink kb-sm" @click="open = false">Done</button>
      </div>
    </div>
  </div>
</template>
