<script setup>
// AreaList - the "List of areas" card: the areas drawn on the bench, grouped by type, with each
// type changeable inline. The type is the only thing that decides an area's colour, so changing
// it here is the same as changing it anywhere -- and it moves the row into its new group.
//
// GROUPED, because a flat list stopped being scannable: the first thing a planner looks for is
// "where are my No-Go areas", and with a dozen areas on one plan the answer should not be
// "somewhere in this list". Groups appear in the same order as the type dropdown, and a type
// with no areas in it is left out rather than shown empty -- except a type this build does not
// know (saved by a newer one), which keeps its rows in an "Other" group instead of losing them.
//
// Each row previews the area's ACTUAL SHAPE (utils/areaOutline.js), not a symbol for its type,
// so the row and the polygon on the map are recognisably the same thing. Colour and the type
// dropdown still carry the type.
//
// Clicking a row selects that area -- the same selection as clicking its shape on the map --
// which is what the highlight shows.
//
// This component never writes to the database: it reports what changed and the page decides
// when to save (which, in this app, is always "when the planner locks something").
import { computed, ref, watch } from 'vue'
import { AREA_KINDS, AREA_NAME_MAX, areaColour, areaKind, isValidAreaName } from '../utils/areaKinds'
import { outlinePoints } from '../utils/areaOutline'
import { askConfirm } from '../composables/useNotify'

const props = defineProps({
  areas: { type: Array, default: () => [] },
  editable: { type: Boolean, default: false },
  selected: { type: String, default: '' }, // the id of the area being worked on, if any
  // Who else has each area open (composables/useBenchPresence.js). A row shows the same names in
  // the same colours as the chip on the shape, so the list and the map are recognisably telling
  // the planner the same thing. This component only draws it and decides nothing.
  presence: { type: Object, default: null },
  // An event's bench (020): every area is a zone with a CODE a plan and the radio refer to (FORMATION_1).
  showCode: { type: Boolean, default: false },
})

const emit = defineEmits(['area-updated', 'area-deleted', 'area-edit', 'area-duplicated'])

// Who has each area, keyed by the area's id. A plain object here rather than a ref, because a ref
// inside a plain object is not unwrapped in a template.
const watchers = computed(() => (props.presence ? props.presence.byObject.value : {}))

function watchersFor(areaId) {
  return watchers.value[areaId] || []
}

// Somebody else is WORKING on this area -- not merely looking at it -- so its row cannot be
// changed, and the name of whoever has it is already shown on the row. The database would refuse
// the change anyway (see 016_object_locks.sql); refusing it here means the planner never types
// something that cannot be saved.
function blocked(areaId) {
  return watchersFor(areaId).find((who) => who.active) || null
}

// A bar down the left of a row that somebody else has open, in their colour. The list is the one
// place a planner can see the whole bench at once, so "which of these is somebody on" belongs
// here as an edge rather than only as a badge inside the row.
function otherMark(areaId) {
  const who = watchersFor(areaId)
  return who.length ? { boxShadow: 'inset 3px 0 0 ' + who[0].colour } : null
}

const total = computed(() => props.areas.length)

// Everything a row needs, worked out once here rather than twice in the template. A row with no
// usable outline (fewer than 3 points) falls back to the type swatch.
function rowFor(area) {
  return {
    area,
    outline: outlinePoints(area.points),
    kind: areaKind(area.kind),
    colour: areaColour(area.kind),
  }
}

const groups = computed(() => {
  const buckets = new Map(AREA_KINDS.map((kind) => [kind.value, []]))
  const unknown = []
  for (const area of props.areas) {
    const bucket = buckets.get(area.kind)
    if (bucket) bucket.push(rowFor(area))
    else unknown.push(rowFor(area))
  }

  const out = []
  for (const kind of AREA_KINDS) {
    const rows = buckets.get(kind.value)
    if (rows.length) out.push({ key: kind.value, label: kind.label, colour: kind.colour, rows })
  }
  if (unknown.length) out.push({ key: '', label: 'Other', colour: '#6c757d', rows: unknown })
  return out
})

function rename(area, value) {
  const name = String(value || '').trim()
  if (name === area.name) return
  if (!isValidAreaName(name)) return // silently keep the old name; the select still works
  emit('area-updated', { id: area.id, patch: { name } })
}

function retype(area, value) {
  if (value === area.kind) return
  emit('area-updated', { id: area.id, patch: { kind: value } })
}

async function remove(area) {
  const ok = await askConfirm({
    title: 'Delete "' + area.name + '"?',
    message: props.showCode ? 'Its zone goes with it.' : '',
    confirmText: 'Delete',
    danger: true,
  })
  if (ok) emit('area-deleted', area.id)
}

// A zone code: capitals, digits and _ (the database checks the same and that it is not taken).
function recode(area, value) {
  const code = String(value || '').trim().toUpperCase().replace(/[^A-Z0-9_]+/g, '_').slice(0, 40)
  if (!code || code === area.code) return
  emit('area-updated', { id: area.id, patch: { code } })
}

// The padlock (QA 1 Nov): a locked area is pinned for every planner -- the map lets presses through it
// and the bench will not open it -- so its own fields are closed too, until it is unlocked here.
function toggleLock(area) {
  emit('area-updated', { id: area.id, patch: { locked: !area.locked } })
}

// One row open at a time. Opening an unlocked row also selects its shape on the map, as a click on a row always has.
const openId = ref(null)
watch(() => props.selected, (id) => {
  if (id) openId.value = id
})
const isOpen = (row) => openId.value === row.area.id
function pick(row) {
  if (!props.editable) return
  openId.value = isOpen(row) ? null : row.area.id
  if (openId.value && !row.area.locked) emit('area-edit', row.area.id)
}

</script>

<template>
  <div data-testid="area-list-card">
    <p v-if="total === 0" class="k2-empty" data-testid="no-areas">No areas yet.</p>

    <div v-else class="area-scroll" data-testid="area-list">
      <section v-for="group in groups" :key="group.key || 'other'">
        <div class="k2-sub" :data-testid="'area-group-' + (group.key || 'other')">{{ group.label }} ({{ group.rows.length }})</div>
        <div
          v-for="row in group.rows"
          :key="row.area.id"
          class="k2-area"
          :data-open="isOpen(row) ? 'true' : 'false'"
          :style="otherMark(row.area.id)"
          :data-testid="'area-row-' + row.area.name"
        >
          <div class="hd">
            <button type="button" class="k2-areaopen" :aria-expanded="editable ? (isOpen(row) ? 'true' : 'false') : null" :data-testid="'area-open-' + row.area.name" @click="pick(row)">
              <i class="k2-sw" :style="{ background: row.colour }"></i>
              <b>{{ row.area.name }}</b>
            </button>
            <!-- Who else has this area open: the same names in the same colours as the chip on the shape -->
            <span
              v-for="who in watchersFor(row.area.id)"
              :key="who.presenceId"
              class="badge rounded-pill area-who"
              :style="{ color: who.colour, borderColor: who.colour, background: who.colour + '22' }"
              :data-testid="'area-who-' + who.name"
            >
              {{ who.label }}
            </span>
            <span v-if="showCode && row.area.code" class="chip chip-soft" style="height: 22px">{{ row.area.code }}</span>
            <span v-if="!editable" class="mut" style="font-size: 12px">{{ row.kind.label }}</span>
            <button
              v-if="editable"
              type="button"
              class="k2-lock"
              :disabled="Boolean(blocked(row.area.id))"
              :aria-pressed="row.area.locked ? 'true' : 'false'"
              :aria-label="(row.area.locked ? 'Unlock ' : 'Lock ') + row.area.name"
              :title="row.area.locked ? 'Locked: it cannot be moved or edited. Press to unlock.' : 'Lock it so it cannot be moved by accident'"
              :data-testid="'area-lock-' + row.area.name"
              @click="toggleLock(row.area)"
            >
              <svg v-if="row.area.locked" class="ki" viewBox="0 1 24 24" aria-hidden="true"><path d="M6 11h12v10H6z" style="fill: currentColor"></path><path d="M8.5 11V8a3.5 3.5 0 0 1 7 0v3"></path></svg>
              <svg v-else class="ki" viewBox="0 1 24 24" aria-hidden="true"><path d="M6 11h12v10H6z"></path><path d="M8.5 11V8a3.5 3.5 0 0 1 6.9-.8"></path></svg>
            </button>
          </div>

          <!-- Expanded: its fields. The inputs and Delete wait while it is locked or someone else has it. -->
          <template v-if="editable && isOpen(row)">
            <div class="k2-ed">
              <input
                class="kin"
                :value="row.area.name"
                :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                :maxlength="AREA_NAME_MAX"
                :aria-label="'Name of ' + row.area.name"
                :data-testid="'area-name-' + row.area.name"
                @change="rename(row.area, $event.target.value)"
              />
              <!-- The zone code (event benches). Filled in by the database from the name when the area is first
                   saved, and kept through renames; a planner may change it. -->
              <input
                v-if="showCode"
                class="kin"
                :value="row.area.code || ''"
                :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                maxlength="40"
                placeholder="CODE"
                :aria-label="'Zone code of ' + row.area.name"
                :data-testid="'area-code-' + row.area.name"
                @change="recode(row.area, $event.target.value)"
              />
              <div class="ksel" style="width: 100%; grid-column: 1 / -1">
                <select
                  style="width: 100%"
                  :value="row.area.kind"
                  :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                  :aria-label="'Type of ' + row.area.name"
                  :data-testid="'area-kind-select-' + row.area.name"
                  @change="retype(row.area, $event.target.value)"
                >
                  <option v-for="kind in AREA_KINDS" :key="kind.value" :value="kind.value">{{ kind.label }}</option>
                </select>
              </div>
            </div>
            <div class="row" style="margin-top: 8px">
              <button type="button" class="k2-pillbtn" :aria-label="'Duplicate ' + row.area.name" :data-testid="'area-duplicate-' + row.area.name" @click="emit('area-duplicated', row.area)">Duplicate</button>
              <span class="sp"></span>
              <button
                type="button"
                class="k2-link danger"
                :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                :aria-label="'Delete ' + row.area.name"
                :data-testid="'area-delete-' + row.area.name"
                @click="remove(row.area)"
              >Delete</button>
            </div>
          </template>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
/* Same cap as the floor-plan list in AreaBench.vue: the rows scroll inside the card rather
   than stretching the column until the rest of the bench is off the screen. The two lists sit
   in one column, so they run out at the same height -- about seven rows. */
/* The padlock: the same square control as a floor plan's (AreaBench.vue). A locked row is greyed. */
.area-lock-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  padding: 0;
  flex: none;
}
.area-row-locked {
  background: var(--bs-tertiary-bg, var(--canvas));
}

.area-scroll {
  max-height: 20rem;
  overflow-y: auto;
  padding-right: 0.25rem;
  overscroll-behavior: contain;
}

/* One heading per type. It sticks to the top of the scrolling card while its own rows go past,
   on the card's own background so the rows cannot show through it. */
.area-group {
  position: sticky;
  top: 0;
  z-index: 1;
  display: flex;
  align-items: center;
  gap: 0.4rem;
  margin: 0;
  padding: 0.35rem 0.5rem 0.25rem;
  background: var(--bs-card-bg, #fff);
  font-size: 0.75rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--bs-secondary-color);
}

.area-kind-select {
  width: 7.5rem;
  flex-shrink: 0;
}
.area-row {
  padding-left: 0.5rem;
  padding-right: 0.5rem;
  border-radius: 0.375rem;
}
/* Only a planner can pick an area, so only a planner is offered the pointer that says so. */
.area-row-pickable {
  cursor: pointer;
}
/* The area being worked on. Clicking its shape on the map highlights this row, and clicking
   the row does the same as clicking the shape. */
.area-row-active {
  background: var(--bs-primary-bg-subtle);
}
/* A planner's row can be squeezed from both sides -- the thumbnail and the type dropdown are
   both fixed -- so the name gets a floor of its own. Once the row cannot fit any more, the
   dropdown and Delete wrap onto a second line instead of crushing the name to nothing. */
.area-name-input {
  min-width: 6rem;
}
.area-thumb {
  flex-shrink: 0;
  background: rgba(0, 0, 0, 0.04);
  border-radius: 3px;
}
/* A planner's badge, in their own colour for the text and the outline and at 13% for the fill:
   tinted rather than white-on-colour so it stays readable at both ends of the palette. */
.area-who {
  border: 1px solid;
  font-size: 0.65rem;
  font-weight: 600;
}
.area-swatch-square {
  width: 0.9rem;
  height: 0.9rem;
  border-radius: 2px;
  flex-shrink: 0;
}
.area-swatch-triangle {
  width: 0;
  height: 0;
  border-left: 0.45rem solid transparent;
  border-right: 0.45rem solid transparent;
  border-bottom: 0.8rem solid;
  flex-shrink: 0;
}
.area-code-input {
  max-width: 9.5rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  text-transform: uppercase;
}
</style>
