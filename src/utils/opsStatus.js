// How a movement's status looks everywhere in the ops view (merger Stage 7): always a word and a symbol as well as a
// colour (colour-blind planners, ground rules), and how bad it is (the worst one colours a cluster / chip).
import { mmss } from '../composables/useShow'

export const STATUS = {
  late: { label: 'Late', symbol: '■', cls: 'ops-late', colour: '#b91c1c', rank: 5 },
  no_signal: { label: 'No signal', symbol: '◌', cls: 'ops-nosig', colour: '#64748b', rank: 4 },
  at_risk: { label: 'At risk', symbol: '▲', cls: 'ops-risk', colour: '#b45309', rank: 3 },
  on_track: { label: 'On track', symbol: '●', cls: 'ops-ok', colour: '#0f766e', rank: 2 },
  arrived_late: { label: 'Arrived late', symbol: '✓', cls: 'ops-late-done', colour: '#9a3412', rank: 1 },
  missed: { label: 'Missed', symbol: '✕', cls: 'ops-missed', colour: '#7f1d1d', rank: 1 },
  arrived: { label: 'Arrived', symbol: '✓', cls: 'ops-done', colour: '#15803d', rank: 0 },
  pending: { label: 'Waiting', symbol: '…', cls: 'ops-wait', colour: '#94a3b8', rank: 0 },
  skipped: { label: 'Skipped', symbol: '–', cls: 'ops-wait', colour: '#94a3b8', rank: 0 },
}

// The statuses the summary bar counts (one per group: its active movement) and the queue shows
export const LIVE_STATUSES = ['on_track', 'at_risk', 'late', 'no_signal']
export const PROBLEMS = ['late', 'no_signal', 'at_risk']

export function statusOf(key) {
  return STATUS[key] || STATUS.pending
}

// "No signal" from the engine covers two different situations, and planners read them differently: a group whose ICs
// have NOT STARTED sharing this session (nobody pressed Share yet) and one whose ICs WERE sharing and went quiet. The board
// counts both kinds of IC per group (sharing = heard in the last 2 min, no_signal = shared before but quiet since), so a
// group with neither has simply not started. Same urgency and colour; different words.
export function notSharingYet(row) {
  return !!row && row.status === 'no_signal' && !row.sharing && !row.no_signal
}
export function statusLabel(row) {
  return notSharingYet(row) ? 'Not sharing yet' : statusOf(row.status).label
}
export function statusSymbol(row) {
  return notSharingYet(row) ? '○' : statusOf(row.status).symbol
}

// "■ Late +0:28", "▲ At risk · 12 s spare", "◌ No signal", "✓ Arrived 18:03:12"
export function statusText(row) {
  const s = statusOf(row.status)
  if (row.status === 'late' || row.status === 'arrived_late' || row.status === 'missed') {
    return s.symbol + ' ' + s.label + (row.late_s ? ' +' + mmss(row.late_s) : '')
  }
  if (row.status === 'at_risk' && row.spare_s != null) return s.symbol + ' ' + s.label + ' · ' + row.spare_s + ' s spare'
  return statusSymbol(row) + ' ' + statusLabel(row)
}

// How bad, for sorting: a group that told the planners it is delayed counts as at least "no signal"
function urgencyRank(r) {
  return Math.max(statusOf(r.status).rank, r.delay_at ? 4 : 0)
}

// Most urgent first: late (soonest deadline first), then reported delays and no signal, then at risk (least spare first)
export function urgency(a, b) {
  const r = urgencyRank(b) - urgencyRank(a)
  if (r) return r
  if (a.status === 'at_risk') return (a.spare_s ?? 0) - (b.spare_s ?? 0)
  return new Date(a.deadline || 0) - new Date(b.deadline || 0)
}
