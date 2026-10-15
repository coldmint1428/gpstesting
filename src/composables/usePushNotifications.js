// Phone app only: push reminders from the server (Firebase Cloud Messaging).
//
// After login the phone registers with Firebase and saves its push token in Supabase
// (register_push_token). While an event is live, the server pushes "Event started - tap to
// share" to ICs who haven't shared yet: at the start, then every 10 min (max 6), and when a
// planner presses "Remind ICs". Pushes arrive even when the app is closed. Tapping one opens
// the event and starts sharing.
//
// Needs android/app/google-services.json from the Firebase console (see the checklist).
// Without it the app still works, just without push reminders.
//
// Library: @capacitor/push-notifications (MIT) - https://capacitorjs.com/docs/apis/push-notifications
import { ref } from 'vue'
import { Capacitor } from '@capacitor/core'
import { supabase } from '../lib/supabase'
import { toast } from './useNotify'

const isNative = Capacitor.isNativePlatform()
export const pushReady = ref(false) // this phone has a push token saved for the logged-in user

let pluginModule = null
let currentToken = null
let listenersAdded = false

// Returns the MODULE, not the plugin: a Capacitor plugin can't be returned from an async
// function (await checks it for .then(), which Capacitor answers with "not implemented")
async function loadPush() {
  if (!pluginModule) pluginModule = await import('@capacitor/push-notifications')
  return pluginModule
}

async function saveToken(token) {
  currentToken = token
  const { error } = await supabase.rpc('register_push_token', { p_token: token, p_platform: Capacitor.getPlatform() })
  pushReady.value = !error
  if (error) console.error('[push] could not save push token:', error.message)
}

// Call after login (and on every app start while logged in): asks for permission once,
// registers with Firebase and saves the token for this user.
export async function enablePush(router) {
  if (!isNative) return
  try {
    const PN = (await loadPush()).PushNotifications
    if (!listenersAdded) {
      listenersAdded = true
      await PN.addListener('registration', (t) => saveToken(t.value))
      await PN.addListener('registrationError', (err) => console.error('[push] registration failed:', JSON.stringify(err)))
      // Tapped a reminder or its "Start sharing" button: open that event and start sharing
      // (EventView handles ?share=1)
      await PN.addListener('pushNotificationActionPerformed', (action) => {
        const data = action.notification.data || {}
        if (data.kind === 'event-start' && data.eventId) {
          router.push({ name: 'event', params: { id: data.eventId }, query: { share: '1' } })
        }
      })
      // Arrived while the app is OPEN: the phone notification is drawn by ReminderMessagingService.java
      // (also when the app is closed); here we add an in-app toast
      await PN.addListener('pushNotificationReceived', showWhileOpen)
      // Android: reminders use their own channel so they can make a sound and pop up
      if (Capacitor.getPlatform() === 'android') {
        await PN.createChannel({
          id: 'event-start',
          name: 'Event start reminders',
          description: 'Reminds ICs to share their location when an event starts',
          importance: 5,
          visibility: 1,
        })
      }
    }

    let permission = await PN.checkPermissions()
    if (permission.receive === 'prompt' || permission.receive === 'prompt-with-rationale') {
      permission = await PN.requestPermissions()
    }
    if (permission.receive !== 'granted') return
    await PN.register() // answers through the 'registration' listener above
  } catch (err) {
    console.error('[push] could not enable push reminders:', err)
  }
}

function showWhileOpen(notification) {
  const data = notification.data || {}
  if (data.kind !== 'event-start') return
  toast((data.title || 'Event started') + '. ' + (data.body || 'Tap Start sharing.'), 'warning', 8000)
}

// Logout: this phone shouldn't get reminders for the old user any more
export async function disablePush() {
  if (!isNative || !currentToken) return
  try {
    await supabase.rpc('unregister_push_token', { p_token: currentToken })
  } catch {
    // offline: the token is replaced when the next person logs in on this phone
  }
  pushReady.value = false
}

// Already tapped / sharing now: remove this event's reminder from the notification shade
export async function clearPushReminders() {
  if (!isNative) return
  try {
    const PN = (await loadPush()).PushNotifications
    await PN.removeAllDeliveredNotifications()
  } catch {
    // nothing shown
  }
}

// Planner button: push a reminder now to every IC of the event who isn't sharing yet.
// start = true right after Start event now: the normal "Event started" push, sent at once.
export async function remindIcsNow(eventId, start = false) {
  const { data, error } = await supabase.functions.invoke('send-reminders', { body: { eventId, start } })
  if (error) {
    let message = error.message
    try {
      message = (await error.context.json()).error || message
    } catch {
      // keep the general message
    }
    throw new Error(message)
  }
  return data // { sent, failed }
}
