<script setup>
// PlanProblems — everything wrong with the plan, as a list: one row per problem saying who, what, which frames, when and
// where, with the buttons that fix it. The words and the levels are planProblems'; the board does what is asked.
import { computed, ref } from 'vue'

const props = defineProps({
  // [{ id, level, kind, title, detail, fix, meta, actions, dismissed }]
  problems: { type: Array, default: () => [] },
  shownId: { type: String, default: '' },
  canEdit: { type: Boolean, default: false },
  busy: { type: Boolean, default: false },
})
defineEmits(['show', 'timeline', 'act', 'dismiss', 'restore', 'dismiss-all'])

const showDismissed = ref(false)
const errors = computed(() => props.problems.filter((p) => p.level === 'error'))
const warnings = computed(() => props.problems.filter((p) => p.level === 'warning' && !p.dismissed))
const dismissed = computed(() => props.problems.filter((p) => p.dismissed))
const count = (n, word) => n + ' ' + word + (n === 1 ? '' : 's')
const sections = computed(() => {
  const list = [
    { key: 'error', label: 'Errors', rows: errors.value },
    { key: 'warning', label: 'Warnings', rows: warnings.value },
  ]
  if (showDismissed.value) list.push({ key: 'dismissed', label: 'Dismissed', rows: dismissed.value })
  return list.filter((section) => section.rows.length)
})
</script>

<template>
  <section v-if="problems.length" class="pv-probs" data-testid="plan-problems" tabindex="-1">
    <header class="pv-probs-head">
      <h3 class="pv-probs-title">Problems</h3>
      <span v-if="errors.length" class="pv-probs-pill is-error" data-testid="problems-errors">{{ count(errors.length, 'error') }}</span>
      <span v-if="warnings.length" class="pv-probs-pill is-warning" data-testid="problems-warnings">{{ count(warnings.length, 'warning') }}</span>
      <span class="pv-probs-bulk">
        <button
          v-if="warnings.length"
          type="button"
          class="pv-pb"
          data-testid="problems-dismiss-all"
          @click="$emit('dismiss-all')"
        >Dismiss all</button>
      </span>
    </header>

    <p v-if="canEdit && errors.length" class="pv-probs-lock" data-testid="problems-lock">
      <strong>Plan locked.</strong> Fix the {{ errors.length === 1 ? 'error' : 'errors' }} to edit other frames or publish.
    </p>

    <div class="pv-probs-list">
      <template v-for="section in sections" :key="section.key">
        <h4 v-if="sections.length > 1" class="pv-probs-section">{{ section.label }}</h4>
        <article
          v-for="p in section.rows"
          :key="p.id"
          class="pv-prob"
          :class="['is-' + p.level, { 'is-shown': p.id === shownId, 'is-dismissed': p.dismissed }]"
          :data-testid="p.level === 'error' ? 'plan-problem' : 'plan-warning'"
          :data-kind="p.kind"
        >
          <span class="pv-prob-dot" aria-hidden="true"></span>
          <div class="pv-prob-body">
            <strong class="pv-prob-title">{{ p.title }}</strong>
            <span v-if="p.detail" class="pv-prob-detail">{{ p.detail }}</span>
            <span v-if="p.fix" class="pv-prob-fix">{{ p.fix }}</span>
            <span class="pv-prob-meta" data-testid="problem-meta">{{ p.meta }}</span>
          </div>
          <div class="pv-prob-actions">
            <button type="button" class="pv-pb is-text" data-testid="problem-show" @click="$emit('show', p)">Map</button>
            <button type="button" class="pv-pb is-text" data-testid="problem-timeline" @click="$emit('timeline', p)">Timeline</button>
            <template v-if="canEdit">
              <button
                v-for="action in p.actions"
                :key="action.key"
                type="button"
                class="pv-pb"
                :data-testid="action.testid"
                :disabled="busy"
                @click="$emit('act', p, action.key)"
              >{{ action.label }}</button>
            </template>
            <button
              v-if="p.level === 'warning' && !p.dismissed"
              type="button"
              class="pv-pb is-icon"
              data-testid="problem-dismiss"
              aria-label="Dismiss this warning"
              title="Dismiss"
              @click="$emit('dismiss', p)"
            >
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18" /></svg>
            </button>
            <button
              v-if="p.dismissed"
              type="button"
              class="pv-pb is-text"
              data-testid="problem-restore"
              @click="$emit('restore', p)"
            >Bring back</button>
          </div>
        </article>
      </template>
      <p v-if="!sections.length" class="pv-probs-clear">No open problems.</p>
    </div>

    <button
      v-if="dismissed.length"
      type="button"
      class="pv-probs-toggle"
      data-testid="problems-dismissed"
      @click="showDismissed = !showDismissed"
    >{{ showDismissed ? 'Hide dismissed' : 'Show ' + dismissed.length + ' dismissed' }}</button>
  </section>
</template>
