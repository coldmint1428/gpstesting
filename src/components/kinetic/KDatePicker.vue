<script setup>
// A date field with the design's calendar instead of the browser's popup. The value stays 'YYYY-MM-DD'.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  modelValue: { type: String, default: '' },
  label: { type: String, required: true },
  min: { type: String, default: '' }, // days before this are disabled
  testid: { type: String, default: null },
})
const emit = defineEmits(['update:modelValue'])

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const DOWS = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']
const pad = (n) => String(n).padStart(2, '0')
const iso = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
const parse = (v) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || '')
  return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null
}

const open = ref(false)
const wrap = ref(null)
const shown = ref(new Date()) // the first of the month on screen
const cursor = ref('') // the day the arrow keys are on
const today = iso(new Date())

const text = computed(() => {
  const d = parse(props.modelValue)
  if (!d) return 'Pick a date'
  return d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }).replace(',', '')
})
const title = computed(() => MONTHS[shown.value.getMonth()] + ' ' + shown.value.getFullYear())
const days = computed(() => {
  const y = shown.value.getFullYear()
  const m = shown.value.getMonth()
  const lead = (new Date(y, m, 1).getDay() + 6) % 7
  const out = []
  for (let i = 0; i < 42; i++) {
    const d = new Date(y, m, 1 - lead + i)
    if (i >= 35 && d.getMonth() !== m) break
    const v = iso(d)
    out.push({ v, n: d.getDate(), out: d.getMonth() !== m, disabled: !!props.min && v < props.min, aria: d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear() })
  }
  return out
})
function show(date) {
  shown.value = new Date(date.getFullYear(), date.getMonth(), 1)
}
function toggle() {
  open.value = !open.value
  if (open.value) {
    const d = parse(props.modelValue) || new Date()
    show(d)
    cursor.value = iso(d)
    focusCursor()
  }
}
function focusCursor() {
  nextTick(() => {
    const el = wrap.value && wrap.value.querySelector('[data-day="' + cursor.value + '"]')
    if (el) el.focus()
  })
}
function step(delta) {
  show(new Date(shown.value.getFullYear(), shown.value.getMonth() + delta, 1))
}
function pick(v) {
  emit('update:modelValue', v)
  open.value = false
}
function onKey(event) {
  const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }
  if (event.key in moves) {
    event.preventDefault()
    const d = parse(cursor.value) || new Date()
    d.setDate(d.getDate() + moves[event.key])
    cursor.value = iso(d)
    show(d)
    focusCursor()
  } else if (event.key === 'Escape') {
    event.stopPropagation()
    open.value = false
  }
}
function away(event) {
  if (open.value && wrap.value && !wrap.value.contains(event.target)) open.value = false
}
onMounted(() => document.addEventListener('pointerdown', away))
onBeforeUnmount(() => document.removeEventListener('pointerdown', away))
watch(() => props.modelValue, (v) => { if (open.value && parse(v)) show(parse(v)) })
</script>

<template>
  <div ref="wrap" class="wrapm">
    <button type="button" class="k2-fbtn" :aria-expanded="open ? 'true' : 'false'" :aria-label="label" :data-testid="testid" @click="toggle">
      <svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16v15H4zM4 10h16M9 3v4M15 3v4"></path></svg><span>{{ text }}</span>
    </button>
    <div v-if="open" class="k2-cal" role="dialog" aria-label="Choose a date" @keydown="onKey">
      <div class="row" style="margin-bottom: 8px">
        <b class="U" style="font-size: 16px; letter-spacing: -0.04em; flex: 1">{{ title }}</b>
        <button type="button" class="ib" style="width: 34px; height: 34px" aria-label="Previous month" @click="step(-1)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m15 18-6-6 6-6"></path></svg></button>
        <button type="button" class="ib" style="width: 34px; height: 34px" aria-label="Next month" @click="step(1)"><svg class="ki" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6"></path></svg></button>
      </div>
      <div class="k2-cal-grid">
        <span v-for="d in DOWS" :key="d" class="dow">{{ d }}</span>
        <button
          v-for="d in days"
          :key="d.v"
          type="button"
          class="k2-day"
          :class="{ out: d.out, today: d.v === today, sel: d.v === modelValue }"
          :disabled="d.disabled"
          :aria-pressed="d.v === modelValue ? 'true' : 'false'"
          :aria-label="d.aria"
          :tabindex="d.v === cursor ? 0 : -1"
          :data-day="d.v"
          @click="pick(d.v)"
        >{{ d.n }}</button>
      </div>
      <div class="row" style="margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--line)">
        <button type="button" class="k2-link" :disabled="!!min && today < min" @click="pick(today)">Today</button>
        <span class="sp"></span>
        <button type="button" class="kb kb-ink kb-sm" @click="open = false">Done</button>
      </div>
    </div>
  </div>
</template>
