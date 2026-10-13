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

const props = defineProps({
  areas: { type: Array, default: () => [] },
  editable: { type: Boolean, default: false },
  selected: { type: String, default: '' }, // the id of the area being worked on, if any
  // What has been copied, so the Paste button can say whether it has anything to paste. The
  // clipboard itself lives on the page (composables/useBenchClipboard.js).
  clipboard: { type: Object, default: null },
})

const emit = defineEmits(['area-updated', 'area-deleted', 'area-edit', 'area-copied', 'area-pasted'])

// Whether there is a copied area to paste, and what it is called -- so the button can promise
// exactly what it will make.
const copiedArea = computed(() => (props.clipboard ? props.clipboard.area.value : null))

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

function remove(area) {
  if (!confirm('Delete the area "' + area.name + '"?')) return
  emit('area-deleted', area.id)
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
              :class="{ 'area-row-active': selected === row.area.id, 'area-row-pickable': editable }"
              :data-testid="'area-row-' + row.area.name"
              @click="editable && emit('area-edit', row.area.id)"
            >
              <div class="d-flex align-items-center gap-2 flex-wrap">
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

                <input
                  v-if="editable"
                  class="form-control form-control-sm flex-grow-1 area-name-input"
                  :value="row.area.name"
                  :maxlength="AREA_NAME_MAX"
                  :aria-label="'Name of ' + row.area.name"
                  :data-testid="'area-name-' + row.area.name"
                  @click.stop
                  @change="rename(row.area, $event.target.value)"
                />
                <span v-else class="flex-grow-1 text-truncate">{{ row.area.name }}</span>

                <select
                  v-if="editable"
                  class="form-select form-select-sm area-kind-select"
                  :value="row.area.kind"
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
</style>
