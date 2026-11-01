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
import { computed } from 'vue'
import { AREA_KINDS, AREA_NAME_MAX, areaColour, areaKind, isValidAreaName } from '../utils/areaKinds'
import { outlinePoints } from '../utils/areaOutline'
import { askConfirm } from '../composables/useNotify'

const props = defineProps({
  areas: { type: Array, default: () => [] },
  editable: { type: Boolean, default: false },
  selected: { type: String, default: '' }, // the id of the area being worked on, if any
  // What has been copied, so the Paste button can say whether it has anything to paste. The
  // clipboard itself lives on the page (composables/useBenchClipboard.js).
  clipboard: { type: Object, default: null },
  // Who else has each area open (composables/useBenchPresence.js). A row shows the same names in
  // the same colours as the chip on the shape, so the list and the map are recognisably telling
  // the planner the same thing. This component only draws it and decides nothing.
  presence: { type: Object, default: null },
  // An event's bench (020): every area is a zone with a CODE a plan and the radio refer to (FORMATION_1).
  showCode: { type: Boolean, default: false },
})

const emit = defineEmits(['area-updated', 'area-deleted', 'area-edit', 'area-copied', 'area-pasted'])

// Whether there is a copied area to paste, and what it is called -- so the button can promise
// exactly what it will make.
const copiedArea = computed(() => (props.clipboard ? props.clipboard.area.value : null))

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

function copy(row) {
  emit('area-copied', row.area)
}

// Paste is offered on the list as well as on the Areas panel, because the list is where the
// planner sees what they have: making a second one from the row in front of them is the obvious
// place for it.
function paste() {
  if (!copiedArea.value) return
  emit('area-pasted')
}
</script>

<template>
  <div class="card">
    <div class="card-body">
      <h2 class="h6 card-title d-flex align-items-center flex-wrap gap-2">
        <span>
          List of areas
          <span v-if="total > 0" class="badge text-bg-secondary ms-1" data-testid="area-count">
            {{ total }}
          </span>
        </span>
        <!-- Paste makes a second area out of the last one copied: same shape and type, a name of
             its own, and a position a short step away so the two are not stacked. -->
        <button
          v-if="editable"
          class="btn btn-sm btn-outline-secondary ms-auto py-0"
          :disabled="!copiedArea"
          :title="copiedArea ? 'Paste a copy of ' + copiedArea.name : 'Copy an area first'"
          data-testid="area-list-paste"
          @click.stop="paste"
        >
          Paste area
        </button>
      </h2>

      <p v-if="total === 0" class="small text-muted mb-0" data-testid="no-areas">
        No areas yet.
      </p>

      <div v-else class="area-scroll" data-testid="area-list">
        <section v-for="group in groups" :key="group.key || 'other'">
          <!-- The heading sticks to the top of the card while its own rows scroll past, so the
               list never leaves the reader wondering which type they are looking at. -->
          <h3 class="area-group" :data-testid="'area-group-' + (group.key || 'other')">
            <span class="area-swatch-square" :style="{ background: group.colour }"></span>
            {{ group.label }}
            <span class="badge text-bg-secondary ms-auto">{{ group.rows.length }}</span>
          </h3>

          <ul class="list-group list-group-flush">
            <li
              v-for="row in group.rows"
              :key="row.area.id"
              class="list-group-item py-2 area-row"
              :class="{
                'area-row-active': selected === row.area.id,
                'area-row-pickable': editable && !row.area.locked,
                'area-row-locked': row.area.locked,
              }"
              :style="otherMark(row.area.id)"
              :data-testid="'area-row-' + row.area.name"
              @click="editable && !row.area.locked && emit('area-edit', row.area.id)"
            >
              <div class="d-flex align-items-center gap-2 flex-wrap">
                <button
                  v-if="editable"
                  type="button"
                  class="btn btn-sm area-lock-btn"
                  :class="row.area.locked ? 'btn-secondary' : 'btn-outline-secondary'"
                  :disabled="Boolean(blocked(row.area.id))"
                  :aria-pressed="Boolean(row.area.locked)"
                  :aria-label="(row.area.locked ? 'Unlock ' : 'Lock ') + row.area.name"
                  :title="row.area.locked ? 'Locked: it cannot be moved or edited. Press to unlock.' : 'Lock it where it is, so it cannot be dragged by accident'"
                  :data-testid="'area-lock-' + row.area.name"
                  @click.stop="toggleLock(row.area)"
                >
                  <svg v-if="row.area.locked" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="currentColor"/><path d="M5 7V5a3 3 0 0 1 6 0v2" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>
                  <svg v-else viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M5 7V5a3 3 0 0 1 5.8-1" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>
                </button>
                <!-- The drawn shape, drawn small. -->
                <svg
                  v-if="row.outline"
                  class="area-thumb"
                  viewBox="0 0 30 30"
                  width="30"
                  height="30"
                  aria-hidden="true"
                >
                  <polygon
                    :points="row.outline"
                    :fill="row.colour"
                    fill-opacity="0.35"
                    :stroke="row.colour"
                    stroke-width="1.5"
                    stroke-linejoin="round"
                  />
                </svg>
                <!-- Fallback for a ring too small to draw (fewer than 3 points). -->
                <span
                  v-else-if="row.kind.icon === 'square'"
                  class="area-swatch-square"
                  :style="{ background: row.colour }"
                ></span>
                <span
                  v-else
                  class="area-swatch-triangle"
                  :style="{ borderBottomColor: row.colour }"
                ></span>

                <!-- Who else has this area open: the same names in the same colours as the chip on
                     the shape, so the list and the map tell the planner the same thing. -->
                <span
                  v-for="who in watchersFor(row.area.id)"
                  :key="who.presenceId"
                  class="badge rounded-pill area-who"
                  :style="{ color: who.colour, borderColor: who.colour, background: who.colour + '22' }"
                  :data-testid="'area-who-' + who.name"
                >
                  {{ who.label }}
                </span>

                <input
                  v-if="editable"
                  class="form-control form-control-sm flex-grow-1 area-name-input"
                  :value="row.area.name"
                  :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                  :maxlength="AREA_NAME_MAX"
                  :aria-label="'Name of ' + row.area.name"
                  :data-testid="'area-name-' + row.area.name"
                  @click.stop
                  @change="rename(row.area, $event.target.value)"
                />
                <span v-else class="flex-grow-1 text-truncate">{{ row.area.name }}</span>

                <!-- The zone code (event benches). Filled in by the database from the name when the
                     area is first saved, and kept through renames; a planner may change it. -->
                <input
                  v-if="showCode && editable"
                  class="form-control form-control-sm area-code-input"
                  :value="row.area.code || ''"
                  :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                  maxlength="40"
                  placeholder="CODE"
                  :aria-label="'Zone code of ' + row.area.name"
                  :data-testid="'area-code-' + row.area.name"
                  @click.stop
                  @change="recode(row.area, $event.target.value)"
                />
                <code v-else-if="showCode && row.area.code" class="small">{{ row.area.code }}</code>

                <select
                  v-if="editable"
                  class="form-select form-select-sm area-kind-select"
                  :value="row.area.kind"
                  :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                  :aria-label="'Type of ' + row.area.name"
                  :data-testid="'area-kind-select-' + row.area.name"
                  @click.stop
                  @change="retype(row.area, $event.target.value)"
                >
                  <option v-for="kind in AREA_KINDS" :key="kind.value" :value="kind.value">
                    {{ kind.label }}
                  </option>
                </select>
                <span v-else class="badge text-bg-secondary">{{ row.kind.label }}</span>

                <button
                  v-if="editable"
                  class="btn btn-sm btn-outline-secondary px-1"
                  :aria-label="'Copy ' + row.area.name"
                  :data-testid="'area-copy-' + row.area.name"
                  @click.stop="copy(row)"
                >
                  Copy
                </button>

                <button
                  v-if="editable"
                  class="btn btn-sm btn-link text-danger px-1"
                  :disabled="Boolean(blocked(row.area.id)) || Boolean(row.area.locked)"
                  :aria-label="'Delete ' + row.area.name"
                  :data-testid="'area-delete-' + row.area.name"
                  @click.stop="remove(row.area)"
                >
                  Delete
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
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
  background: var(--bs-tertiary-bg, #f4f4f2);
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
