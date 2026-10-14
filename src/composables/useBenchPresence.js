// useBenchPresence - who else is on the bench, and what each of them has hold of.
//
// One row per open page in public.layout_presence (015), written straight from here and streamed
// back to everyone through Realtime. This composable owns THIS TAB's row: it joins, beats, says
// what is selected, and leaves. Everything else it only reads.
//
// It knows nothing about who may edit what. Presence is a HINT -- it is what lets the bench say
// "Ali is on this area" before anybody presses anything -- and the only thing that will ever
// decide a refusal is the database, when a write is attempted (step 8). A display must never be
// the authority: presence rows are written by browsers, so they can be stale, and a page that
// trusted them would happily let two planners drag the same shape.
//
// THREE DECISIONS ARE DELIBERATE, and each was a real fork rather than a default:
//
// 1. THE TAG IS PER TAB, NOT PER PLANNER. Two tabs of one account are two planners as far as the
//    bench is concerned, which is the entire point: the bench's oldest bug was that a second
//    browser of the same login was indistinguishable from the first one. The tag is minted per
//    PAGE LOAD (not kept in sessionStorage, which a duplicated tab copies), and the row is deleted
//    as the page closes, so a reload does not leave a ghost behind. It is kept PER USER ID too, because
//    a login that changes inside one tab must not inherit the previous planner's row -- the RLS
//    policy would silently refuse the write and the new planner would be invisible.
//
// 2. THE TAG IS NOT A CREDENTIAL. Nothing is authorised by it, and that is exactly what makes
//    this table publishable when public.layout_claims is not: the claim's token IS its authority,
//    so any select policy on that table would hand the bench to every signed-in user. A planner
//    who learns somebody's presence tag has learned nothing at all.
//
// 3. STALENESS IS MEASURED AGAINST THE FRESHEST ROW, NOT AGAINST THIS BROWSER'S CLOCK. Every live
//    page beats every ten seconds, so the newest row on the bench is the best reading of "now"
//    available -- and a phone whose clock is four minutes out then sees the bench as everyone
//    else sees it, instead of seeing all of its colleagues as ghosts. The database cannot be the
//    arbiter (it would have to sort live from dead on every read), so the rule is the simple one:
//    a row that has fallen 45 seconds behind the newest row is gone. That is what a tab which has
//    been hidden for a minute looks like, and hiding is exactly when a page stops beating.
import { computed, onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'
import { uuid4 } from '../utils/uuid'
import { sendOnExit } from '../utils/exitBeacon'

const BEAT_MS = 10 * 1000 // how often this tab says it is still here
const STALE_MS = 45 * 1000 // behind the freshest row on the bench: gone

// A planner's colour, derived from their user id, so it is the same colour in every window, on
// every screen, with nobody having to agree on one or store it anywhere. Eight hues that stay
// apart from each other and from the area colours, which are what the shapes themselves use.
const COLOURS = ['#0d6efd', '#d63384', '#198754', '#fd7e14', '#6f42c1', '#0dcaf0', '#b02a37', '#6610f2']

export function plannerColour(userId) {
  const text = String(userId || '')
  let hash = 0
  for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) >>> 0
  return COLOURS[hash % COLOURS.length]
}

// The tag has to be a real uuid: layout_presence.presence_id is a uuid column. It is an identifier
// and never a secret, but it still has to be the right SHAPE, which is what utils/uuid.js is for --
// crypto.randomUUID() alone would leave every plain-http origin unable to announce itself at all.
//
// ONE TAG PER PAGE LOAD (per account). It used to live in sessionStorage so a reload reused its row --
// but a duplicated tab gets a COPY of sessionStorage, and two windows then shared one row and one name
// chip. A fresh tag per load cannot be shared; the row of the page that closed is deleted as it closes
// (see onPageHide), so a reload does not leave a ghost of itself either.
const tags = new Map()

function tabTag(userId) {
  if (!tags.has(userId)) tags.set(userId, uuid4())
  return tags.get(userId)
}

function readRows(data) {
  return (data || []).map((row) => ({
    presenceId: row.presence_id,
    userId: row.user_id,
    name: row.display_name || 'Someone',
    // The shape this page has open, and (step 8) the one it is actually holding. Empty means none.
    objectId: row.selected_object_id || '',
    activeObjectId: row.active_object_id || '',
    lastSeen: Date.parse(row.last_seen) || 0,
  }))
}

export function useBenchPresence() {
  const auth = useAuthStore()

  const rows = ref([]) // every presence row I can see, mine included
  const joined = ref(false)
  const errorMsg = ref('')
  const myPresenceId = ref('')

  let layoutId = ''
  let channel = null
  let beatTimer = null
  let selection = null // what this tab has open
  let holding = null // what this tab is holding (nothing sets it until step 8)

  const myUserId = computed(() => (auth.user ? auth.user.id : ''))

  // The freshest row on the bench stands in for "now" -- see decision 3 at the top.
  const reference = computed(() => rows.value.reduce((newest, row) => Math.max(newest, row.lastSeen), 0))

  const live = computed(() => rows.value.filter((row) => reference.value - row.lastSeen <= STALE_MS))

  // Everyone else, including my own other windows -- which are worth showing precisely because
  // they are the case that used to be invisible. They are labelled rather than hidden, so a
  // planner can tell "somebody else is here" from "I left myself open somewhere".
  const others = computed(() =>
    live.value
      .filter((row) => row.presenceId !== myPresenceId.value)
      .map((row) => {
        const mine = row.userId === myUserId.value
        return {
          presenceId: row.presenceId,
          userId: row.userId,
          name: row.name,
          label: mine ? row.name + ' (another window)' : row.name,
          mine,
          colour: plannerColour(row.userId),
          objectId: row.objectId,
          active: Boolean(row.activeObjectId),
        }
      })
      .sort((a, b) => a.label.localeCompare(b.label)),
  )

  // What to draw on the map: object id -> the planners who have it. An object can have more than
  // one, because selecting is not yet holding -- two planners may both be looking at the same
  // area, and only one of them will be able to move it.
  const byObject = computed(() => {
    const map = {}
    for (const who of others.value) {
      if (!who.objectId) continue
      if (!map[who.objectId]) map[who.objectId] = []
      map[who.objectId].push(who)
    }
    return map
  })

  function put(row) {
    const index = rows.value.findIndex((existing) => existing.presenceId === row.presenceId)
    if (index === -1) rows.value = rows.value.concat([row])
    else rows.value = rows.value.map((existing, i) => (i === index ? row : existing))
  }

  function drop(presenceId) {
    rows.value = rows.value.filter((row) => row.presenceId !== presenceId)
  }

  function applyPayload(payload) {
    if (payload.eventType === 'DELETE') drop(payload.old && payload.old.presence_id)
    // Unfiltered channel (see join): since 020 each event has its own bench, so only rows of THIS one.
    else if (payload.new && payload.new.layout_id === layoutId) readRows([payload.new]).forEach(put)
  }

  // Read the whole table. Run on joining and again whenever Realtime (re)connects, so nothing
  // that happened while this page was disconnected is missed -- the same pattern as
  // useLiveLocations, and the reason no replay of old events is needed.
  async function load() {
    if (!supabase || !layoutId) return
    const { data, error } = await supabase
      .from('layout_presence')
      .select('presence_id, user_id, display_name, selected_object_id, active_object_id, last_seen')
      .eq('layout_id', layoutId)

    if (error) {
      errorMsg.value = error.message
      return
    }
    errorMsg.value = ''
    rows.value = readRows(data)
  }

  // Say I am here, and what I have open. An upsert rather than an update, because the row can be
  // gone for two reasons: this is the first beat, or another planner swept it as a ghost while
  // this tab was asleep. Both are cured by the same statement.
  async function beat() {
    if (!supabase || !layoutId || !myPresenceId.value) return

    const { data, error } = await supabase
      .from('layout_presence')
      .upsert(
        {
          presence_id: myPresenceId.value,
          layout_id: layoutId,
          selected_object_id: selection,
          active_object_id: holding,
        },
        { onConflict: 'presence_id' },
      )
      .select('presence_id, user_id, display_name, selected_object_id, active_object_id, last_seen')

    if (error) {
      errorMsg.value = error.message
      return
    }

    // The row as the DATABASE sees it (name and timestamp filled in by the trigger), not as this
    // page asked for it -- and it keeps the "freshest row" reference moving even if Realtime is
    // down, so a planner with a broken socket still expires everybody else correctly.
    errorMsg.value = ''
    readRows(data).forEach(put)
  }

  function startBeating() {
    stopBeating()
    beatTimer = setInterval(() => {
      // A hidden tab is not on the bench: it stops beating and its row goes stale by itself,
      // which is the same rule useBenchLocks uses to let go of every lock when nobody is looking.
      if (document.visibilityState === 'visible') beat()
    }, BEAT_MS)
  }

  function stopBeating() {
    if (beatTimer) {
      clearInterval(beatTimer)
      beatTimer = null
    }
  }

  function onVisibilityChange() {
    if (document.visibilityState !== 'visible' || !joined.value) return
    // Back in view: say so at once rather than up to ten seconds later, and catch up on what
    // happened while away.
    beat()
    load()
  }

  // The page is closing: take my row away with a request the browser finishes after the page is gone, so
  // other planners do not see a ghost of me for 45 s.
  function onPageHide() {
    stopBeating()
    if (myPresenceId.value) {
      sendOnExit('layout_presence?presence_id=eq.' + myPresenceId.value, { method: 'DELETE' })
    }
  }

  // Back from the browser's page cache (Back button after leaving): announce myself again.
  function onPageShow(event) {
    if (event.persisted && joined.value) {
      beat()
      startBeating()
    }
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange)
    window.addEventListener('pagehide', onPageHide)
    window.addEventListener('pageshow', onPageShow)
  }

  // Join the bench. Called by the page once the bench has been opened and its id is known.
  function join(id) {
    if (!supabase || !id || joined.value) return
    layoutId = id
    myPresenceId.value = tabTag(myUserId.value)
    joined.value = true

    channel = supabase
      // Unique per mount: channels with the same name are shared, and a second one throws
      // (see useEventData.js).
      .channel('bench-presence-' + id + '-' + myPresenceId.value)
      // NOT filtered by layout_id, which is deliberate and looks like an oversight otherwise.
      // A DELETE carries only the primary key unless the table's replica identity is FULL, so a
      // filter on layout_id would silently drop every departure -- and "somebody left" is exactly
      // the event that has to arrive promptly. There is one bench, so the whole table is the
      // bench's presence anyway. The read below is filtered, because a SELECT has the columns.
      .on('postgres_changes', { event: '*', schema: 'public', table: 'layout_presence' }, applyPayload)
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') load()
      })

    beat()
    startBeating()
  }

  // Leave. Best effort: a killed tab cannot delete anything, which is what the sweep is for.
  async function leave() {
    stopBeating()
    joined.value = false
    const mine = myPresenceId.value
    myPresenceId.value = ''

    if (channel && supabase) {
      supabase.removeChannel(channel)
      channel = null
    }
    if (supabase && mine) await supabase.from('layout_presence').delete().eq('presence_id', mine)
    rows.value = []
  }

  // What this tab has open. Beaten straight away rather than waiting for the next heartbeat: this
  // is what puts a planner's name on somebody else's screen, so a ten second lag would be felt.
  function setSelection(objectId) {
    const next = objectId || null
    if (next === selection) return
    selection = next
    beat()
  }

  // Step 8 will call this; nothing does yet, and `active` in the entries above stays false.
  function setHolding(objectId) {
    const next = objectId || null
    if (next === holding) return
    holding = next
    beat()
  }

  onUnmounted(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange)
      window.removeEventListener('pagehide', onPageHide)
      window.removeEventListener('pageshow', onPageShow)
    }
    leave()
  })

  return {
    joined,
    myPresenceId,
    others,
    byObject,
    errorMsg,
    join,
    leave,
    setSelection,
    setHolding,
    reload: load,
  }
}
