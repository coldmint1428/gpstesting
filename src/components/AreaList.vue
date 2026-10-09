<script setup>
// AreaList - the "List of areas" card: one row per drawn area, with its type changeable
// inline. The type is the only thing that decides an area's colour, so changing it here is
// the same as changing it anywhere.
//
// Each row previews the area's ACTUAL SHAPE (utils/areaOutline.js), not a symbol for its
// type, so the row and the polygon on the map are recognisably the same thing. Colour and
// the type dropdown still carry the type.
//
// Clicking a row selects that area -- the same selection as clicking its shape on the map --
// which is what the highlight shows.
//
// This component never writes to the database: it reports what changed and the page
// decides when to save (which, in this app, is always "when the planner locks something").
import { computed } from 'vue'
import { AREA_KINDS, AREA_NAME_MAX, areaColour, areaKind, isValidAreaName } from '../utils/areaKinds'
import { outlinePoints } from '../utils/areaOutline'

const props = defineProps({
  areas: { type: Array, default: () => [] },
  editable: { type: Boolean, default: false },
  selected: { type: String, default: '' }, // the id of the area being worked on, if any
})

const emit = defineEmits(['area-updated', 'area-deleted', 'area-edit'])

// The outline is computed once per row here rather than twice in the template, and a row
// with no usable outline (fewer than 3 points) falls back to the type swatch.
const rows = computed(() =>
  props.areas.map((area) => ({
    area,
    outline: outlinePoints(area.points),
    kind: areaKind(area.kind),
    colour: areaColour(area.kind),
  })),
)

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
</script>

<template>
  <div class="card">
    <div class="card-body">
      <h2 class="h6 card-title">List of areas</h2>

      <p v-if="rows.length === 0" class="small text-muted mb-0" data-testid="no-areas">
        No areas yet.
      </p>

      <ul v-else class="list-group list-group-flush" data-testid="area-list">
        <li
          v-for="row in rows"
          :key="row.area.id"
          class="list-group-item py-2 area-row"
          :class="{ 'area-row-active': selected === row.area.id, 'area-row-pickable': editable }"
          :data-testid="'area-row-' + row.area.name"
          @click="editable && emit('area-edit', row.area.id)"
        >
          <div class="d-flex align-items-center gap-2">
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
              class="form-control form-control-sm flex-grow-1"
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
    </div>
  </div>
</template>

<style scoped>
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
