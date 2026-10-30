// The QA event the signed-in tests share: made by qa_root through the same RPC the wizard uses, with every role in it.
//   Alpha: qa_admin (group admin), qa_ic1 + qa_ic2 (ICs), qa_member
//   Bravo: nobody yet (an empty group, for scoping checks)
//   qa_planner: planner, qa_marshal: marshal, qa_outsider: not in the event
import { clientFor } from './session.js'

export const QA_EVENT_PREFIX = 'QA-'

export async function ids(...names) {
  const out = {}
  for (const n of names) out[n] = (await clientFor(n)).user.id
  return out
}

/** Make a fresh QA event (name gets a time stamp) and return { eventId, joinCode, groups: {Alpha, Bravo} }. */
export async function makeQaEvent(label = 'Functional', { startsAt = new Date(Date.now() + 3600_000), hours = 6 } = {}) {
  const { sb } = await clientFor('root')
  const u = await ids('planner', 'admin', 'ic1', 'ic2', 'member', 'marshal')
  const stamp = new Date().toISOString().slice(5, 16).replace('T', ' ')
  const { data: eventId, error } = await sb.rpc('create_event_with_setup', {
    p_event: { name: `${QA_EVENT_PREFIX}${label} ${stamp}`, venue: 'Padang, Singapore', description: 'Made by the QA test suite; deleted after the run.',
      starts_at: startsAt.toISOString(), ends_at: new Date(startsAt.getTime() + hours * 3600_000).toISOString() },
    p_members: [
      { user_id: u.planner, role: 'planner' },
      { user_id: u.marshal, role: 'marshal' },
      { user_id: u.admin, role: 'participant' },
      { user_id: u.ic1, role: 'participant' },
      { user_id: u.ic2, role: 'participant' },
      { user_id: u.member, role: 'participant' },
    ],
    p_groups: [
      {
        name: 'Alpha',
        colour: '#0072B2',
        members: [
          { user_id: u.admin, is_admin: true, is_ic: false },
          { user_id: u.ic1, is_admin: false, is_ic: true },
          { user_id: u.ic2, is_admin: false, is_ic: true },
          { user_id: u.member, is_admin: false, is_ic: false },
        ],
      },
      { name: 'Bravo', colour: '#009E73', members: [] },
    ],
  })
  if (error) throw new Error('create_event_with_setup: ' + error.message)
  const id = typeof eventId === 'object' && eventId ? eventId.event_id || eventId.id : eventId
  const { data: ev } = await sb.from('events').select('id, join_code').eq('id', id).single()
  const { data: groups } = await sb.from('groups').select('id, name').eq('event_id', id)
  return { eventId: id, joinCode: ev.join_code, groups: Object.fromEntries(groups.map((g) => [g.name, g.id])) }
}

/** Delete every QA- event qa_root made (the overview's delete, through the API). */
export async function deleteQaEvents() {
  const { sb, user } = await clientFor('root')
  const { data } = await sb.from('events').select('id, name').eq('created_by', user.id).like('name', QA_EVENT_PREFIX + '%')
  for (const ev of data || []) await sb.from('events').delete().eq('id', ev.id)
  return (data || []).length
}
