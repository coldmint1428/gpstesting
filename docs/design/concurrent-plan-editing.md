# Concurrent editing on the plan board

**Status:** phases 1–5 built (081, 082, 083, the ownership UI, live drafts, per-cell undo, the structural doors).
**Branch:** `concurrent-plan-editing`.

Two or more planners may edit one plan at the same time. They must not move each other's badges by
accident, must not lose work to somebody else's save, and must not wait for a network round trip before
the badge follows the hand.

The shape of this is not new to the repository. The area bench already solved the same problem
(`supabase/migrations/016_object_locks.sql`, `src/composables/useBenchLocks.js`): the database owns the
exclusion, a lock is held by a *session* (one per page load), and nothing on the client is trusted. This
plan applies that doctrine to the plan board, where the unit of contention is smaller.

## The decisions

| # | Question | Decision |
|---|---|---|
| 1 | What is locked | One **cell** = `(frame_id, group_id)`. Two planners may edit different groups at the same frame. |
| 2 | Multi-frame gestures | All-or-nothing, one call. If one cell in the range is taken, nothing happens and the holder is named. |
| 3 | Frame time/note | A separate **frame** lock, disjoint from cell locks — a retime and a badge drag write different rows, so neither is refused because of the other. |
| 4 | Idle release | 5 s without pointer movement, **including mid-drag**. The next movement re-acquires silently. |
| 5 | Server timing | heartbeat 2 s, steal 7 s, expiry 12 s. |
| 6 | Two grabs at once | Optimistic: the badge moves at once; the server picks a winner; the loser snaps back. |
| 7 | Failures | Retry 3x over ~5 s, then roll back and say why. |
| 8 | Offline | Keep the local move, banner, flush on reconnect. |
| 9 | Incoming changes | Never applied to a cell I hold. |
| 10 | Undo | Pre-acquire its cells in one call; refused means nothing happens, the command stays, the holder is named. |
| 11 | Live drags | Streamed over a public broadcast channel, exactly as the bench's shapes are (see "Live drafts"). |
| 12 | Presence | A small stack of planners on the board; ring colour comes from it. |
| 13 | Phase 1 scope | Badge positions only; frame time and structural ops follow. |
| 14 | 25 m rule | Not enforced on a concurrent write; a violation is painted red by `plan_check`. |
| 15 | Publish | **Not blocked**; a warning names whoever is mid-edit. |
| 16 | Rollout | On by default; `?concurrent=0` turns off the ownership UI and the live stream. It **cannot** restore the old write path — 082 made the per-cell write the only one (see "The write path") |
| 17 | Capacitor | Later, same code path. |

## The model

| Resource | Key | Guards |
|---|---|---|
| Cell | `(frame_id, group_id)` | position, state, verify |
| Frame | `frame_id` | `t_s`, note |
| Plan | `plan_id` | not a lock: a read, used to warn on publish and refuse import/delete |

The database is the authority. The page is optimistic: a grab moves the badge immediately, a refusal
snaps it back to the last **committed** position and detaches that badge for the rest of the gesture.

## The server surface (081, built)

Two tables, `plan_cell_locks` (keyed `frame_id, group_id`) and `plan_frame_locks` (keyed `frame_id`), each
carrying `plan_id`, `user_id`, `session_id`, `last_seen` and `expires_at`. Both have RLS on with **no
policies**, every grant revoked, and a composite foreign key to `plan_frames (id, plan_id)` so a lock
cannot exist on a frame of another plan and dies with the frame it guards.

| Function | Does |
|---|---|
| `plan_lock_cells(plan, cells, session, take_over?)` | Takes a grab: one badge or forty, all or nothing. Raises `PT423` naming the holder. |
| `plan_lock_frame(plan, frame, session, take_over?)` | Takes a moment for a retime. Independent of the badges standing in it. |
| `plan_renew(plan, cells, frames, session)` | The heartbeat. Refreshes everything that session holds and says, per requested item, whether it is still `held`. |
| `plan_unlock_cells` / `plan_unlock_frame` / `plan_release_all` | Letting go, one thing at a time or the whole page at once. |
| `plan_lock_holders(plan)` | Who is editing, with display names and **never** a session id. Only live rows. |

`plan_cell_list` and `plan_require_editor` are internal and granted to nobody. A refusal is an **exception
with SQLSTATE `PT423`**, not a returned flag: the whole call rolls back (which is what all-or-nothing
means), and the message is the sentence the board shows. `PT409` stays what it always was — a stale write.

083 adds four more internal helpers, shared by the structural doors so that a refused delete, push and confirmation
are the same sentence read three ways: `plan_raise_hold` (the words), `plan_refuse_holds` (any live hold in these
frames, or in the whole plan), `plan_refuse_cells` (any live hold on these cells) and `plan_require_moment_hold` (the
positive check a retime makes).

The blocking rule is written once, in both the steal and the listing: a lock blocks while
`last_seen > now() - 7 s AND expires_at > now()`.

## The write path (082, built)

`frame_save` used to replace a frame's whole position map and bump one `rev` for the row. That is incompatible
with per-cell holds: two planners holding different cells still collided, and a stale payload deleted the
colleague's badge. 082 splits it:

- **`frame_place(plan, frame, group, session, lat, lng, state?, verify?)`** writes exactly one cell, checked
  against a live hold on it, and touches `plans.updated_at` once per call (never `plan_frames.rev`).
- **`frame_place_many(plan, cells, session)`** writes one gesture's cells in one statement, all or none. The cell
  list is the grab's own shape — `{frame, group, lat, lng, state?, verify?}`.
- **`frame_unplace` / `frame_unplace_many`** are the only way a position disappears. A payload never deletes.
- **`frame_save` writes `positions` only when it *inserts* the frame**, and refuses them on a frame that already
  stands. A moment that did not exist a statement ago cannot have somebody else's badge on it, so the map has
  nothing to lose there — and this is what keeps `plan_import` (one `frame_save` per sheet frame, after deleting
  every frame) and undo's restore (041) working untouched.
- **`frame_save` takes an optional session**; given one, and on a frame that exists, the moment hold must be the
  caller's. Without one the rev check is the only guard — the same guard every caller had before, which is all
  `plan_import` has to offer.
- **A cell write does not bump `plan_frames.rev`.** `rev` is the metadata version (time and note) now. Bumping it
  on every badge move would hand the next planner a stale-rev refusal for an unrelated note edit, which is the
  exact message this feature exists to remove.

`frame_hold` (045/067), `frames_fill` (042) and `frame_set_verify` (047) used to write positions inside their own
bodies, without a hold. 083 gives them, and the rest of the structural writes, the same rule — see "The rest of the
board (phase 5)" below.

A phase-2 page took the hold immediately before a write and put it down after it (`usePlanLocks`). That was enough
for exclusion. Phase 3 keeps the hold for the length of the gesture; the rules are in "The ownership UI" below.

## The ownership UI (phase 3, built)

**A hold lasts as long as the hand does.** It is taken on `dragstart` — for every badge the drag will carry, all or
none — and released on `dragend`, so a badge is locked to other planners for the whole gesture rather than for the
instant of the write. Between the two, `plan_renew` says "still here" every 2 s: the server's blocking rule is "quiet
for 7 s", so a page that renews cannot be mistaken for one that has walked away. The same call reports, per row,
whether the hold is still mine; a row that is not is dropped from the page's list at once and the gesture finishes as
a refusal instead of a write.

**5 s of stillness lets go.** Decision 4: a badge nobody has moved for five seconds is released even though the
finger is still down, so a planner who walks away — or a phone that locked — does not keep a colleague out. The next
pointer movement takes it back silently; if somebody else took it in the gap, the write is refused and the badge goes
back with the sentence. That snap-back is the price of the rule, and the silent re-acquire is the mitigation rather
than a change of rule.

**Every exit is a release.** Pointer up, the idle timer, a hidden tab (`visibilitychange`), a page unload
(`pagehide`), a plan switch and a teardown all give up what the page holds (`plan_release_all` for the unload paths).
The database also expires a hold on its own after 12 s, which is what makes all of it best effort.

**One strip, and it is the only place a refusal is said.** A refusal arrives while the hand is still down, so a toast
would be about a moment that has passed; the board's strip (`data-testid="plan-refusal"`) holds the server's sentence
until dismissed or eight seconds pass, and carries the one action a refusal can have — "Edit it here anyway", offered
only when the sentence is "another of your windows" (081's `p_take_over` reaches nothing else). A move that failed for
any other reason reads "Error updating location: …" and the badge goes back where the plan has it. The four write
sites and undo route a lock refusal here; everything else keeps its toast.

**Rings and a stack, drawn from one read.** `plan_lock_holders` every 2.5 s: a badge somebody else is holding gets a
slate ring and a tooltip that names them, a badge of my own account gets a green one, and the stack in the corner of
the map (`data-testid="plan-presence"`) names everyone else and how many badges they are on. None of it decides
anything — a ring is a courtesy, and the refusal is the fact.

**`?concurrent=0`** turns off the rings, the stack and the gesture hold. It cannot turn off the rule: a write still
goes through the per-cell doors and is still refused by the database.

## Live drafts (phase 4, built)

**A drag is published as a draft, not as a write.** `usePlanStream` joins the public broadcast channel
`plan-cells-<planId>` and publishes `{ from, cell, seq, patch }` for every badge a gesture is moving: `cell` is
`frame|group`, `patch` is `{ lat, lng }` and nothing else, `seq` is the sender's own number, and `from` is this page's
tag — never the lock session (`pageSession.js`), which no message may carry.

**The badge on your screen does not move until they let go.** It is drawn from the plan, and the plan has not changed,
so their drag is drawn as a hollow ghost on a layer of its own, beside the ring that already says the badge is theirs.
That pair is the honest picture: *that* is where the plan has the badge, and *this* is where somebody is taking it.

**Nothing a draft says is written, and that is what makes an untrusted channel safe to draw on.** Every commit needs a
hold the database checks, so a forged draft is a lie about a preview, not about the plan: the worst it can do is draw a
ghost. `utils/planDraft.js` is the allow-list — two finite numbers inside `point_in_sg()`'s box, which now lives once in
`utils/geo.js` — and it filters what is sent as well as what is drawn, so the two sides cannot drift apart. The name
beside a ghost comes from `plan_lock_holders`, never from the message: a name in a broadcast is a name anybody can type.

**Three bounds keep a cosmetic stream from costing anything.** One draft per badge per 50 ms, with the last place always
sent (a trailing timer, so letting go publishes the place the hand let go at); a per-sender sequence number, so a
message that arrived late is dropped rather than drawn; and a 2.5 s TTL, after which a ghost goes — that is the crashed
tab, the closed lid, the socket that died mid-drag. The end of a gesture also publishes `patch: null`, so the ghost goes
at once instead of waiting the TTL out. A broadcast that cannot be pushed is dropped rather than retried: at twenty a
second the silent REST fallback would be a request storm, for a hint that is worth nothing once it is late.

Known and accepted: the channel is public. Any authenticated user who knows a plan id can watch drafts and publish fake
ones. This is the bench's existing posture for its shapes (`useBenchFrames`) and it is recorded here rather than
discovered later.

## Undo, under one hold (phase 4, built)

Decision 10, literally. A command remembers a whole position map; a write is per cell (082). So `usePlan.rewriteCells`
works out the difference against the **live** frame — the cells that moved or appeared are placed, the ones that were
taken away are unplaced — and `usePlanLocks.rewrite` asks for every one of those cells in ONE `plan_lock_cells` call
before anything is written, writes both directions under that one hold, and lets go.

A refusal therefore happens before the first row: nothing moves, the command **stays on the stack** (so the same key
works once the badge is free), and the strip says `Undo did not happen: Priya is editing Gate Crew at +1:00`. Before
this it was `placeCells` and then `unplaceCells` — two calls with a hold each, where a refusal could arrive between
them, which is an undo that half happened.

The comparison is against the live frame, not against the command's other map, because a command remembers where the
frame was and not what somebody else has done to it since: a badge taken away in the meantime comes back, which is what
the planner asked for.

## The rest of the board (phase 5, built)

**The rule, in one sentence:** a door that would take away or overwrite something a live hold is guarding refuses and
names the holder; a door that only adds something that was not there may go ahead. 083 applies it to the eight writes
that were still unguarded.

**Two checks, because there are two kinds of write.** A retime (`frame_move`) is a gesture, and a gesture can be
claimed: it **takes** the moment lock for the length of the write, exactly as a note edit does, so a colleague
retiming the same moment is refused by name. Everything else — a push, a fill, a hold, a confirmation, a frame
delete, a plan delete, an import — is one action across many rows rather than a hand on one, so it takes no hold and
asks the **negative** question instead: is anybody else's hand on anything this would write? Taking forty holds to
write forty flags would lock a colleague out of the board for a click.

| Door | Refused by |
|---|---|
| `frame_move` (retime) | the caller must hold the moment |
| `frame_delete` | **any** live hold in the frame — a badge being dragged in it, its own clock being retimed |
| `frame_shift` (push), `frames_fill` | a moment hold in the stretch (both bump those frames' revisions) |
| `frame_hold` | a badge hold on a cell it writes, a moment hold on the frame it bumps |
| `frame_set_verify` | a badge hold on a row it would change, a moment hold on a frame it touches |
| `plan_delete`, `plan_import` | any live hold anywhere in the plan |

**Deleting a moment is refused while a badge in it is held.** A badge only exists inside a frame, and 081's composite
foreign key cascades the lock away with it, so doing nothing was an option — and the wrong one. The colleague's hand
is on a badge that is about to cease to exist: their drag ends on a refusal about a badge that is gone, and the
moment they were drawing is gone with it, so there is nothing to redo. Refusing costs the deleter the twelve seconds
a hold can live at most, and it is the same rule the two bigger destructive acts already had. The sentence says who
and where: *"Priya is editing Gate Crew at +1:00, so this moment cannot be deleted yet."*

**A lapsed hold is not a hold**, so there is no "delete it anyway": 083 shares 081's blocking rule (quiet for 7 s,
expired at 12 s), which means the delete works a few seconds after the holder has walked away. `p_take_over` stays
what it was — a way past my **own** other window, on the two doors that are a gesture, and never a way to take a
colleague's badge out from under them. A hold of my own account in another tab is named as exactly that, not as a
stranger.

**What is still allowed, deliberately.** A retime does not wait for the badges standing in the moment (081's
decision, and the deadlock that made it), and a push or a fill is never refused by a badge hold: neither changes a
position, and both would otherwise be blocked by the very drags they are not touching.

**Publishing warns, and does not wait** (decision 15). After the publish question, `plan_lock_holders` is read fresh —
not the 2.5 s presence read — and if anybody is mid-edit a second question names them and their cells and says what
the version being written will not contain: it is a snapshot, so their change lands afterwards and needs another
publish to reach anyone. Cancelling it publishes nothing. With `?concurrent=0` the warning goes with the rest of the
ownership picture; the publish itself is never blocked either way.

## Client

| Module | Owns |
|---|---|
| `usePlanLocks` | ownership: hold, the 2 s heartbeat, release, release-all, loss detection (`onLost`), take-over, `holders(cell)`, and `rewrite` (both directions under one hold). Built |
| `usePlanStream` | where a badge somebody else is dragging is going: the public broadcast, its per-badge throttle, its sequence numbers and its TTL. Built |
| `usePlanDraft` | **not built, and not needed for drafts**: a draft is drawn on an overlay and never merged into `frames`, so a peer's drag cannot become a position on this page before the database says it is one |
| `usePlanQueue` | **not built**: per-cell serialised writes, coalescing, retries, rollback — decision 7's "retry 3× over ~5 s" is the outstanding half of that decision |

`loadFrames` still assigns rather than merges, and a peer event still reloads the board: with drafts on an overlay there
is no local picture to protect, and a reload after somebody else's write is the truth arriving rather than a clobber. A
merge becomes necessary when the write queue lands — a queued write's own picture is what a background read would take
away. (Phase 2 added `placeCells` / `unplaceCells` and the moment hold in `saveFrame`; phase 4 added `rewriteCells` and
the five draft calls — `startDrafts`, `stopDrafts`, `planDraft`, `clearDrafts`, `onDraft`.)

## Refusals and errors

| Situation | What the planner sees |
|---|---|
| Grabbed a cell someone else holds | badge does not move; strip: "Priya is editing Gate Crew at +1:00" |
| Lost the lock mid-drag | snap back to committed; "Error updating location: Priya has this badge" |
| Save failed | snap back + the same message with the reason (retries are the write queue, not built) |
| Undo refused | nothing moves (one hold covers both directions, so nothing is written at all); "Undo did not happen: Priya is editing Gate Crew at +1:00"; the command stays on the stack |
| Publish with someone mid-edit | two-step confirm naming them and their cells; not blocked |
| Delete a moment with a badge held in it | nothing is deleted; strip: "Priya is editing Gate Crew at +1:00, so this moment cannot be deleted yet" |
| Delete a moment while it is being retimed | the same, naming the moment |
| Retime a moment somebody else is retiming | the field goes back; strip: "Daniel Planner is editing the moment at +2:00, so this moment cannot be moved yet" |
| Push, fill, hold or confirm over a held badge | nothing is written; the strip names the holder and says what did not happen |
| Delete the plan, or import a sheet, while anybody is in it | refused; strip: "…so this plan cannot be deleted yet" / "…so the plan cannot be replaced yet" |
| Any of the above after the holder has gone | works once the hold lapses (12 s at most) — there is no override |

Refusals use a board-level strip (`data-testid="plan-refusal"`, built in phase 3 rather than the confirm toast, which
is already used for successful moves and would collide). An undo refusal goes through the same strip.

## Failure matrix

| Case | Behaviour |
|---|---|
| Frame deleted under a drag | `frame_place` refuses unknown frames, and 083 refuses the delete while the drag's hold is live, so the only window is the one between a lapsed hold and its next heartbeat. (`frame_save` still re-inserts a frame whose id it is handed — that is 041's restore — so the badge door is the one that refuses, and it is the one a drag uses.) |
| Reload with locks held | release is best effort; a reclaimed grab may return `mine_elsewhere`; the reloaded page takes it back at once |
| Crashed tab | steal after 7 s, expiry 12 s |
| Crashed tab mid-drag | its ghost expires 2.5 s after its last draft; nothing else was ever written |
| Peer edits another group | merged on apply; my cell untouched |
| Peer drags a badge I am looking at | a ghost on the overlay; the badge stays where the plan has it until their write lands |
| Import / delete plan while anyone holds | refused, holders named (083) |
| Clock skew | never decide "held" from a local timestamp; the server's `expires_at` decides |

## Phases

1. **Locks, server only** — *done (081)*. `081_plan_locks.sql`, the seven doors, and a `plan-locks` pgtest
   phase that proves grab / refuse / steal / expire / all-or-nothing / holders / take-over / cascade and the
   real-role grants. Nothing user-visible.
2. **Per-cell writes** — *done (082)*. `082_frame_place.sql`, the four doors, `frame_save` reduced to the moment
   and to a new frame's first cells, and the board writing through `placeCells` / `unplaceCells` (a drag, a
   placement, an off-site toggle, a bulk state change, and undo's inverse). Still single-user, all suites green.
3. **Ownership UI** — *done*. The hold taken on dragstart and kept across the gesture (2 s `plan_renew`), the 5 s
   idle release with a silent re-acquire, release on up / idle / hidden / unload / plan switch, the refusal strip
   (`plan-refusal`) with snap-back and "Error updating location: …", the ghost ring and the presence stack from
   `plan_lock_holders`, the take-over action for my own other window, badge test ids, and `?concurrent=0`.
4. **Live drafts and undo** — *done*. `usePlanStream` on `plan-cells-<planId>` (payload, 50 ms per-badge throttle,
   per-sender sequence numbers, 2.5 s TTL, a let-go message), the ghost overlay drawn from it, `?concurrent=0` turning
   it off, and per-cell undo with pre-acquire: one `plan_lock_cells` for every cell of both directions, then the two
   writes, so a refusal writes nothing and the command stays.
5. **Structural ops** — *done*. `083_frame_ops_locks.sql`: every remaining write on the board is checked against the
   holds it could destroy, a moment delete is refused while a badge in it is held, `frame_move` takes the moment lock,
   the session travels with all eight doors, and publishing asks a second question that names whoever is mid-edit.

## Verification

| Layer | Command | Proves |
|---|---|---|
| SQL rules, ownership | `node tools/pgtest.mjs plan-locks` | grab/refuse/steal/expire, all-or-nothing, holders, take-over, cascade, and that `authenticated` can reach the doors but not the tables (116 assertions) |
| SQL rules, writes | `node tools/pgtest.mjs plan-place` | a write needs a hold; one cell is the only row written and the revision is untouched; a gesture is all or nothing; a new frame still takes its first cells; a stale rev is still PT409 (116 assertions) |
| SQL rules, structural ops | `node tools/pgtest.mjs plan-ops` | a retime needs the moment; a moment delete waits for a badge in it, for its own clock, and for my own other window, and goes once the hold lapses; a push and a fill wait for a moment and not for a badge; a hold and a confirmation refuse over a badge in somebody's hand and over a retimed moment, and a flag already at the value asked for is not in anybody's way; a plan delete and an import wait for anybody; the old arities are gone and only `authenticated` can reach the doors (108 assertions) |
| Full schema | `npm run test:db` | nothing else regressed (932 assertions) |
| Unit | `npm run test:unit` | the hold-write-release order, a refusal writing nothing, one release for overlapping writes, the 2 s heartbeat and its stop, a hold the heartbeat says is gone, release-all, presence, take-over, one grab for a write inside a gesture, an undo asking for both directions in ONE hold and writing nothing when that hold is refused; the draft channel's join, its push gate, its per-badge throttle with the last place sent, an overtaken draft dropped, a draft from this page dropped, a draft outside the box dropped, a let-go, the TTL, and `stop()`; the allow-list on its own; and every structural door carrying the session, with the retime wrapped in one moment hold (99 assertions, 20 + 10 + 6 + 5 in those files) |
| Browser smoke | `npm run check:board` | the board works without logging in; a dragged badge stays where it was put and is let go; a badge a colleague holds is ringed, named, refused and snapped back; 5 s of stillness releases it and the next movement takes it back; a colleague's drag is a ghost drawn where it said, named from the holders read, with the badge itself unmoved, and the ghost goes when they let go; an undo refused by a held badge writes nothing and the same key works once the badge is free; a moment with a badge in it is not deleted, and the same two clicks delete it once the badge is free; publishing while somebody is mid-edit asks twice, names them, publishes nothing on Cancel and publishes on the second yes; `?concurrent=0` hides the picture (and the stream) and not the rule (73 assertions, 6 tabs) |
| Two tabs | manual, one identity | streaming and release |
| e2e | blocked: `.tmp/qa-accounts.json` and seven accounts | two real identities |

PGlite is one connection, so it proves the **rules**, never the **race**. The race — two grabs in the same
millisecond — is covered by the manual two-profile pass, and by nothing automated. That is stated rather
than papered over: a script that "proves" arbitration on one connection would be proving a sequence.

The same is true of the draft channel in a different way: the browser harness has no socket, so
`check:board` drives the fixture's seam (the same rows, through the same renderer) and the unit suite drives
`usePlanStream` against a fake client. What neither can show is two real browsers on one Realtime channel —
the manual two-profile pass is the only thing that does, and it is the one piece of phase 4 still owed.

**The one place 083 is thinner than a hold, and it is on purpose.** A bulk door (a push, a fill, a hold, a
confirmation, both plan-level deletes) checks for other people's holds in the same transaction as the write but takes
no row of its own, so two bulk writes can still interleave. The cost of that is bounded and small — a flag written
twice, a position stated twice — and the alternative was forty lock rows for one click. The doors that are a gesture
(one badge, one moment) are the ones that take a hold, and they are the ones where losing a race would lose work.

## Risks

- `frame_save` losing `positions` touches paste, import, undo and the sheet path — and it did: the answer was to
  keep the wholesale map for a frame the call *creates*, which is why 059 (import) and 041 (restore) needed no
  change at all. It only looks like a loophole until you ask who could be holding a badge on a frame that did not
  exist a statement ago.
- **There is no going back to the old write path.** 082 refuses a badge map on a frame that exists, so
  `?concurrent=0` can turn the UI off but not the per-cell write. That is deliberate: the old path is the
  data-loss bug, and a flag that could re-enable it would keep the bug reachable from a URL. A rollback here is a
  migration, and it should read like one.
- `frame_hold` must be copied from its **live** body (067), not 046, or QA-07 silently reverts. 083 is the second
  copy of it and carries 067's condition; a third copy would need the same care.
- **A multi-frame undo is a loop of single doors.** Undoing a paste or a fill deletes its frames one `frame_delete` at
  a time (and a delete is now refusable per frame), so a refusal part-way through leaves the stretch half undone. The
  command stays on the stack, so the same key resumes, and the strip says who is in the way — but the stack's promise
  ("either it happened or it did not") is only true for the per-cell commands, which are one hold and one call.
  Making it true here means a `frame_delete_many`, which nobody has asked for yet.
- The 5 s mid-drag release is the product owner's decision and the main source of snap-backs; the
  mitigation is the silent re-acquire, not a change of rule. It is built, and the browser check holds a badge still
  for five seconds to prove it is released and taken back.
- The broadcast channel is public (section "Live drafts"). A forged draft draws a ghost and nothing else: it cannot
  become a position, because every commit needs a hold the database checks.
- Retries are not built. Decision 7 said "retry 3× over ~5 s, then roll back"; today a failed write rolls back at
  once with the reason in the strip. The rollback half is what the product asked for explicitly, and it is the half
  that is there; the retry half is `usePlanQueue`, unbuilt, and belongs with decision 8's offline flush.
- **A retime and a badge drag are independent, on purpose.** The first draft of 081 refused a retime while
  another session held a badge in that moment, on the theory that the badge would slide out from under the
  hand. It does not: a badge is a lat/lng, and a clock does not move one. What slides is the frame's tick
  in the strip and the walk lines and 25 m flags measured between moments — pictures reflowing, not an edit
  lost. The rule deadlocked two planners dragging different badges at one moment, so it was dropped. Do not
  add it back for a reason about the picture moving; only for one about data.
- The word "lock" already means the local drag guard (`moveLock`). The server concept is called **editing** / **in
  use**; the guard's test id is `plan-drag-guard`, and `plan-lock` is gone from the board (the bench's
  `plan-lock-<n>` ids are a different page and a different thing).
