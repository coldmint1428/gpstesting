# Concurrent editing on the plan board

**Status:** phases 1–2 built (081, 082). **Branch:** `concurrent-plan-editing`.

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
| 11 | Live drags | Streamed over a public broadcast channel, exactly as the bench's shapes are (see section 6). |
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

`frame_hold` (045/067), `frames_fill` (042) and `frame_set_verify` (047) still write positions inside their own
bodies, without a hold. They are whole-stretch and whole-grid operations rather than per-badge ones, and 083 is
where they meet the rule.

What a phase-2 page does, then, is take the hold immediately before a write and put it down after it (`usePlanLocks`).
That is enough for exclusion; holding one for the length of a gesture — pointer down to pointer up, the heartbeat,
the 5 s idle release — is phase 3.

## Client

| Module | Owns |
|---|---|
| `usePlanLocks` | ownership: grab, heartbeat, 5 s idle release, release-all, take-over, `holderOf(cell)`. Phase 2 has the first three of those calls in their narrow form — hold, write, let go — and the rest arrives with the UI |
| `usePlanDraft` | the optimistic frame store: merge rows, never overwrite a cell I own |
| `usePlanStream` | draft drags and lock hints on one broadcast channel; drafts render on an overlay |
| `usePlanQueue` | per-cell serialised writes, coalesce, retries, rollback |

`usePlan.js` changes in two places only: `loadFrames` merges instead of assigning, and a peer event no
longer triggers a full-board reload. (Phase 2 already added `placeCells` / `unplaceCells` and the moment hold
in `saveFrame`; the board's own calls at those five sites are the whole of its edit.)

## Live stream

Public broadcast channel `plan-cells-<planId>`, event `draft`, payload
`{ from, cell, seq, patch }`, where `from` is the **presence tag**, never the session secret. Copied
from the bench: `self: false`, a 50 ms trailing throttle per cell, per-sender sequence numbers, a
`canPush()` gate (a broadcast that cannot push silently falls back to REST), and an allow-list patch
filter.

A received draft is **drawn, never written**. It cannot become a position, because every commit needs a
lock the database checks. A forged draft is therefore a lie about a preview, not about the plan.

Known and accepted: the channel is not private, so any authenticated user who knows the plan id can
watch planned positions and send fake drafts. This is the bench's existing posture. It is recorded here
deliberately rather than discovered later.

## Refusals and errors

| Situation | What the planner sees |
|---|---|
| Grabbed a cell someone else holds | badge does not move; strip: "Priya is editing Gate Crew at +1:00" |
| Lost the lock mid-drag | snap back to committed; "Error updating location: Priya has this badge" |
| Save failed after retries | snap back + the same message with the reason |
| Undo refused | nothing moves; "Undo did not happen: Priya is editing Gate Crew at +1:00" |
| Publish with someone mid-edit | two-step confirm naming them and their cells |

Refusals use a board-level strip (the bench's pattern), because the confirm toast is already used for
successful moves and would collide.

## Failure matrix

| Case | Behaviour |
|---|---|
| Frame deleted under a drag | `frame_place` refuses unknown frames. (`frame_save` still re-inserts a frame whose id it is handed — that is 041's restore — so the badge door is the one that refuses, and it is the one a drag uses.) |
| Reload with locks held | release is best effort; a reclaimed grab may return `mine_elsewhere`; the reloaded page takes it back at once |
| Crashed tab | steal after 7 s, expiry 12 s |
| Peer edits another group | merged on apply; my cell untouched |
| Import / delete plan while anyone holds | refused, holders named |
| Clock skew | never decide "held" from a local timestamp; the server's `expires_at` decides |

## Phases

1. **Locks, server only** — *done (081)*. `081_plan_locks.sql`, the seven doors, and a `plan-locks` pgtest
   phase that proves grab / refuse / steal / expire / all-or-nothing / holders / take-over / cascade and the
   real-role grants. Nothing user-visible.
2. **Per-cell writes** — *done (082)*. `082_frame_place.sql`, the four doors, `frame_save` reduced to the moment
   and to a new frame's first cells, and the board writing through `placeCells` / `unplaceCells` (a drag, a
   placement, an off-site toggle, a bulk state change, and undo's inverse). Still single-user, all suites green.
3. **Ownership UI** - release, refusal strip, snap-back, ghost ring, presence stack, badge test ids.
4. **Live drafts and undo** - `usePlanStream`, overlay rendering, per-cell undo with pre-acquire.
5. **Structural ops** - `083_frame_ops_locks.sql`, publish warning.

## Verification

| Layer | Command | Proves |
|---|---|---|
| SQL rules, ownership | `node tools/pgtest.mjs plan-locks` | grab/refuse/steal/expire, all-or-nothing, holders, take-over, cascade, and that `authenticated` can reach the doors but not the tables (116 assertions) |
| SQL rules, writes | `node tools/pgtest.mjs plan-place` | a write needs a hold; one cell is the only row written and the revision is untouched; a gesture is all or nothing; a new frame still takes its first cells; a stale rev is still PT409 (116 assertions) |
| Full schema | `npm run test:db` | nothing else regressed (824 assertions) |
| Unit | `npm run test:unit` | the take-write-release order, a refusal writing nothing, one release for overlapping writes, a failed release not being an error (68 assertions) |
| Browser smoke | `npm run check:board` | the board works without logging in, and a dragged badge stays where it was put across a frame switch (29 assertions) |
| Two tabs | manual, one identity | streaming and release |
| e2e | blocked: `.tmp/qa-accounts.json` and seven accounts | two real identities |

PGlite is one connection, so it proves the **rules**, never the **race**. The race — two grabs in the same
millisecond — is covered by the manual two-profile pass, and by nothing automated. That is stated rather
than papered over: a script that "proves" arbitration on one connection would be proving a sequence.

## Risks

- `frame_save` losing `positions` touches paste, import, undo and the sheet path — and it did: the answer was to
  keep the wholesale map for a frame the call *creates*, which is why 059 (import) and 041 (restore) needed no
  change at all. It only looks like a loophole until you ask who could be holding a badge on a frame that did not
  exist a statement ago.
- **There is no going back to the old write path.** 082 refuses a badge map on a frame that exists, so
  `?concurrent=0` can turn the UI off but not the per-cell write. That is deliberate: the old path is the
  data-loss bug, and a flag that could re-enable it would keep the bug reachable from a URL. A rollback here is a
  migration, and it should read like one.
- `frame_hold` must be copied from its **live** body (067), not 046, or QA-07 silently reverts.
- The 5 s mid-drag release is the product owner's decision and the main source of snap-backs; the
  mitigation is the silent re-acquire, not a change of rule.
- The broadcast channel is public (section "Live stream").
- **A retime and a badge drag are independent, on purpose.** The first draft of 081 refused a retime while
  another session held a badge in that moment, on the theory that the badge would slide out from under the
  hand. It does not: a badge is a lat/lng, and a clock does not move one. What slides is the frame's tick
  in the strip and the walk lines and 25 m flags measured between moments — pictures reflowing, not an edit
  lost. The rule deadlocked two planners dragging different badges at one moment, so it was dropped. Do not
  add it back for a reason about the picture moving; only for one about data.
- The word "lock" already means the local drag guard (`moveLock`, `data-testid="plan-lock"`). The server
  concept is called **editing** / **in use**; the old test id becomes `plan-drag-guard`.
