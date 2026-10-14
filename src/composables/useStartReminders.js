// Phone app only: "Event started - tap to share your location" reminders for ICs.
//
// When the app sees that an event where I'm an IC has a scheduled start, it sets a phone
// alarm for that time (Capacitor Local Notifications). The reminder appears even if the app
// is closed, and stays (ongoing, not removed when tapped) until I start sharing. Tapping it
// opens the event and starts sharing.
//
// This is the fallback when server push (usePushNotifications.js, Firebase) isn't available:
//  - the phone only learns about a schedule when the app is opened after it was set
//  - "Start event now" pressed by a planner doesn't reach a closed app
//  - Android 14+ lets people swipe most notifications away; iPhones always do
//
// Library: @capacitor/local-notifications (MIT) - https://capacitorjs.com/docs/apis/local-notifications
import { Capacitor } from '@capacitor/core'
import { supabase } from '../lib/supabase'
import { pushReady } from './usePushNotifications'

const isNative = Capacitor.isNativePlatform()
const KIND = 'event-start'

// Returns the MODULE, not the plugin: a Capacitor plugin can't be returned from an async
// function (await checks it for .then(), which Capacitor answers with "not implemented")
let pluginModule = null
async function loadNotifications() {
  if (!pluginModule) pluginModule = await import('@capacitor/local-notifications')
  return pluginModule
}

// Same notification id for the same event every time (32-bit number from the event id)
function idFor(eventId) {
  let hash = 0
  for (const c of eventId) hash = (hash * 31 + c.charCodeAt(0)) | 0
  return Math.abs(hash % 2000000000) + 1
}

// Remove both a waiting alarm and a reminder already showing
async function remove(LN, ids) {
  if (!ids.length) return
  const list = ids.map((id) => ({ id }))
  await LN.cancel({ notifications: list })
  await LN.removeDeliveredNotifications({ notifications: list })
}

// Set alarms for every scheduled start of my IC events; drop reminders that are no longer needed
// (start cancelled, event ended, or I'm already sharing for that event).
export async function syncStartReminders(userId, sharingEventId = null) {
  if (!isNative || !userId) return
  // Server push is set up on this phone: it reminds at the start and keeps reminding, so
  // drop the phone alarms instead of showing two reminders
  if (pushReady.value) return clearAllStartReminders()
  try {
    const LN = (await loadNotifications()).LocalNotifications

    const { data: myGroups, error: e1 } = await supabase
      .from('group_members')
      .select('event_id')
      .eq('user_id', userId)
      .eq('is_ic', true)
    if (e1) throw e1
    const eventIds = myGroups.map((g) => g.event_id)

    let open = []
    if (eventIds.length) {
      const { data, error } = await supabase
        .from('event_sessions')
        .select('event_id, starts_at, events (name)')
        .in('event_id', eventIds)
        .is('ended_at', null)
      if (error) throw error
      open = data
    }

    const now = Date.now()
    const wanted = new Map() // id -> notification to schedule
    const keepShowing = new Set() // live events I'm not sharing for yet: keep the reminder on screen
    for (const s of open) {
      const id = idFor(s.event_id)
      const at = new Date(s.starts_at).getTime()
      if (at > now) {
        wanted.set(id, {
          id,
          title: 'Event started: ' + (s.events ? s.events.name : 'your event'),
          body: 'Tap Start sharing to share your location with the planners.',
          schedule: { at: new Date(at), allowWhileIdle: true },
          ongoing: true, // Android: can't be swiped away (until Android 14)
          autoCancel: false, // stays after tapping, until sharing really starts
          smallIcon: 'ic_stat_location',
          actionTypeId: KIND,
          isExactNotification: await canBeExact(LN),
          extra: { kind: KIND, eventId: s.event_id },
        })
      } else if (s.event_id !== sharingEventId) {
        keepShowing.add(id)
      }
    }

    // Our pending alarms + reminders on screen that aren't wanted any more
    const pending = (await LN.getPending()).notifications.filter((n) => n.extra && n.extra.kind === KIND)
    const delivered = (await LN.getDeliveredNotifications()).notifications.filter(
      (n) => n.extra && n.extra.kind === KIND,
    )
    const stale = [
      ...pending.filter((n) => !wanted.has(n.id)).map((n) => n.id),
      ...delivered.filter((n) => !keepShowing.has(n.id)).map((n) => n.id),
    ]
    await remove(LN, stale)

    if (wanted.size) {
      const permission = await LN.checkPermissions()
      if (permission.display !== 'granted') {
        const asked = await LN.requestPermissions()
        if (asked.display !== 'granted') return
      }
      // "Start sharing" button on the reminder (tapping it = same as tapping the reminder)
      await LN.registerActionTypes({
        types: [{ id: KIND, actions: [{ id: 'start-sharing', title: 'Start sharing', foreground: true }] }],
      })
      await LN.schedule({ notifications: [...wanted.values()] }) // same id = replaces the old alarm
    }
  } catch (err) {
    console.error('[reminders] could not update start reminders:', err)
  }
}

// Exact alarms need "Alarms & reminders" permission (Android 12+). Without it the reminder
// can arrive a few minutes late, but we never pop up the settings screen by ourselves.
let exactAllowed = null
async function canBeExact(LN) {
  if (exactAllowed === null) {
    try {
      exactAllowed = (await LN.checkExactNotificationSetting()).exact_alarm === 'granted'
    } catch {
      exactAllowed = false
    }
  }
  return exactAllowed
}

// For a button: opens Android's "Alarms & reminders" setting for this app
export async function allowExactReminders() {
  if (!isNative) return
  const LN = (await loadNotifications()).LocalNotifications
  const result = await LN.changeExactNotificationSetting()
  exactAllowed = result.exact_alarm === 'granted'
  return exactAllowed
}

export async function exactRemindersAllowed() {
  if (!isNative || Capacitor.getPlatform() !== 'android') return true
  return canBeExact((await loadNotifications()).LocalNotifications)
}

// Started sharing (or event over): this event's reminder can go
export async function clearStartReminder(eventId) {
  if (!isNative) return
  try {
    await remove((await loadNotifications()).LocalNotifications, [idFor(eventId)])
  } catch (err) {
    console.error('[reminders] could not clear reminder:', err)
  }
}

// Logout: nobody to remind
export async function clearAllStartReminders() {
  if (!isNative) return
  try {
    const LN = (await loadNotifications()).LocalNotifications
    const pending = (await LN.getPending()).notifications.filter((n) => n.extra && n.extra.kind === KIND)
    const delivered = (await LN.getDeliveredNotifications()).notifications.filter((n) => n.extra && n.extra.kind === KIND)
    await remove(LN, [...pending, ...delivered].map((n) => n.id))
  } catch (err) {
    console.error('[reminders] could not clear reminders:', err)
  }
}

// Tapping a reminder opens that event and starts sharing (once per app launch)
let listening = false
export async function listenForReminderTaps(router) {
  if (!isNative || listening) return
  listening = true
  const LN = (await loadNotifications()).LocalNotifications
  LN.addListener('localNotificationActionPerformed', (action) => {
    const extra = action.notification.extra
    if (extra && extra.kind === KIND && extra.eventId) {
      router.push({ name: 'event', params: { id: extra.eventId }, query: { share: '1' } })
    }
  })
}
