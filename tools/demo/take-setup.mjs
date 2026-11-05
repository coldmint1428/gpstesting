// The take's set-up steps, as commands (docs/demo/RECORDING.md):
//
//   node tools/demo/take-setup.mjs add-phone <event id> <username>   the phone's account joins P&C Contingent 3
//   node tools/demo/take-setup.mjs names on                          the QA accounts show realistic names on screen
//   node tools/demo/take-setup.mjs names off                         ...and back to their QA names (the tests need them)
//
// Each QA account renames itself (a person may change their own display name), so no admin key is needed.
import { clientFor } from '../../e2e/support/session.js'

const NAMES = {
  root: ['QA Root', 'Komin Chow'],
  planner: ['QA Planner', 'Lt Marcus Lee'],
  ic1: ['QA Ic1', 'Sgt Daniel Tan'],
  member: ['QA Member', 'Cadet Aisha Rahman'],
}
const [cmd, a, b] = process.argv.slice(2)

if (cmd === 'add-phone') {
  if (!a || !b) throw new Error('usage: add-phone <event id> <username>')
  const { sb } = await clientFor('root')
  // A user id works too: the root sees a profile only once it shares an event with it
  const user = /^[0-9a-f-]{36}$/.test(b) ? { id: b } : (await sb.from('profiles').select('id').eq('username', b).maybeSingle()).data
  if (!user) throw new Error(`no account with the username ${b} that the root can see: pass the account's user id instead`)
  const group = (await sb.from('groups').select('id').eq('event_id', a).eq('name', 'P&C Contingent 3').single()).data
  const { error } = await sb.rpc('add_event_member', { p_event_id: a, p_user_id: user.id, p_group_id: group.id })
  console.log(error ? 'error: ' + error.message : `${b} is in P&C Contingent 3 (user id ${user.id}: pass it to the recorder as --phone-user)`)
} else if (cmd === 'names') {
  const on = a === 'on'
  if (!on && a !== 'off') throw new Error('usage: names on | names off')
  for (const [who, [qaName, realName]] of Object.entries(NAMES)) {
    const { sb, user } = await clientFor(who)
    const { error } = await sb.from('profiles').update({ display_name: on ? realName : qaName }).eq('id', user.id)
    console.log(`${who}: ${error ? 'error: ' + error.message : on ? realName : qaName}`)
  }
} else if (cmd === 'role') {
  // Segment 01 shows a Group Admin: the phone's account is one for that take (member again for the rest)
  const [, ev, user, role] = process.argv.slice(2)
  if (!ev || !user || !role) throw new Error('usage: role <event id> <user id> <member|admin|planner>')
  const { sb } = await clientFor('root')
  const { error } = await sb.rpc('set_member_role', { p_event_id: ev, p_user_id: user, p_new_role: role })
  console.log(error ? 'error: ' + error.message : `${user} is now ${role}`)
} else {
  throw new Error('commands: add-phone <event id> <username> | names on | names off | role <event id> <user id> <role>')
}
