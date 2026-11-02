// The month grid of the Rehearsals calendar: plain date arithmetic, in Singapore time like every other date in the app.
// A day is its key ("2026-11-02"), so a rehearsal lands on the day Singapore says it is, whatever the viewer's clock says.
import { sgtParts } from './time'

const pad = (n) => String(n).padStart(2, '0')

// "2026-11-02": the Singapore day a moment falls on
export const dayKey = (date) => sgtParts(date).date

// { year: 2026, month: 11 }: the Singapore month a moment falls on
export function monthOf(date) {
  const [year, month] = dayKey(date).split('-').map(Number)
  return { year, month }
}

export function shiftMonth({ year, month }, by) {
  const d = new Date(Date.UTC(year, month - 1 + by, 1))
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 }
}

// "November 2026"
export function monthTitle({ year, month }) {
  return new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString('en-SG', { timeZone: 'UTC', month: 'long', year: 'numeric' })
}

/** The weeks that show a month, Monday first, with the neighbouring months' days filling the first and last week. */
export function monthGrid({ year, month }) {
  const first = new Date(Date.UTC(year, month - 1, 1))
  const backToMonday = (first.getUTCDay() + 6) % 7
  const weeks = []
  const d = new Date(first.getTime() - backToMonday * 86400000)
  do {
    const week = []
    for (let i = 0; i < 7; i += 1) {
      week.push({
        key: d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()),
        day: d.getUTCDate(),
        inMonth: d.getUTCMonth() === month - 1,
      })
      d.setUTCDate(d.getUTCDate() + 1)
    }
    weeks.push(week)
  } while (d.getUTCMonth() === month - 1)
  return weeks
}
