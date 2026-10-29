# Planning stage — implementation plan (v27)

Twenty-eight steps. v6's decisions stand; v7 is the result of a third audit round that asked a different question:
not *is the design right* but *will each step actually execute*. Nine findings, two blockers, all folded in below.
v8–v27 are the same plan with the finished steps' **Done** blocks written: what now exists, the command that
proves it, what the step found, and what it left owing. Steps 26, 27 and 28 are the ones added after the
twenty-five were closed: they come from using the thing, not from the plan, and the last one is the first about the
person pressing rather than the phone deciding.

**Your decisions, unchanged:** impossibility is cumulative (25 m per frame step, so 3 frames = 75 m); verification
is per group per frame with bulk toggles; no deadlines — a key time is a frame; multi-select drag, weighted
midpoint, hand-back log and CSV are in; **undo and redo are both in** (Ctrl+Z, Ctrl+Y / Ctrl+Shift+Z); named
states and undo-across-publish are out.

---

## Where this is

**All twenty-eight steps are done.** Step 25 deleted the run-sheet stack, so the plan is the only engine left in the
product; step 26 made a timetable row say *where* the moment is; step 27 made a moment close itself when the IC's
phone is close enough, with a radius that is the IC's own; step 28 gave the group's IC a press of their own ("we're
here") and made a mark belong to the person who made it. The work was done one step at a time and stopped for
review after each.

| | |
|---|---|
| ✅ done | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 |
| ▶ next | nothing in this plan — the debts below are the next list |

When a step finishes, its block below gains a **Done** line saying what now exists and the command that proves it.

---

## What the execution audit changed

| | Finding | Where it lands |
|---|---|---|
| 1 | **New tables would be world-readable.** `pg_default_acl` grants `arwdDxtm` on public tables to `anon` and `authenticated`; `plan_progress`, `plan_versions`, `handover_log` were described with no RLS | standing rule R3; steps 14, 18, 21 |
| 2 | **PostGIS would not resolve.** `plan_check` runs with `search_path=public`; PostGIS is in `extensions`, so unqualified `st_intersects` raises 42883. Its return type is fixed, so a new `zone_name` column cannot `create or replace` | step 11 |
| 3 | **The deletion inventory is partly fictional.** `session_run_sheets` is a function, not a table; `ic_moves` and `delays` do not exist | step 25 (done — and the catalogue's list was bigger than this one: `show_cues`, `group_messages` and `sim_groups.movement_id` too) |
| 4 | **Dropping `start_event` loses its grants** (`authenticated=X, service_role=X`) and leaves an ambiguous overload if recreated without dropping | step 2 |
| 5 | **"Exactly one" is wrong** — sessions may have neither a plan nor a run sheet. The check must be "not both" | step 2 |
| 6 | **`show_log.kind` is a CHECK over twenty values**; new kinds need drop/re-add, and removing `broadcast` breaks existing rows | step 22 |
| 7 | **The cron set is larger than assumed** — ten jobs, including an unexplained `zz-walk`; "all jobs succeeded recently" fails on the hourly ones, and three tick jobs error every 2 s if their functions are dropped first | steps 21, 24 |
| 8 | **`origin_frame_id` cannot be set inside `plan_fork`'s INSERT** (the new ids do not exist yet) | step 17 (done) |
| 9 | **A plan session cannot be started from the app at all** — the only caller passes a run sheet and the Start dialog offers a run-sheet picker | step 2 |
| 10 | **Renaming a plan silently unpublishes it** — `plan_save` defaults status to `draft` | step 2 |
| 11 | **Members can already read every group's positions** — the board renders for them and the policy is `is_event_member` | step 3 |
| 12 | **Six checks could not be run** — `shot.mjs` clicks one selector and cannot reload, type or drag, so those steps would have been "verified" by RPC calls that pass exactly when the interaction is broken | step 1 |
| 13 | **Bulk work cannot be a loop** — each `saveFrame` reloads every frame and needs a live `rev`; a 12-frame fill is 24 round trips | steps 5, 10 |
| 14 | **A multi-drag would fire one write per marker** against one revision, so all but the first get PT409 | step 8 |
| 15 | **Undo of a delete cannot restore the id**, because `frame_save` always lets Postgres mint it | step 4, 13 |

### Found while doing step 1

| | Finding | Where it lands |
|---|---|---|
| 16 | **A person is in one group per event** — `group_members` is unique on `(event_id, user_id)`, so "two members of two groups" is two people, and a second row for the same person is a 23505 | fixture; step 3 |
| 17 | **`event_sessions.end_reason` is a CHECK over `ended`, `auto`, `scheduled`** — a fixture inventing `'fixture'` is refused, which is the same class of trap as 6 | fixture; step 2 |
| 18 | **A page with no `<link rel="icon">` makes the browser request `/favicon.ico` and 404** — a check that treats any failed request as a failure (it should) then fails on the fixture page, not on the product | `dev/preview.html` |
| 19 | **A list that loads after the button is pressable is a silent default** — the Start dialog opened with no plan in it while `plan_list` was still in flight, so pressing Start meant "tracking only". Start is now disabled until the list has arrived | `EventView`, `EventStatus` |
| 20 | **Every 037/038 plan function carries a PUBLIC execute grant** (`=X/postgres`), against R4. Not a leak — each one checks the caller's role — but it is not what the rule says, and 039's own functions are revoked properly | debt, step 3 |
| 21 | **The 25 m limit is exact**: a step computed as 25.0006 m is an error, not a rounding difference. The fixture's first 25 m steps failed the gate for that reason, and a "fill the gap" in step 5 has to land at or under the limit, not near it | fixture; step 5 |
| 22 | **The board fitted the map to the polygons only**, so a plan whose groups stood outside the drawn areas opened with no marker in view — the planner's screenshot was a map of empty shops | step 3 (fixed) |
| 23 | **A member can still read an unpublished plan's frames and notes** at the database: `plans_read` and `plan_frames_read` are `is_event_member`. The board no longer shows a draft (step 3 opens the live plan only), but the read path is replaced in step 16 | debt; step 16 |
| 24 | **The board and `plan_check` name different frames for the same jump.** The board walks resolved tracks, where every frame carries a point for every group, so Sound's 200 m is reported from +2:00 (the last moment it was still standing there); `plan_check` compares stated positions and says +1:00 to +3:00. Same distance, either pair fixes it — but a check that assumed the two agree failed, and step 12 has to choose which one its cumulative highlight follows | step 5 (done); step 12 |
| 25 | **Two dots 13 s apart overlap at the default zoom.** The dot is 22 px wide and 1.1 px/s makes 13 s 14 px, so the later dot wins the hit test: clicking the middle of the earlier one opens the later one. Nothing is wrong with the data; the −/+ zoom separates them. Anything that clicks a frame has to zoom first, and a planner needs a keyboard way to step between close frames | step 6 (arrow keys) |
| 26 | **The browser runner took a string as a true condition.** `assertThat(name, expr)` did `!!condition` on the expression source, so nineteen assertions across steps 1–5 could not fail — including three bugs they were supposed to catch. It now evaluates the expression in the page and requires exactly `true` | step 6 (fixed) |
| 27 | **`change` does not fire for a value the browser does not consider user-edited**, so the note field never wrote: the note stayed on screen and never reached the plan. The field commits on blur now, guarded so an unchanged field writes nothing | step 6 (fixed) |
| 28 | **A field being edited commits on blur, and the blur used to happen after the selection moved**, so a note typed against one frame was saved onto the frame that was clicked. Blur now runs before the selection changes | step 6 (fixed) |
| 29 | **The map never re-fitted when the plan changed** (only on the first load), so a plan drawn in another corner opened showing the previous plan's corner with no markers in it — finding 22's other half | step 6 (fixed) |
| 30 | **A function body copied from the migration that introduced it reverts every later rewrite.** 044 re-created `frame_save` from 038 and undid 041's client-supplied ids; `step4-frame-id.sql` caught it. Copy from the latest definition (R8) | step 6 (fixed) |
| 31 | **A save could nudge the map by seven pixels.** Leaflet's bare `invalidateSize()` pans by half the difference between the size it last saw and the container's size now, and the board called it after every frames change — so the first save after the inspector changed height moved the camera, which on this screen belongs to the planner. It is called with `{ pan: false }` now | step 7 (fixed) |
| 32 | **A marker is not a statement.** The board draws every group that has ever been placed on every frame — a position is carried forward — so a frame that states one group still shows three markers. "No other group gained one" is what the inspector's `set`/`same` column says, not what the map shows. The step-7 check asserted the marker count first and was wrong | step 7 |
| 33 | **A badge is not where it will be while the map is still fitting.** Opening a plan (or reloading) animates Leaflet's zoom for about a quarter of a second; a press aimed at a badge measured mid-animation starts **no drag at all** — no save, no toast, no error, so it reads as "the feature is broken". The step-8 check waits for `.leaflet-zoom-anim` to clear; a fixed sleep would be a guess about the browser's speed | step 8 (harness) |
| 34 | **A toast is not proof of a write.** The confirmation is raised only after the reads that follow the save, so it can be missing while the write is committed — the step-8 drag wrote three positions and showed no toast for eight seconds. Read the plan's own re-derived numbers (the warning distance) instead | step 8 |
| 35 | **A plan switch is not proven by a frame count, or by the picker.** The select's value comes from `plan`, which changes before the frames do, and the two plans a check compares can hold the same number of frames *and the same notes* — so "two dots and the right name in the picker" passed while the board was still showing the previous plan, and the check read the wrong strip. Wait for something the plan itself says (the warning it earns), and let the page's own "open the newest plan" finish before dispatching a switch (the race step 7 documented) | step 9 (harness) |
| 36 | **`text()` reads rendered text, not markup.** The harness's `assertContains` uses `innerText`, which applies `text-transform`: a badge whose template says "1 too far apart" reads as "1 TOO FAR APART" and the assertion fails on the stylesheet rather than on the data. When the words matter, assert `textContent` | step 9 (harness) |
| 37 | **The browser's resource-timing buffer holds 250 entries by default, and this page loads a map.** A plan switch fills it with tile requests, so the `frame_save` a check is counting is dropped and `performance.getEntriesByType('resource')` answers 0 for a request that certainly happened (and "nothing was written" assertions pass vacuously). `tools/browser.mjs` raises the buffer on every new document now | step 10 (harness) |
| 38 | **A disabled button swallows a press without a word.** Every write sets `busy` while its save and the reads after it are in flight; a check that presses the next control as soon as the screen changes can click a disabled button and then wait for a request nobody sent. Wait for the control to be enabled (the `press()` helper in the step-10 check), not just for the board to redraw | step 10 (harness) |
| 39 | **A fit that animates can lose the argument with the layout.** Opening a plan fits the map, then the inspector fills and the map grows by more than a quarter of its height; Leaflet's animated zoom finishes with the target it computed for the *old* size, and the board never refits afterwards. So the plan opened by the page itself was framed several zoom levels too far out while the same plan opened from the picker was framed correctly — two doors, two framings, and the step-4 check compared the two. The fit now waits a tick for the inspector, every fit is instant, and an animated fit is gone from the board | step 10 (product: `PlanBoard.fitMap`, `openFirstFrame`) |
| 40 | **`plan_publish` never moved the session's revision, though its own comment said it did.** 039 gave `event_sessions` a `plan_rev` column, commented "publishing again moves it, which is how a screen holding the old timetable can tell it is holding the old timetable" — and `plan_publish` only bumped `plans.rev`. A running session kept the revision it started on for ever, so the column could answer "what did it start on" and nothing else, and the staleness it was built for could never fire | step 15 (fixed: 051) |
| 41 | **The phone shell already owns `.pv-live`.** `native.css` styles `.pv-live` for the events card (`background: var(--pv-brand); color: #fff`), so the new running-plan strip's first version came out as **white text on a cream band** — and no assertion could see it, because the assertions are about words. Renamed to `pv-run-*`; this file's header already carries the same warning about `.pv-head`, which an earlier version borrowed | step 15 (fixed) |
| 42 | **An assertion on a record that no query filled passes.** `select * into v_row ...` with no rows leaves a null record, `v_row.state <> 'late'` is NULL, and PL/pgSQL's `IF NULL` takes the false branch — so the step-15 check's "the other group is still late" passed while the row it named was invisible to the caller. A SQL assertion has to prove `FOUND` before it reads a field; it is R7 in PL/pgSQL form | step 15 (fixed) |
| 43 | **A background tab's timers are throttled, so "wait for the poll" is not a plan.** The tab holding the old payload in the two-tab check is not the focused one, and an interval there can drop to a tick a minute. The re-read is triggered by the `event_sessions` subscription — 051's publish moves the session's `plan_rev`, so another tab's publish arrives as a push — and the check proves the tab actually *asked* by counting the `session_timetable` request in resource timings, rather than trusting the sentence it renders | step 15 |
| 44 | **The strip must name the revision it is showing, not the one the database has.** The first version printed the fresh revision in the version chip beside a sentence saying "what is on screen is version 2", so the same strip claimed two numbers. The held revision drives the chip and the sentence; the newer one appears in the warning and on the button | step 15 (fixed) |
| 45 | **A click measured before the layout settles still lands at the old coordinates.** `rect()` scrolls, waits, and measures — but the page can move *after* the measurement: an inspector that has just filled, a bar that has just moved down. The press then hits the background or a neighbour, no handler runs, and the check reports "waited 8 s for frame +1:00 to open" as if the product were broken. `Tab.click` now asks the page what is under the point (`elementFromPoint`) and measures again up to three times before pressing. The step-15 regression is where it bit: the *first* click of `shortcuts.mjs` failed two runs in five until this was added | step 15 (harness: `tools/browser.mjs`) |
| 46 | **A browser profile is one signed-in person.** Tabs of one browser share `localStorage`, and each new tab's seeded session overwrites it, so a tab opened as the planner makes every tab the planner: the step-16 check's member page started drawing the *board* — role planner, ten rows of it — the moment the planner's tab was opened after it, and the symptom looked like a Vue bug. A check with several identities must finish a person's work, **close** the tab, and only then open the next; step 3's check had the same rule but only by luck of ordering | step 16 (bench) |
| 47 | **The ledger can say a migration is applied while part of it is not there.** `ops.schema_migrations` records 037 as applied; the `activities` table 037 creates is not in the database at all, and nothing had noticed because 038 replaced `plan_list` (which was the only thing that joined it) and no client ever called `activity_list`. 052's first version put a policy on it and aborted the whole file — a migration that touches an older table should ask `to_regclass` first, or not touch it | step 16 (finding) |
| 48 | **A scope that lives in the wrapper is not a scope.** `session_status` is executable by `authenticated` and answered with every group's rows; step 15's timetable filtered *its* result, so the screen was right and the engine was open, and any client could call the engine directly. 052 moved 040's rule into the engine and the timetable stopped repeating it. The bite shows the direction of the dependency: with 050's unscoped body back, a member reads **ten** rows through the timetable, not five | step 16 (fixed in 052) |
| 49 | **An assertion that borrows another policy's effect goes vacuous when that policy changes.** Step 3's check proved RLS *inside* `plan_check` by calling it as a member and expecting exactly their own group's error. Once 052 closed `plan_frames`, the call walks nothing and answers no errors — the assertion "sees no other group's error" was still true, for a completely different reason, and the one beside it ("sees their own") failed. Three more files had built a member-facing assertion on the same door (`step10`'s flags through `plan_frames_list`, `step11`'s and `step12`'s member `plan_check`), and one more (`step9`) counted the fixture's positions without excluding the plan its own prep adds: all four were re-pointed at what they are about (the positions table, or the function's silence) and say why, rather than being deleted | step 16 (checks updated: 3, 9, 10, 11, 12) |
| 50 | **`assertContains` reads `innerText`, and CSS can change what that is.** The schedule's phase badge is uppercased by `.pv-badge`, so asserting the page "contains live" read "LIVE" and failed. Step 3 had already recorded the same trap ("textContent, not innerText: the chip is uppercased by CSS"); it bit again because the assertion was new code | step 16 (bench) |
| 51 | **The schema's default ACL grants EXECUTE on every new function to `authenticated` directly**, so "revoke from public and anon" — the house rule for trigger functions since 040 — leaves `authenticated=X` behind. It is not a way in: Postgres refuses a trigger function that is called directly ("trigger functions can only be called as triggers"), and the check now asserts what is true (`anon` has nothing) instead of what 040's comment claimed | step 17 (finding; check 10f) |
| 52 | **A refused time edit left the typed time on screen.** The field is bound to the frame's time, and a failed write does not change that time, so Vue has nothing new to render and the box keeps saying the time the database just refused — a field that lies until the page is reloaded. `setFrameTime` now puts the frame's own time back in the box when the write fails, which is honesty for every refusal (a stale revision too), not only this step's | step 17 (fixed: `PlanBoard`) |
| 53 | **Deleting a plan that a copy was taken from sets the copy's `fork_of` to null through the foreign key** — and a rule that "a cut must name its original" turned that into a refusal, so the original could never be deleted while a copy existed. The cut is an immutable fact about the plan; naming the original is not. The check is on INSERT only now, and the migration says why | step 17 (fixed in 053) |
| 54 | **A uuid is global, not per-event.** The step-17 database check reused the browser bench's plan uuid for its own plan, so its cleanup `delete from plans where id = …` deleted the *browser bench's* plan (and the copy's foreign key then caught finding 53). Two benches must not share an id even when they are two events; the check now has plans `…b71`/`…b72` and says so | step 17 (check 17) |
| 55 | **A revision the database never asked for is not a revision.** `plan_publish` took a plan id and published whatever was current, so a tab opened across another planner's publish announced its stale picture over it and nothing could tell. Compare-and-set needs three things, not one: the caller's number as an argument, the comparison *under a row lock* (`SELECT … FOR UPDATE` — two publishes that both read 3 must not both pass), and a refusal that names both numbers. The step-18 check proves the refusal; the race is the migration's comment, not an assertion | step 18 (fixed in 054) |
| 56 | **The client replaced every conflict's sentence.** `planErrorMessage` turned every PT409 into one sentence ("Someone else changed this a moment ago. Reopening the plan."), which was right while every conflict was a frame and wrong for a publish that has to name two revisions. It now shows the raised sentence and falls back only when there is none; the frame-save message changed with it ("…Reload the plan."), and nothing asserted the old words | step 18 (fixed: `usePlan.js`) |
| 57 | **The strip took the session's revision as the page's.** `PlanLive` set its "held" revision from its first timetable read, so after step 17's hand-over — a publish that moves the session onto a copy — a tab still drawing revision 1 adopted the session's 2 and never warned; the strip called the newer revision what was on screen. It takes the revision from the plan the board holds now, and the bite is a check that waits 25 s for a warning that never comes | step 18 (fixed: `PlanLive.vue`) |
| 58 | **A rename bumps the revision too.** `plan_save` bumps `plans.rev` for any change to the plan row, its name included, so a rename between a tab's read and its publish makes that publish stale. That is what "the plan's revision" means — the row, not the timetable — and the refusal says "changed", not "published again". If the two should be different revisions, that is a column, not a sentence | step 18 (finding; debt) |
| 59 | **A count of a table is a count of every event the caller works on.** The step-18 check asserted "the root user reads six versions" with `select count(*) from plan_versions` and read **eight**: the step-16, 17 and 18 browser benches had left versions in *their* events, and the root user is staff of all of them, while the policy is per row (the row's own `event_id`). An unscoped count on a bench shared by three events measures the machine, not the event — and the failure doubles as proof that the policy is scoped by event and not by caller | step 18 (check 18) |
| 60 | **The plan row was already the change log.** The step expected `plan_frames` and `plan_positions` in the publication, and a replica identity "for deleted frames". Every frame and position write already ends with `update public.plans set updated_at = now()` (038/041/042/044/045/046/047), so the plan row carries every change and one table is one channel; what the identity was needed for was a deleted **plan** — a DELETE with the default identity carries the primary key only, so an `event_id` filter can never match it. The check asserts the two content tables are *not* published, so a later step that adds them has to say why | step 19 (055) |
| 61 | **Realtime does not apply RLS to DELETE events.** Supabase's own documentation: "there is no way for Postgres to verify that a user has access to a deleted record". A subscription on `plan_positions` would therefore send every replaced position's coordinates to anyone who knows the event id — and every `frame_save` replaces positions wholesale, so it would also be a delete per position that merely stayed. That is the reason the channel is the plan row, and the reason the deletion at the end of the browser check is worth proving | step 19 (055) |
| 62 | **A revision bump is not content.** Adopting the row a publish just wrote would move the board to the new revision with the old frames still under it, and silence the warning step 18 exists for. The channel splits deliberately: a change whose revision did not move is re-read, one whose revision moved is left to the strip. That made step 15's and step 18's "the other tab does not have my frames" assertions false — the other tab *may* have them, and a publish is the moment the board stops adopting content — so both now assert the revision, the part that has to hold | step 19 (client; checks 15 and 18) |
| 63 | **The revision to compare is the one the read answered, not the one the payload carried.** A publish can commit between a frame write's payload and the read that follows it; the payload then says "revision 1, content changed" about a plan that is already 2. Adopting the freshly read row moved the strip's number to 2 while the frames were still revision 1's — and no warning ever appeared (the step-15 and step-18 strips sat silent for 25 s). The fresh row decides now | step 19 (client: `usePlan.adopt`) |
| 64 | **A background read is not compatible with a hand on the board.** A frames reload during a badge drag replaces the marker Leaflet is dragging, and the drag ends with the removed element: no save, no error, the hop simply never happens. A read that overtakes a save does the opposite and puts the pre-write picture back. Background reads are now held from pointer-down to pointer-up and repeated once a save has landed, and the marker layer is not redrawn while a drag owns it. It bit steps 5, 6, 8, 9 and 12 — every check that drags — which is how it was found | step 19 (client: `usePlan.pauseLive`, `PlanBoard`) |
| 65 | **Keys sent before the focus lands type into nothing — or onto the end of the old text.** `Tab.type` clicked the box, pressed Ctrl+A and Backspace, then inserted the text; on a page that re-renders in the background the first keys could arrive before the focus did, so nothing was selected and nothing was deleted, and the field read "+5:00+0:10". The commit then refused the *format* ("Use +1:30 …") instead of the move, and the check waited for a refusal that had never been asked for — once in five runs, and only after the page got busier. `type` now waits for `document.activeElement` to be the element and repeats the clear until the box is empty | step 19 (harness: `tools/browser.mjs`) |
| 66 | **A prep that deletes a copy by `fork_of` can leave the plan it cannot name.** Delete the original first and its copy's `fork_of` becomes null (053's foreign key), so the next prep's `delete … where fork_of = b17` matches nothing; it then deletes the copy's positions directly, which the cut guard refuses, and every later run fails at its own freshness guard. The step-17 prep deletes the event's plans **as plans** now, whatever their `fork_of`, and says why beside the statement | step 19 (bench: `step17-fork-prep.sql`) |
| 67 | **A group's own status is the wrong unit for the step's own sentence.** The sketch gave a group `pending` / `active` / `done`, but a group has two or three moments: its own word flips twice and then says "under way" for the rest of the night, while the done-when asks for a flip as the clock passes **each frame**. Attaching the three words to a moment (and the walk that begins at it) makes each frame flip exactly one row — pending until its time, active until the group's next moment, done after it — and gives the screen both the moment a group is on and the one after. The vocabulary is 027's, kept; the unit changed | step 20 (056) |
| 68 | **The midpoint already existed — inside a trigger.** 021 computes the accuracy-weighted midpoint into `group_positions` on every reading, so "compute it server-side so it is assertable" was already true for the map. The ops read needs the same rule **at a chosen instant**, not at the last reading's arrival, so the rule moved into one internal function that the trigger and the read both call. Done the other way (a second copy of the arithmetic in `plan_ops`) the map and the ops board could disagree about one group's position and both be "right"; the check asserts they answer the same numbers from the same readings | step 20 (056) |
| 69 | **The scope has to come before the per-group reads, not after.** `plan_position_at` enforces 040's rule itself and raises for a group the caller may not read (053), so a read that computed every group's expected position and filtered the rows afterwards would raise for a **member** instead of answering for their group. `plan_ops` scopes in a `visible` CTE first and only then calls the per-group functions — the order is the fix, and the member case in the check is what proves it | step 20 (056) |
| 70 | **The last moment has no walk.** A moment's status is the leg that begins at it, so a group's last moment has no leg: it is `pending` until its own instant and `done` from then on, and a group with a single moment never reads `active`. The alternative — active until a next frame that never comes — would leave a group "under way" after its plan had ended. It also keeps "done" honest: it means the plan has no more moments for the group, not that the group arrived (step 21 marks that) | step 20 (056; documented in the header) |
| 71 | **The two-minute window is measured from the instant you ask, not from now.** A reading recorded at `now - 10 s` is inside the window at `p_at = now`, and outside it at a `p_at` twelve minutes ahead — so a check that stands at a chosen second has to place its readings at that second too, and the first version of the off-site assertion got a null position for exactly this (the reading was "two minutes older than a future instant"). It is the right rule — "how did this look at 18:20" must not use a reading from 18:30 — and it is worth knowing before writing a check that stands in the future | step 20 (check 20, found as `FAIL 6c`) |
| 72 | **A `v-show` page is still mounted, so a panel placed on it runs on every page.** The Live page stays in the DOM behind the others to keep the map's connection, so step 20's ops panel polled `plan_ops` every five seconds while a planner was drawing the plan on the Timeline page — harmless until step 19's deletion test deleted the live plan, and one poll landed between the cascade (`event_sessions.plan_id` → null) and the session reload: an HTTP 400 from a screen that was not even visible, counted by `assertNoErrors` as step 19's failure. The panel is mounted with `v-if="page === 'live'"` now. A check that finds an error from another step's screen is usually right about the screen | step 20 (found by check 19) |
| 73 | **A CHECK constraint re-stated from the files can delete something the database has.** `push_queue.kind` is a CHECK, and 057 has to re-add it to allow three new kinds — so the list has to be restated. Copied from 029 it listed nine kinds; the **live** constraint carries ten, the tenth being `'sos'`, which no migration in this repository writes and eight queue rows hold. The migration **refused** (`23514`, the constraint is validated against existing rows) instead of leaving those rows illegal, which is the right failure and the same lesson as finding 47: the inventory is the database, never the folder. `'sos'` is carried forward with the missing migration noted as somebody's to write | step 21 (057; the first apply failed) |
| 74 | **`now()` is frozen, so a chain written in one transaction has no order.** Two `handover_log` rows written in the same transaction share `now()`, and ordering by the uuid is arbitrary — the second hand-back's "who had it" would be a coin toss, and the browser check's list read the wrong row as newest. `handed_at` is `clock_timestamp()` (the wall clock at the insert) and the previous holder is read off the log ordered by it. A "when" that a person will read and a chain will be ordered by is not a transaction timestamp | step 21 (057, found as `FAIL 4k`) |
| 75 | **The first hand-back named a previous holder called "someone".** `coalesce(display_name, username, 'someone')` returns a name for a `from_user` that does not exist, so the very first row of a session read "Handed from someone to testuser1" — an invented person, and the panel had no way to tell a first hand-back from a chain. `handover_log_list` now answers null when there is no previous holder, and the screen falls back to "Board with X since …". **The SQL check did not catch it** — its name assertion only looked at the newest row — the browser check did, and the null is now asserted (4l) | step 21 (057, found by check 21) |
| 76 | **One phone cannot both walk into a box and have a believable speed.** The auto-close assertion wants the IC to **enter** the zone after the moment (so the close is dated from the entry), and the ETA assertion wants a **measured** speed from the same group; the same phone walking 300 m into the box in 50 s measures 6.1 m/s, and `refresh_group_position`'s speed comes from the newest reading's last minute. The fixture gives the speed to a second phone tagged with the group (membership is the auto-close's rule, not `group_position_at`'s) and the entry to the IC — a fixture problem, recorded because it is the shape any later check of "speed + presence" will meet | step 21 (check 21) |
| 77 | **A tick needs parameters a client never passes.** Both new tick functions take optional `p_session` and `p_at`: cron calls them with no arguments and they walk every live plan session at `now()`, while a check stands at one session and one chosen second. Without them the check's only choice is to move the world's clock or to count rows across every other live session on the project (finding 59's lesson). They are **not** a client door: no grant to `authenticated`, and the check proves it | step 21 (057) |
| 78 | **A gap in the tick loses a nudge, it does not backfill it.** `plan_collect_pushes` only nudges moments at most a minute old, deliberately: a tick that has been down for an hour must not tell six groups they are due *now*, all at once, about moments that passed. The consequence is that a cron outage is silently a missed nudge (no retry, no log), which the auto-close does not share — that one closes the current moment whenever it next runs, dated from the entry | step 21 (057, documented in the header) |
| 79 | **A poll can outlive the plan it is asking about.** Deleting the live plan nulls `event_sessions.plan_id` and leaves `t0_at` behind, so for the second between the delete and the tab hearing about it a 30 s poll of `session_timetable` (or `plan_ops`) still arrives at a session that is "not running a plan" and gets HTTP 400 — which Chrome logs as a console error. Step 19's check caught it in its own deletion test, on a screen nothing to do with step 21. Both reads now answer **no rows** for a session whose plan is gone while still refusing one that never had a plan (`t0_at` is the difference), which is exactly the state the schedule's "running without a plan" sentence was written for. Same family as finding 72: a screen asking about something that no longer exists | step 21 (057 sections 7 and 10; found by check 19) |
| 80 | **A check can depend on the hour.** The bench's ended session starts at 18:45 and ends at 19:30, and 021's presence trigger gives a reading to the open-or-covering session with the **latest** start. Step 20's check inserts readings "ten seconds ago", so after 18:45 those readings fall inside the bench's own session, the trigger wrote the midpoint into *that* session, and section 4 failed — on a check that had passed every time it ran in the afternoon, and through steps 14–21 at 18:40. The fix is in the check (the bench's session is moved a week back inside the transaction), and the lesson is that a fixture with fixed wall-clock times is a trap the moment a check starts inserting "now" | step 20 (found by step 21's regression run, as `FAIL 4h`) |
| 80 | **A check can depend on the hour.** The bench's ended session starts at 18:45 and ends at 19:30, and 021's presence trigger gives a reading to the open-or-covering session with the **latest** start. Step 20's check inserts readings "ten seconds ago", so after 18:45 those readings fall inside the bench's own session, the trigger wrote the midpoint into *that* session, and section 4 failed — on a check that had passed every time it ran in the afternoon, and through steps 14–21 at 18:40. The fix is in the check (the bench's session is moved a week back inside the transaction), and the lesson is that a fixture with fixed wall-clock times is a trap the moment a check starts inserting "now" | step 20 (found by step 21's regression run, as `FAIL 4h`) |
| 81 | **A plan's message would have been written into the log step 25 deletes.** The event already has a broadcast (032) that writes a `show_log` line when a show is running; a plan message borrowing that table would be deleted with the run-sheet engine, and its twenty kinds are about cues and GO. A plan session has no cue to attach a message to, and the audience is the plan's groups. So `plan_log` is a table of its own with its own push kinds, and the step's done-when is exactly this: **one row to the new log, zero to `show_log`** — asserted after every send and every publish, so a later step cannot quietly reintroduce the shortcut | step 22 (058) |
| 82 | **A copy's first publish must compare the future, not the anchor.** `plan_fork` starts the copy with a frame at the cut, holding everybody where the walk already had them; the hand-over then records them arrived at it. Compared against the plan it was cut from, that frame is "new for every group" — so the first publish of every copy told every group on the plan, which is the targeting this step exists to add, broken in its main case. The comparison window is `> fork_cut_s` on **both** sides: nothing changed at the cut, and what the groups were told changes between the cut and the end of the walk | step 22 (058; `FAIL 7c` when the window was opened) |
| 83 | **A tally read from the recipients' group column cannot show a group with nobody in it.** The check expected the memberless group in the recipients' group set, but a group with no members contributes no recipient rows — it is in the row's sentence and in nobody's inbox. The assertion was measuring the wrong side (inboxes instead of the record) and now reads the sentence for the three walks and the inbox count separately. A "who was affected" question and a "who was told" question have different answers, and the panel shows the second | step 22 (check 22, section 6) |
| 84 | **Three checks clicked the bar head's second button.** The strip's bar head was "−, +" and nothing else that mattered, and board smoke, step 5 and step 12 clicked `button index 1` to zoom in. The run's Play/Pause/speed buttons were added to the same head, so the checks pressed the speed control instead, the dots stayed overlapping, and the next click opened the wrong moment — a step-22 change failing three older proofs that were not wrong about the product. The zoom buttons are named now (`[data-testid=zoom-in|zoom-out]`) and the three checks click the name. A position in a row of buttons is not a contract (finding 25's family) | step 22 (client; checks 1, 5, 12) |
| 85 | **Two publishes are two versions, not two revisions.** The check expected three `plan_versions` after two publishes, counting the draft's revision 1 — but a draft was never announced, and `plan_publish` writes the version at the revision it produced. The invariant is one version per **publish**, and a check has to say which of the two numbers it means | step 22 (check 22, found as `FAIL 4c`) |
| 86 | **The browser bench's identity is the browser's, not the tab's.** localStorage is shared, so a tab that reads *again* after another identity has been seeded — a 30 s poll, or the re-read an ack triggers — can answer as the newest person. Step 22's Gate Crew tab acked its message after the Sound tab had been opened, its re-read went out as Sound, and the timeline row addressed to Gate Crew vanished mid-check (`Cannot read properties of null`). Each identity now does all of its reading while it is the newest tab, and the trough the acks moved is read at the end on a **fresh** planner tab. The step-16 warning about tab order had the symptom; this is the mechanism | step 22 (check 22; harness) |
| 87 | **A flaky proof is not a proof (observed, not explained).** Step 8's drag failed twice while the machine was busy — once on a toast that had not appeared, once on an 8 s wait for the re-read after the solo drag — and passed twice on a clean run with all 49 assertions. Nothing in step 22 touches the drag path (`drawMarkers` with no run in flight is the code it always was), which is a reason to look again, not a diagnosis. Recorded because "it passed when I ran it" is exactly what this document keeps refusing to accept | step 22 (observed during the regression run) |

---

## Standing rules — apply to every step, or it will bite later

- **R1. Qualify `extensions.`** and put `extensions` in any function's `search_path`. PostGIS is not in `public`.
- **R2. Changing a function's return type means DROP + recreate + re-GRANT**, never `create or replace`.
- **R3. Every new table: `enable row level security`, a read policy on `is_event_member`, and no table grants to
  `authenticated`.** Writes go through `security definer` functions only.
- **R4. Every new function: `revoke execute … from public, anon` and an explicit `grant execute … to authenticated`.**
  The original wording ("there are no default privileges here") was wrong: the schema's default ACL grants every new
  function an EXECUTE to `anon` directly, so revoking from `PUBLIC` alone leaves `anon=X` behind — 042 did exactly
  that and 043 fixed it. Revoke from both, every time.
- **R5. A session runs a plan, or nothing — never both.** (Written in step 2 as "a plan or a run sheet, or neither";
  step 24 removed the run-sheet parameter, so since 060 there is no second thing to run and step 25 deleted the engine
  that would have run it.)
- **R6. Tests prove the interaction, not the payload.** Anything with a button or a drag is checked through the
  browser runner, not by replaying RPC calls.
- **R7. An assertion has to be able to fail.** A condition handed to the browser runner is evaluated in the page and
  must answer exactly `true`; a string, a truthy object or a thrown exception is a failure, not a pass. (Nineteen
  assertions across steps 1–5 could not fail at all, because the runner took the expression itself as true —
  finding 26.)
- **R8. Copy a function body from the *latest* migration that defines it**, never from the one that introduced it.
  `044` re-created `frame_save` from 038 and silently undid 041's client-supplied ids (finding 30); the step-4 check
  caught it, which is the reason every step keeps one.

---

## The 28 steps

### Infrastructure first

**1. Prove-it tooling and trustworthy fixtures** — M
Extend `tools/shot.mjs` into a step-list runner: click, type, drag, key, wait-for, reload, assert-text, and two
tabs at once. Add a runner for the numbered migrations (today `tools/pgtest.mjs` is a hardcoded file list, and
nothing records what has been applied). Add fixtures: ≥2 groups, a no-go zone, two ICs, and a session whose
`t0_at` differs from `starts_at` — the seeded single-group plan makes half the later checks vacuous.
**Done when:** one script performs "load page → click → reload → assert text" against the preview and fails loudly
when the assert is wrong; and a second tab can be opened and asserted independently.

**Done.** `tools/browser.mjs` drives a real Edge over the DevTools protocol — `goto`, `click`, `type`, `press`,
`drag`, `reload`, `waitFor`, `text`, `assertText`, `assertContains`, `assertCount`, `assertThat`, `shot`, many tabs.
Input is dispatched as trusted events, so a `pointerdown` handler is reached only when it would be reached by a
finger. `tools/run.mjs <check.mjs>` runs one check and exits non-zero on the first false assertion, printing what
the page actually said. `dev/checks/board-smoke.mjs` passes 20 assertions across two tabs (load, click, drag a
frame from +2:00 to +2:50, type a note, reload, re-select, and neither tab stealing the other's selection);
`dev/checks/board-lies.mjs` is wrong on purpose and exits 1. `tools/migrate.mjs` gives `status`/`up`/`adopt` over
`ops.schema_migrations`, and all 38 existing files are adopted with checksums. `supabase/fixtures/plan_bench.sql`
builds one event: 4 groups, 3 people (two ICs in Gate Crew), 2 zones (a no-go between two positions 20 m apart), 3
plans (one invalid with a 200 m jump, one valid, and a two-frame copy bench added in step 4), 32 positions, and a
session that starts at 18:45 while its plan's T+0 is 18:00. Re-running it is safe. Prove it: `npm run check:board`
(needs `npm run dev -- --port 5178`).

### A — one engine, and who may see what

**2. A session runs a plan or a run sheet, never both** — M
`event_sessions.plan_id` + `t0_at` + `plan_rev`; a "not both" check (R5); DROP and recreate
`start_event`/`schedule_event_start` with `p_run_sheet` and `p_plan` **both defaulted to null, re-granting in the
same migration**; old tick functions skip plan sessions; **the Start/Schedule dialog gains a plan picker**
(`EventStatus.vue`), not just the RPC; `EventView` hides `NextMoveCard`/`ShowBar`/`OpsQueue` for a plan session;
**renaming a plan no longer resets its status**.
**Done when:** a session is started *from the UI* on a plan; both-set is refused; two ticks after it produce no
push rows for it, while a run-sheet session in the same run **does** push (positive control).

**DONE.** `039_session_plan.sql`: `event_sessions` gains `plan_id`, `t0_at` and `plan_rev`; a CHECK refuses a session
with both a plan and a run sheet; `start_event`/`schedule_event_start` are dropped and recreated with `p_plan`
defaulted to null and re-granted; `session_engine()` and `plan_t0()` decide what may run and when its clock starts;
`show_tick`/`move_tick` skip plan sessions; `switch_live_run_sheet` says why it cannot touch one; `plan_save` no
longer resets status (or `for_date`/`t0_time`) when they are not sent. `EventStatus` has one "What runs" picker with
run sheets and plans in it, published plans only; Start is disabled until that list has loaded; `EventView` hides
`NextMoveCard`, `ShowBar` and `OpsQueue` for a plan session.
Prove it: `node tools/sql.mjs --file dev/checks/step2-session-plan.sql` (refusals, `t0_at` = 18:00 while the session
started at 18:45, zero rows from both ticks and from the push collector, and a real run-sheet session in the same run
that both ticks still process) and
`node tools/run.mjs dev/checks/step2-start-on-a-plan.mjs --session .tmp/session.json` (11 assertions: the picker
offers the published plan, refuses the draft one, the confirm names it, the status reads "Running plan: Clean walk",
no run-sheet machinery appears, the event ends again).
**Not proved:** the push positive control. Pushes need `leave_by`/"late", which come from live GPS, and a session
created with no people in it has nothing to say. `push_collect_moves` is untouched by 039 and is replaced in 21/24.

**3. Members see only their own group** — M
Closes a live defect: the board renders for any member and the policy is `is_event_member`, so every group's
positions are readable. A read function returning only my group unless I am staff, or a policy that says the same.
**Done when:** impersonating two members in SQL, each sees only their own group's rows; a planner sees all.

**DONE.** `040_plan_group_scope.sql` gives `plan_positions_read` the rule the rest of the app already uses:
ops staff (`root`, `planner`, `marshal` — the same trio as `FEATURE_ACCESS.wholeEvent` and the movements policies
in 027) read every group; everyone else reads only `group_id = my_group_id(event_id)`. A group admin is *not*
staff and sees their group only. The same file closes finding 20: every 037/038 plan function is revoked from
PUBLIC and `anon` and granted to `authenticated`, trigger functions included (revoked, not granted — they fire
with the table). `EventView` passes `only-group-id` for everyone except ops staff; `PlanBoard` draws only that
group, labels the board "your group only", opens **only the published plan** for them (no plan picker, so a draft
cannot be browsed) and shows an honest empty state before anything is published or when the person is in no group.
The board also now fits the map to the polygons **and** the plan — fitting to the polygons alone opened a plan
whose groups stood outside the drawn areas with not one marker in view (finding 22).
Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step3-group-scope.sql` — a Gate Crew IC sees 4 of the clean plan's 16
positions and one group, the second IC sees the same, Sound's group admin sees 4 and only *their own* 200 m error
from `plan_check` (the Gate Crew IC sees zero), both planners see all 16 and the error, and a marshal added
temporarily sees 16 while on duty and 4 again once the duty is deleted; grants are PUBLIC 0 / anon 0 /
authenticated 12 of 12. The check was then broken on purpose twice — the old `is_event_member` policy, and one
function back on PUBLIC — and it failed at 1a and 7a respectively before both were restored. Through the screen:
`node tools/run.mjs dev/checks/step3-member-view.mjs --session .tmp/session.json` with a second session for
testuser3 (`node tools/authlink.mjs 2906655b-… .tmp/session3.json`), 21 assertions and two tabs: the planner
publishes "Clean walk" and sees four groups; the member sees "your group only", four frames, exactly one group row
(Sound), one marker, no other group's name anywhere on the page, and no add / copy / publish controls. Screenshot
`shots/step3-member-view.png`.
**Not fixed here:** the database still lets a member read an unpublished plan's frames and notes (`plans_read` and
`plan_frames_read` are `is_event_member`). The board no longer offers a draft; the member's real read path — their
own timetable — is built in step 16, which is where that half is closed and asserted in the browser (finding 23).
**Closed by step 16:** 052 narrowed both policies and the engine, and the member's browser half moved to
`dev/checks/step16-schedule.mjs` — the board this check asserted is no longer a member's screen, so its browser file
was retired and its database file re-pointed at the positions rule (finding 49).

### B — drawing a strip quickly

**4. Copy and paste, proved through the browser** — S
Pure `snapshotAt(tracks, frameId)`; paste becomes one write; **`frame_save` accepts a client-supplied id on
create**, which undo needs to restore a deleted frame without orphaning progress.
**Done when:** click path — a frame stating 3 groups and one stating 1; copy the second, paste, reload → 3
positions at the source coordinates, note kept.

**DONE.** `snapshotAt(tracks, frameId)` in `src/utils/planFrames.js` resolves a frame to what it *means*: the
groups it states plus every group carried into it from earlier frames. `PlanBoard.copyFrame` uses it, so the
clipboard is a plain position map and `pasteFrame` stays one `frame_save` (a second write was already removed:
a failure between the two left a frame holding the wrong positions). `041_frame_id.sql` teaches `frame_save` to
honour a client-supplied id on create — free id → created with it, the same id again → the update path (a retry is
idempotent), an id owned by another plan → refused rather than moved, no id → minted exactly as before. Step 13's
undo needs that to restore a deleted frame without orphaning the rows that point at it.
Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step4-frame-id.sql` — fifteen assertions in one rolled-back transaction:
create-with-id returns that id at rev 1 with its positions and note; the identical call again leaves one frame at
+5:00 on rev 2 and replaces the positions wholesale; a stale rev still raises PT409; another plan's id is refused
and its frame stays in that plan; no id still mints one, and a duplicate time is still refused. Proven to bite:
with the 038 body restored the check dies on the first call ("That frame is not in this plan"). Through the
screen: `node tools/run.mjs dev/checks/step4-copy-paste.mjs --session .tmp/session.json`, 24 assertions. The bench
gained "Copy bench": +0:00 states three groups, +1:00 states only Gate Crew 11 m east with the note "one here".
The check opens it, copies +1:00, pastes at +2:00 and measures the page: the pasted frame states all three groups,
its markers sit on the same pixels as the source's (measured inside the map container, not the viewport, because
clicking a frame scrolls the page), the note came across, and after a reload the stored frame still states three
at those pixels. Proven to bite: copying only the frame's own row fails at "the pasted frame states all three
groups". Screenshot `shots/step4-copy-paste.png`.
**Also fixed in the harness, because this step's first clicks silently did nothing:** `tools/browser.mjs` read an
element's rect in the same evaluation that scrolled it into view. Layout is updated synchronously, but the input
pipeline maps a click through the compositor's scroll offset a frame later, so the first click after a big scroll
landed at the pre-scroll coordinates and hit the background. `rect()` now scrolls, waits for the scroll to commit
(two animation frames, raced with a timer because a background tab never gets one), then reads. The unconditional
rAF wait also hung `board-smoke` in its second tab; that check is green again (20 assertions).
**Keyboard, added at your request and kept where the action lives:** Ctrl+C copies the open frame and Ctrl+V
pastes it — the same two functions the buttons call, wired to one `keydown` listener on the window, with three
refusals: a keystroke inside a field stays in the field (Ctrl+C in the note copies words, not the frame), the
confirm dialog keeps the keys while it is up, and a member's board has no shortcut because it has nothing to
accelerate. Clicking a frame dot now blurs the field, so the keyboard belongs to the board again after a click
(the dot's `pointerdown` is prevented for dragging, which previously left focus in the note field). Ctrl+Z is
deliberately **not** here: undo is the inverse stack in step 13, where the shortcut belongs. Prove it:
`node tools/run.mjs dev/checks/shortcuts.mjs --session .tmp/session.json` — 18 assertions: with focus in the
note field the board does not even claim the key and no frame appears, and on the board Ctrl+C then Ctrl+V
creates +2:00 with all three groups and the note. Proven to bite: with the typing guard removed the first
assertion fails (`claimed: true`). One limit, recorded: a *real* Ctrl+C through CDP wedges this sandbox's
headless browser (the browser's copy command reaches for the OS clipboard and the renderer blocks), so the check
dispatches the key as a DOM `KeyboardEvent` on the focused element and asserts `defaultPrevented`; the buttons
themselves are still proved with trusted clicks above. Screenshot `shots/shortcuts.png`.

**5. Fill a gap** — M, needs 4
"Fill gap" between two frames for chosen groups; a **batch RPC `frames_fill`** (not a loop — each `saveFrame`
reloads everything and needs a live rev); merge required times across groups, since `subdivide()` is per-group.
**Done when:** no two frames share a `t_s` anywhere, every neighbouring pair of every group is ≤25 m, **and** the
whole fill is one round trip.

**DONE.** `042_frames_fill.sql` adds `frames_fill(p_plan, p_from, p_to, p_groups)`: name the two ends and the
groups and it writes the frames that split the distance. It resolves each group's position as it *stands* at both
ends rather than reading the two frames' own rows, so a stretch that begins at a frame the group inherited from
works — and that is the shape the board's warning usually has. Steps are sized to **24 m**, not 25 (finding 21).
The times the groups need are merged: each group's own grid is added to one array, duplicates dropped, and every
filled group is written at every time in it. That is safe because every position it writes lies on the straight
line, so an extra sample can only shorten a step. A frame already sitting at one of those times is **reused** — its
note and the other groups' positions are untouched, only its `rev` is bumped, because a frame that gains a position
has changed and a planner holding the old copy should be told to reload rather than overwrite it. Then it walks the
rows it just wrote and **refuses the whole call** if rounding still leaves a step over the limit (200 m in ten
seconds cannot be split into whole seconds), so a fill is never half-done. Before writing it refuses four things: a
group that already stands *between* the two frames (it never overwrites a position somebody placed deliberately),
another plan's frame, another event's group, and a caller who is not root or planner.

The client is one call and one reload: `usePlan.fillGap` calls the RPC and reloads frames and plans once. In
`PlanBoard`, `gapGroups(gap)` collects every gap that runs between the *same two frames* — a stretch is usually
broken for more than one group, because they walk together — and `fillGap(gap)` names them all in that one request.
Each warning row carries a **Fill** button (its title says "these groups" when it covers more than one), and the
warnings block moved out of the selected-frame panel: what is wrong with the plan is not a property of the frame
that happens to be open. `subdivide()` is gone from `planFrames.js`: merging per-group step counts is exactly what
the client cannot do once the times are shared, and nothing called it.

Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step5-fill-gap.sql`. On the bench's real 200 m jump: one call adds 8 frames
and 8 positions, `plan_check` then reports nothing, every other group's rows are byte-identical (a `jsonb_agg`
compared before and after), the two ends did not move or change `rev`, no two frames share a time, and every row it
wrote is on the straight line. Its own two-frame plan covers the case the bench cannot: Gate Crew 60 m (3 steps) and
Sound 100 m (5 steps) produce the merged grid 60/100/120/180/200/240, a frame already at 200 is reused with its
note kept and `rev` 1→2, 12 positions are written, and the longest step is 20 m. It also proves the refusals,
including a 100 m stretch in 2 s where the self-check catches its own arithmetic and nothing is left behind, and a
participant (a group admin) being refused. **Proven to bite:** with the union replaced by "only the first group
decides the times", the call dies on "a step would still be 33 m apart" — the self-check, not the assertion, which
is the stronger answer.
**One thing 042 got wrong, found by looking:** it revoked `PUBLIC` but not `anon`, and this schema's default
privileges grant every new function an EXECUTE to `anon` directly, so `pg_proc` showed `anon=X` on `frames_fill`
while every other plan function was clean — the same trap as finding 20. Not a way in (the function checks the
caller's role first), but the wrong shape, and `043_frames_fill_anon.sql` revokes `public, anon` and re-grants
`authenticated`. The check now reads `pg_proc` and the ACL, and **proven to bite** with `grant execute … to anon`
put back: it fails at "anon can execute frames_fill".

Through the screen: `node tools/run.mjs dev/checks/step5-fill-gap.mjs --session .tmp/session.json`, **44
assertions**. The bench's Walkthrough shows two red dots, a red band, the "1 too far apart" badge and one warning
row naming Sound and 200 m; one click turns its 6 frames into 14, with exactly **one** `rpc/frames_fill` in the
browser's resource timing before and after. The gap closes, no dot is red, and clicking **+2:07** — a frame that
did not exist before — draws Sound's marker between +2:00 and +3:00, on the same latitude, at 7/60 of the way along
(which is where the straight line puts it, since the samples are evenly spaced in time). All of that survives a
reload. The new bench plan **"Twin gap"** then covers the multi-group case in the UI: Gate Crew and Sound are both
200 m out between the same two frames, so two warnings name one stretch, both buttons say "these groups", and one
click fills both in **one** round trip. Screenshots `shots/step5-before-fill.png` and `shots/step5-fill-gap.png`.
**Proven to bite:** with the board filling the groups one at a time, the check fails at "filling a stretch two
groups share is still one round trip".
**Two limits worth knowing.** The board and `plan_check` name *different* frames for the same jump (finding 24) —
step 12 ended that: both now report from the frame that stated the position, with the budget counted in frame steps.
And at the default zoom two frames 13 s apart draw overlapping dots, so the later one wins the hit test; the −/+
zoom separates them (finding 25).

**6. Push a chunk** — M
`frame_shift` gains `p_to_s`; **selection model designed here once** (frame-id and group-id sets inside
`PlanBoard`, shared by bar and inspector — steps 8 and 10 will otherwise invent their own); guards for below
T+0, **above the `t_s` ceiling (currently unguarded)**, and passing an untouched frame.
**Done when:** 0/60/120/180, shifting 60..120 by +300 moves exactly 2 and leaves 0 and 180; shifting 0..60 by +300
is refused.

**DONE.** `044_frame_shift_range.sql` gives `frame_shift` a fourth argument: name both ends of the stretch and only
the frames between them move; leave `p_to_s` out and everything at or after `p_from_s` still travels, which is the
"we are five minutes behind" move. A bounded chunk is **not** a ripple — the frames after it do not make room, so a
chunk pushed far enough *passes over* a frame that stays put: 0/60/120/180 with +1:00..+2:00 pushed by +300 becomes
0/180/360/420, which is the Done-when's own example. That is allowed on purpose. The strip is ordered by time, not by
an index, so two moments swapping order is a legal edit; what is refused is landing *exactly* on a frame that stays
put, which is a collision and says so. The consequence is worth knowing: reordering changes which positions are
neighbours, so the 25 m rule has something new to say afterwards — four broken pairs in that example, the longest
73 m — and the board shows them in red rather than hiding the side effect.

**The Done-when's second half was wrong, and is corrected here.** It says "shifting 0..60 by +300 is refused".
Nothing can refuse that: +300 moves frames *later*; the guard the step lists first is T+0, which only a negative
delta can reach. Worse, pinning the frame at T+0 would make `frame_shift(p_from_s => 0, p_to_s => null)` — "push the
whole run by five minutes", the operation 038 was written for — impossible. So the check proves the refusal the step
*names* (0..60 by **−300**, refused with a sentence about T+0) and then proves that **+300 on the same stretch is
accepted**, because it has to be.

Three guards, and the one that was missing: below T+0 (from 038); **above the `t_s` ceiling** — `plan_frames_t_range`
allows three days, and a shift or a move past it used to arrive as a raw check-constraint violation from inside an
UPDATE, so `frame_shift`, `frame_move` and `frame_save` all name the limit now, tested at the boundary and one second
past it; and a stretch that holds no frame, which used to answer 0 — a count of zero is indistinguishable from
success at the other end of the wire.

**The selection model, designed once.** `PlanBoard` holds the two sets the step asked for. `selection` is the frames
selected on the bar and is always a contiguous run of time (click picks one, Shift+click extends from the open frame,
a sweep across the bar picks the run it touches) — that is what lets a whole stretch be named by two times without
the client and the server disagreeing about what "selected" means. `selectedGroups` is the groups ticked in the
inspector: any subset, and the rest step back on the map; nothing else reads it yet, because steps 8 and 10 are where
it moves and verifies. The open frame is still exactly one — the moment the map shows, what the inspector and Ctrl+C
act on — and it is always one of the selected frames. Dragging any selected dot moves the whole stretch in **one**
`frame_shift`, previewed by adding the same delta to every selected dot; pushed past T+0 it stops at T+0 rather than
squashing its first frames onto it. There is **deliberately no Ctrl+click** to pick frames out of the middle: with a
two-time span, a selection with a hole would move the frames in the hole. The arrow keys step the strip (←/→ open the
neighbouring frame, Shift+←/→ extend) — the reliable way to reach a dot that is under another one at the current zoom
(finding 25), and the only control added here that is not a button.

Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step6-push-chunk.sql`. On the bench's new **"Push bench"** plan — four frames at
0/60/120/180, one note each, every step legal — one call moves exactly two: the strip becomes 0/180/360/420, the two
frames outside the stretch keep their id, time, revision **and** note, the two inside keep their ids and notes and gain
a revision, positions travel with their frames (8 of them), and `plan_check` then reports the four pairs the new order
creates, the longest 72 m. The refusal names T+0 and leaves the strip byte-identical; 0..60 by +300 is accepted;
pulling the same two frames back across the frame at +3:00 restores the original order and the rule goes quiet again.
The ceiling is exercised three ways (frame_save, frame_move, frame_shift) at the boundary and one second past it, and
a three-argument `frame_shift` no longer exists — an overload left behind would keep the old, unguarded behaviour
reachable by name. **Proven to bite:** with the far end ignored (the call made a ripple) section 1 fails at "moved 3
frames, expected exactly 2"; with the ceiling constant widened, section 6 fails at "frame_shift let the table
constraint answer instead of naming the limit".

Through the screen: `node tools/run.mjs dev/checks/step6-push-chunk.mjs --session .tmp/session.json`, **44
assertions**. The strip opens at +0:00/+1:00/+2:00/+3:00 with its notes and its markers inside the map view; ticking a
group steps the other one back on the map; Shift+click, ←/→ and Shift+←/→ build the same stretch; **−1m** on
+0:00..+1:00 is refused in the toast and nothing moves; **+5m** on +1:00..+2:00 moves exactly those two — +3:00 keeps
its note, the two that moved land on +6:00 and +7:00 carrying their own — and the header then reads "4 too far apart"
with three dots red, the reorder reported rather than hidden. It survives a reload. Dragging one dot of a two-frame
stretch moves both in one request and leaves the other two; sweeping across the bar selects the run it touches.
Screenshot `shots/step6-push-chunk.png`. **Proven to bite:** with `p_to_s` sent as null the check fails at the "2
frames moved by +5:00" toast; without the Shift+click guard (the dot picking itself on pointerdown) it fails at "2
frames, +1:00 → +2:00".

**Five things this step found, four of them older than it.**
1. **The runner took a string as true.** `assertThat(name, expr)` accepted a JavaScript *expression* and did
   `!!condition` on the string itself, so nineteen assertions across steps 1–5 passed whether or not the page agreed.
   It now evaluates the expression in the page and requires exactly `true`, and a throw fails with its message.
   Re-running the older checks with live assertions found the next three bugs; all four checks are green now,
   counted rather than assumed.
2. **A note never reached the plan.** `frame_save` was called from `@change`, and `change` does not fire for a value
   the browser does not consider user-edited, so a typed note stayed on screen and was never written. The field
   commits on **blur** now (guarded, so leaving an unchanged field writes nothing) and Enter blurs it.
3. **A note typed against one frame was filed against another.** The blur happened during the click's own selection
   change, so the handler read the *new* open frame; `blurActive()` now runs before the selection moves, in both the
   click and the pointerdown paths.
4. **A plan could open with none of its markers in view.** The map deliberately does not re-fit on a save, but it did
   not re-fit when the *plan* changed either, so switching to a plan drawn elsewhere kept the previous plan's corner
   (finding 22's other half). Opening a plan now resets the fit.
5. **In this step's own migration:** `044` re-created `frame_save` from 038's body to add the ceiling guard, which
   silently reverted **041**'s client-supplied id on create. `step4-frame-id.sql` caught it on the next run ("That
   frame is not in this plan"); the body now comes from the latest file and R8 records the rule.

**7. Hold one group** — S, needs 5
One control writes a frame at t+Δ stating that group where it already is.
**Done when:** click path — the row at `t_s = 300` for that group equals the one at `t_s = 0`, and no other group
gained one.

**DONE.** `045_frame_hold.sql` adds `frame_hold(p_plan, p_frame, p_seconds, p_groups)`: name the frame the groups
stand at, how long they stay there, and which groups — and it writes the later moment that says so. It is the first
write in this plan that is **partial on purpose**: `frame_save` replaces a frame's positions wholesale, so holding one
group through it would either restate every other group or wipe the ones that frame already says. The function adds
these groups and touches nothing else, and it reads each group's position *as it stands* — the last thing it said at
or before the frame — so a frame that only inherits a position still works. It inherits 042's two rules verbatim
(that is the step's "needs 5"): resolve by inheritance, and **reuse a frame that already exists at the wanted
moment** — its note and the other groups' rows stay, only its `rev` is bumped, because a frame that gains a position
has changed. Holding the same group to the same moment twice writes nothing and bumps nothing: twice is once.

**What it refuses, and each refusal is a decision rather than a failure.** A group that stands nowhere yet has
nothing to hold. A group that **moves before the moment asked for** would not be delayed by the hold, it would be
sent back: the strip's 0/60/120/180 with a hold from +0:00 to +5:00 would draw a 72 m jump back at +5:00, so the call
says which frame it moves at and suggests holding from there or pushing those frames later first (step 6's
operation). A frame at the wanted moment that **already puts the group somewhere else** is somebody's placement, and
silently rewriting it is exactly what 042 refuses to do to a position in the middle of a stretch. And a target past
the three-day ceiling answers in words instead of arriving as `plan_frames_t_range` from inside an INSERT (044).

**The invariant, kept in the check rather than argued:** a hold cannot make the 25 m rule worse. With no statement in
between, the old hop P→N becomes P→P (zero metres) plus P→N (unchanged), so `plan_check` reports the same breaks —
Walkthrough's one 200 m error is read before and after, and has to be identical.

On the screen it is one row of durations in the inspector — **Hold +1m / +5m / +10m** — acting on the groups ticked
in the group list, or on **everyone standing at that frame** when nothing is ticked (a rain delay is a hold of
everybody). The ticks had only dimmed the map until now; this is the first thing they *do*, and the inspector line
names exactly who will be written ("Keep Sound where it stands"). The open frame does not jump: the planner stays
where they were and the new dot appears on the strip.

Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step7-hold-group.sql` — **70 assertions** in one rolled-back transaction. On
"Copy bench" (Sound stated once at +0:00, Gate Crew again at +1:00) holding Sound to +5:00 creates one frame, states
one group, and that row is *byte-identical* to the row at +0:00; every other row in the plan is compared before and
after and is unchanged. Holding Sound to the existing +1:00 reuses that frame: id kept, note "one here" kept, Gate
Crew's position kept, revision 1→2, and the second identical call writes nothing and leaves the revision alone. Then
the refusals — Twin gap's overwrite, Push bench's move at +1:00, a group that stands nowhere, another event's group,
another plan's frame, a plan that does not exist, a hold of zero and of minus a minute, a frame with nothing to hold
— and the ceiling exercised at 259200 and one second past it; then the default (no group list holds the two groups
standing there and nobody else, and the two 200 m breaks keep their distance); then the doors (signature, `anon` and
PUBLIC grants) and a participant (a group admin) refused.
**Proven to bite, twice, by injecting the bug into the deployed function and re-running the check:** with the
"already stands somewhere else" guard removed it dies on "the hold overwrote a position somebody had placed"; with the
group list ignored (hold everyone standing) it dies on "Gate Crew moves before +5:00" — the refusal catching its own
wrongness, which is the stronger failure.

Through the screen: `node tools/run.mjs dev/checks/step7-hold-group.mjs --session .tmp/session.json`, **37
assertions**. The board opens Copy bench on +0:00 with its four group rows; the hold line names all three groups
standing there; ticking Sound narrows it to Sound and steps the other two back; **Hold +5m is exactly one
`rpc/frame_hold` in the browser's resource timing**, the strip gains +5:00, and the frame the planner was on is still
open. Opening +5:00 draws Sound's marker on the *same pixels* it had at +0:00 (measured inside the map container),
while only Sound's row says "set" and the other two say "same" — carried forward, not stated — which is the
Done-when's "no other group gained one" read off the screen. Nothing is red. It survives a reload. Then the two
holds that would lie: Twin gap's +5:00 refuses with "already stands somewhere else at +5:00", Push bench's with
"moves before +5:00", and neither strip changes. Screenshot `shots/step7-hold-group.png`.

**Two things this step found, both by measuring rather than looking.**
1. **A save could nudge the map by seven pixels** (finding 31). The pixel comparison showed the held marker 7 px
   higher after the hold while its Leaflet transform was byte-identical — the map had *panned*. The board calls
   `invalidateSize()` after every frames change, bare, and Leaflet's bare form pans by half the difference between
   the size it last saw and the container's now; the first save after the inspector changed height therefore moved
   the camera. It takes `{ pan: false }` now, and the same measurement reads 178 → 178 across three writes.
2. **A marker is not a statement** (finding 32). The first version of the browser check asserted that the held frame
   had exactly one marker; it has three, because the board draws every placed group on every frame and only the
   inspector's `set`/`same` column distinguishes a statement from a carried-forward position. The Done-when is about
   stating, so the check reads it there.

The `invalidateSize` fix is a change to every screen this board has, so the whole board suite was re-run afterwards,
not just this step: board smoke 22, keyboard shortcuts 18, steps 2–7 **183**, all green (223 browser assertions), the
PGlite database suite 322, and `npm run build` clean.

**8. Drag several groups at once** — M, needs 4, 6
Select groups and drag them together. **Suppress the per-marker write** during a group drag and issue **one**
`frame_save` with every moved position — otherwise the first write bumps `rev` and the rest get PT409 and a reload
that discards them.
**Done when:** click path — select 3 groups, drag 30 m, reload → all 3 moved by the same delta, the rest unchanged,
no PT409 toast.

**DONE.** No new SQL: a drag is a `frame_save` whose `positions` map holds every group that moved, and finding 14's
warning is the whole of the design. The board gained a second meaning for the group ticks and one sentence in the
inspector; the save is the call step 4 already had.

**The gesture.** Ticking groups says who travels. Dragging any badge of a ticked group carries every ticked group
that stands at the open frame by the same delta, previewed live: the badge under the pointer is moved by Leaflet,
the companions by `setLatLng()` as it travels. What is written at the end is **one** `frame_save` carrying the
frame's own statements plus every moved group — not one call per badge, whose first would bump the revision and make
the rest stale (PT409), and not only the moved groups, which would delete everybody else's position on that frame
(the trap step 10 names, proved here at the database). The suppression is structural rather than a flag: only the
badge under the pointer raises `dragstart`/`dragend`, and a programmatic `setLatLng()` raises no drag event at all,
so one gesture is one `dragend` by construction.

**What it says, and what it will not do.** The inspector names the movers before anything moves — "Drag any of
Backstage, Gate Crew and Sound: they move together, by the same distance" — and the map hint names the count. A
ticked group that stands **nowhere** at this frame is not in that sentence and does not move: there is no badge to
grab, and inventing a place for it would be a different edit. Grabbing an **unticked** badge while others are ticked
still moves only that badge; the sentence names the ticked ones, so the picture and the words agree. That is the
other half of "several at once", and the last two sections of the check prove it.

Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step8-drag-together.sql` — **36 assertions** in one rolled-back transaction.
On "Copy bench", one `frame_save` with three moved positions bumps the frame's revision exactly once (1 → 2), writes
three rows that moved by exactly the same delta, leaves the other frame, its note and its revision byte-identical
(a whole-plan comparison outside the open frame), and leaves the 25 m rule with exactly one thing to say: Gate
Crew's 11 m hop to +1:00 is now 41 m. Then the bug the step exists for, played out: the same three moves issued as
three saves. The first bumps the revision to 3, the second and third are refused with PT409 and move nothing — so the
reload that follows keeps one of the three moves (rev 3, Gate Crew 60 m out, the other two where they were), which
is "three badges dragged, two edits lost". One call carrying all three, on the revision that is current, does what
the gesture meant. A payload naming one group leaves one row — the others are deleted — which is why the client
always sends the whole map. A participant (a group admin) is refused, and the doors are read from `pg_proc` and
`pg_function_privilege`.

Through the screen: `node tools/run.mjs dev/checks/step8-drag-together.mjs --session .tmp/session.json`, **49
assertions**. Copy bench opens legal, notes intact, four group rows; with nothing ticked the inspector says a drag
moves that group. Ticking three names all three, and nobody is stepped back on the map (the only group that would
have been is Security, which stands in no frame of this plan). **The map is its own ruler**: Gate Crew and Sound are
55.645 m apart in the fixture and 93 px apart on screen, so 30 m is 50 px — the check drags Gate Crew 50 px west and
all three badges move by exactly (−50, 0), with Gate Crew–Sound spacing still 93 px. That is **one** `rpc/frame_save`
in the browser's resource timing, and a toast naming all three and the distance. The plan then reports exactly one
warning — "Gate Crew: 41 m between +0:00 and +1:00 (limit 25 m)" — 11 m plus the drag, which is how the check knows
how far the drag really went. It survives a reload: the same 41 m from a fresh read, the badges in the same spacing
*ratio* (2.514 → 2.514) whatever the new fit's scale, and the +1:00 note still "one here". Then, the ticks cleared
by the reload, dragging Gate Crew another 30 m moves **only** Gate Crew — the other two badges do not move by a
pixel — and the hop grows to 71 m. Finally, with Sound and Backstage ticked and Gate Crew *not*, grabbing Gate Crew
moves it alone again (the sentence named the two ticked groups, and it does not name the grabbed one), stepping
back to a 101 m hop; the ticked pair does not move a pixel, and the unticked badge is the one drawn dim. Screenshot
`shots/step8-drag-together.png`.

**Proven to bite, twice.** With the board's one save replaced by one save per badge (each re-reading the revision,
so that all three succeed), the browser check dies at "three badges dragged is one save, not one each" — 0 → 3 round
trips. With `frame_save`'s delete turned into a merge (a partial map no longer drops the groups it leaves out), the
database check dies at "a map naming one group left 3 positions, expected 1".

**Two things this step found.**
1. **A badge is not where it will be while the map is still fitting** (finding 33). Opening a plan animates Leaflet's
   zoom for a quarter of a second, and a press aimed at a badge measured a moment earlier starts **no drag at all**:
   no save, no toast, no error, which reads as a broken feature. The check waits for `.leaflet-zoom-anim` to clear.
2. **A toast is the weakest evidence of a write** (finding 34). The confirmation is raised only after the reads that
   follow the save, so it can be missing while the write is committed — the same drag that wrote three positions once
   showed no toast for eight seconds. The check now waits on the plan's own warning distance, which the page can only
   show after re-reading the plan, and treats the toast as a bonus.

The whole board suite was re-run afterwards for this step, since the markers' drag handlers changed for every screen
that draws them: board smoke 22, keyboard shortcuts 18, steps 2–8 **232** browser assertions all green, the SQL
checks for steps 2–8 green, the PGlite database suite 322, and `npm run build` clean.

### C — the concepts

**9. A position can be off-site and can need confirming** — M
`plan_positions` gains `state` (`on_site|off_site`) and `verify` (`auto|manual`); off-site rows are ignored by
**every** check, client and server. `frame_save` reads both; `plan_frames_list` returns them.
**Done when:** round-trip returns both, and a plan whose only long jump belongs to an off-site group raises no
error from `plan_check`.

**DONE.** Migration **046** — two columns on `plan_positions` (`state` defaulting to `on_site`, `verify` to `auto`,
each behind a check constraint) and five functions re-created against them: `frame_save` reads the flags,
`plan_frames_list` returns them, `plan_check` skips off-site rows, and `plan_fork` and `frame_hold` copy them. The
client follows: `resolveTracks` carries the flags forward with the coordinates, `findGaps` measures only on-site
pairs, `snapshotAt` and `effectiveAt` keep them so a copy or a new frame says the same thing, and a drag writes them
back rather than putting a group on the map by moving it.

**A row, not a hole.** The tempting model is "an off-site group has no position at that frame", which is what this
table already means by *omitted*: "has not moved since the last frame that mentioned me". The two would be the same
row, so a group that goes off site for twenty minutes and comes back would have its departure and return silently
deleted — and step 10 could not draw either. So the row stays, keeps its coordinates, and is still returned; what
changes is that no rule that measures a walk may use it. That is what "ignored by every check" means in both
places: `plan_check`'s `where p.state = 'on_site'`, and `findGaps`'s filter, which compare a group's **last on-site
statement with its next one**.

**The consequence, stated rather than left to be discovered.** An excursion is invisible to the 25 m rule. A group
last seen on site at the gate, off site for ten minutes, then on site 400 m away is reported as one 400 m hop from
the gate: the plan does not know how they travelled, and inventing a walk is worse than saying so. Coming back
where they left raises nothing, which is the ordinary case.

**The flag is not the default.** `positions` is replaced wholesale, so an omitted flag could reasonably mean "back
to the default" — except that the drag sends a point with only a coordinate in it, and a drag must not quietly put
an off-site group back on the map. So an omitted flag means **unchanged** on an existing row (the upsert keeps what
is stored) and the defaults on a new one; sending an explicit `on_site` is how a group goes back, which is what
step 10's toggle will send. A value outside the two words comes back as a sentence naming it, from inside the
function (044's lesson about `plan_frames_t_range`), and an explicit `null` is refused rather than read as
"unchanged".

**Two copies that would have lost it, found by asking who else writes a position.** `plan_fork` copied a plan
position by position, and `frame_hold` copied one group's position to a later moment; both were written before the
flags existed, so both would have taken a careful off-site / manual pair and turned it into `on_site` / `auto` —
silently, in the two operations whose whole purpose is "the same plan, somewhere else in time". Both copy the flags
now, and a hold that finds the target row at the same coordinates but with different flags writes it instead of
reporting "already there", so a hold followed by a confirmation toggle is not two contradictory statements.

**On the screen, without pre-empting step 10.** The inspector's `set`/`same` column says **off site** for such a
row (it is still listed: that is the plan's statement that the group is not on the map), and the badge is drawn
hollow and dashed with a tooltip that says "off site", so a planner is not looking at a filled marker for somebody
who is not there. The warning row and the red band are gone, because the rule no longer has anything to say. There
is **no toggle yet**: a planner cannot make a group off site from the board, which is step 10's job — the check's
prep file sets the flag through `frame_save`.
*(Step 10 replaced the hollow badge: the Done-when there is "one fewer marker, still listed", so the map now draws
nothing for an off-site group and the track stops at it. The flag itself, and the row, are unchanged.)*

Prove it at the database: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step9-off-site.sql` — **47 assertions** in one rolled-back transaction. Twin
gap has two 200 m walks to begin with; flagging Gate Crew's arrival off site leaves exactly one break (Sound's,
still 200 m, still +0:00 → +5:00) and leaves Gate Crew's coordinates byte-identical — the Done-when, and the row is
not deleted. The list's own output is then fed straight back into `frame_save` and changes nothing but the
revision: the round trip in both directions in one move. Putting the same group back on site at the same
coordinates brings the second break back, which is what makes the pair a test of the flag rather than of the
geometry. Then the write rule (a coordinate-only point keeps `off_site`/`manual`; a new point gets the defaults),
the two words refused in sentences with nothing written and no revision bumped, the constraints for the paths that
bypass the function, **publish** (a plan whose only long jump is off site goes live; the same plan with that group
on site is refused with "more than 25 m apart"), the member's read (the flags arrive; the row is still listed), the
doors (`anon` cannot call either function, `authenticated` can), and a participant refused.

Through the screen: `node tools/run.mjs dev/checks/step9-off-site.mjs --session .tmp/session.json`, **29
assertions**, after `node tools/sql.mjs --file dev/checks/step9-off-site-prep.sql` adds "Off-site twin" — Twin gap's
coordinates to the digit, with one group's arrival flagged. The control plan reports **2** breaks, two warning rows
and two bands, and at +5:00 both rows are flagged; the off-site copy reports **1** — Sound's — with one band and no
mention of Gate Crew anywhere in the warnings. At +0:00 the same group is an ordinary badge reading "set" (the flag
belongs to the position, not to the group), and at +5:00 it is listed as "off site", not flagged, and the map draws
**one** badge — the group that is really there. A reload keeps the word, the single badge and the single warning,
because they came from the server. Screenshot `shots/step9-off-site.png`.
*(This check was re-written by step 10: the drag that proved "a coordinate-only save keeps the flag" is not a
gesture the product has any more, because an off-site group has no badge to grab. The rule is proved at the
database instead — section 4 here, and section 7 of `step10-flags.sql` — and the screen proof moved to step 10's
state toggle.)*

**Proven to bite, three times.** With `plan_check`'s `and p.state = 'on_site'` deleted from the deployed function the
SQL check dies at "the plan reports 2 breaks, expected only Sound's". With the upsert's "omitted means unchanged"
turned back into `excluded.state` it dies at "a save that named only state reset verify to auto" — before it even
reaches the state half. With the client's filter replaced by `const onSite = points` the browser check refuses to
open the off-site plan at all: the board reports two breaks where the check insists on one.

**Two things this step found, both in the harness.**
1. **A plan switch is not proven by a frame count, or by the picker** (finding 35). The first run failed waiting for
   "Twin gap", and the second showed Copy bench's strip under the picker's "Twin gap (2)": the select's value comes
   from `plan`, which changes before the frames do, and the two plans this check compares hold the same number of
   frames *and the same notes*. It now waits for something the plan itself says — the warning it earns — and lets
   the page's own "open the newest plan" land before dispatching a switch.
2. **`text()` reads rendered text** (finding 36). The badge's markup says "1 too far apart" and the assertion was
   told "1 TOO FAR APART", because `innerText` applies `text-transform`. The words are asserted through
   `textContent` now.

`plan_check`, `plan_fork` and `frame_hold` are called by six other screens and checks, so the whole suite was re-run
afterwards: board smoke 22, keyboard shortcuts 18, steps 2–9 **267** browser assertions all green, the SQL checks for
steps 2–9 green, the PGlite database suite 322, and `npm run build` clean.

**10. The board for state and verification, with bulk toggles** — M, needs 6, 9
Inspector toggles per group, plus bulk over **all**, **selected groups**, **selected frames**. Bulk must **send the
full position map** — `frame_save` deletes any position absent from the payload, so a partial write silently wipes
other groups — and uses a **batch RPC `frame_set_verify`**, because 4 frames × 6 groups as individual saves is 24
reloads and a race on `rev`.
**Done when:** click path — one group off-site and reload → one fewer marker, still listed; then select two frames,
set verify to manual in bulk, and only those groups change; a third group's position survives untouched.

**DONE.** Migration **047** adds one function, `frame_set_verify(p_plan, p_frames, p_groups, p_verify)`, and the
board gained the two flags as controls. The function is **patch-only**: it sets `verify` on the rows the named frames
already hold, counts the cells they do not state, and never creates a position — a frame that carries a group forward
has no position of its own to confirm, and inventing one would turn "same" into "set" all over the plan for an edit
that did not touch geometry. **One revision per frame that actually changed** (not per row), **nothing at all** when
every named row already reads what was asked ("twice is once", the rule `frame_hold` applies), and refusals in words
for a value outside the two words, an explicit null, an empty frame list, another plan's frame, another event's group,
a plan that does not exist, and a caller who is not root or planner.

**Off site is written here, because it is a statement about this moment.** The state toggle goes through
`frame_save` with the frame's **own** map plus the group being changed; `restatedPositions()` in `planFrames.js` is
now the only place that payload is built — the drag uses it too — so the full map is the only shape the board can
send. A group that only inherits a position **gains a row** when it is taken off site: that is the point, because
the earlier on-site sentence would otherwise keep standing. Bringing it back on site reuses the coordinates the row
already holds and leaves `verify` alone.

**One fewer marker.** Step 9 drew an off-site position as a hollow dashed badge, a placeholder until this step; the
Done-when is "one fewer marker, still listed", and that is what the board does now: `drawMarkers` skips an off-site
group (the row stays, still "off site"), the dashed track is drawn as the **runs between on-site statements** instead
of through a point nobody is at, and the map's fit ignores off-site coordinates. Under each row sit the two segmented
controls — `on site | off site` and `auto | manual` — with `off site` filled hollow-and-dashed the way the old badge
was. The confirmation chips are **disabled** on a frame that only carries the position forward (there is no row there
to flag); the state chips are not, because "off site from here" is a statement this frame can make.

**Bulk.** The Flags panel names the groups it will touch — the ticked ones, or everyone standing at the open frame,
the same rule as Hold — and splits the two writes honestly: *On the map at +5:00* acts on the open frame in one
`frame_save`; *Confirm N positions in M frames* acts on the whole selected stretch in one `frame_set_verify`, where N
counts the cells those frames actually state (a carried-forward position is the same statement as the frame that set
it, so it is not one of them). The toast reports what changed and what it could not reach.

Prove it at the database: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step10-flags.sql` — **65 assertions** in one rolled-back transaction, on a plan
the file builds itself ("Verify bench": +0:00 and +5:00 state three groups, +10:00 states only Sound) so no earlier
run can change the result. The Done-when's database half: two frames × two groups set 4 positions, both revisions move
once, the third group and the unnamed frame stay byte-identical and the plan stays legal. The identical call again is
0/0 and bumps nothing. No group list means every position those frames hold. Patch-only: a mixed grid sets 3 in 2
frames and reports 1 skipped, and the carried-forward row is not invented. A frame named with nothing left to change
keeps its revision. A group no named frame states answers 0/0/1. Seven refusals — a word outside the two, an explicit
null, no frames, an array of only nulls, another plan's frame, another event's group, a plan that does not exist —
compared against a whole-plan snapshot taken before them. The state half: off site keeps the coordinate, the row stays
listed, the rule stays silent, the list's own output round-trips, a coordinate-only save keeps both flags, back on
site keeps `manual` — then the partial payload that leaves one row, which is why the client always sends the whole
map. Publish with a manually confirmed position (verification is not a geometric gate), a member's read (own group
only, flag intact), a participant refused, the doors read from `pg_proc` and the ACL (**PUBLIC** as well as `anon`),
and a fork carrying the flags position by position.

Through the screen: `node tools/run.mjs dev/checks/step10-flags.mjs --session .tmp/session.json`, **43 assertions**,
after `node tools/sql.mjs --file dev/checks/step10-verify-prep.sql` adds "Flags bench" (same shape as the SQL check's
plan). Gate Crew off site is **one** `frame_save`, **one fewer badge**, the row still listed and the plan still legal;
a reload keeps all of it; back on site draws three badges. One confirmation is one `frame_set_verify` and no save;
the same control puts it back to `auto`. Tick two groups, select two frames: the panel says "Confirm 4 positions in 2
frames", and one call sets them all — the third group is still `auto`, and every position survived (three badges,
three rows "set"). The bulk state control with two groups ticked is one save, two badges gone, and Backstage's badge
**on the same pixel** it had, which is the full map working. At +10:00 the carried-forward groups' confirmation chips
are disabled, the panel counts one position, and the call reports the two cells it left alone. Screenshot
`shots/step10-flags.png`.

**Proven to bite, three times.** With `and p.verify is distinct from v_verify` deleted from the deployed function the
SQL check dies at "the same call again set 4 positions in 2 frames, expected 0 and 0". With the frame-belongs-to-
this-plan guard turned off it dies at "a frame from another plan was accepted". With the bulk state write sending
only the changed groups — `positions: changes` instead of `restatedPositions(frame, changes)` — the browser check dies
at "the third group is untouched: still 'set', its badge on the same pixel": the partial payload deleted the row, and
the board said so.

**Two things this step found, both in the harness.**
1. **The resource-timing buffer is 250 entries and this page loads a map** (finding 37). The first browser run failed
   waiting for a `frame_save` that had certainly been made: a plan switch's tile requests had filled the buffer, and
   `getEntriesByType('resource')` simply did not list the write. `tools/browser.mjs` now raises the buffer to 5000 on
   every new document — which also rescues the "nothing was written" assertions that could pass vacuously, and
   re-checks them.
2. **A disabled control swallows a press without a word** (finding 38). The second run clicked "By hand" while `busy`
   was still true from the previous save, and waited fifteen seconds for a request that was never sent. The check now
   waits for the control itself (`press()`), not for the board to look settled.

**And one product fix fell out of the regression, which is the point of running it** (finding 39). Step 4's
pixel-for-pixel comparison of the pasted frame broke: the plan the page opens by itself was framed **several zoom
levels further out** than the same plan opened from the picker. The steps were all in `fitMap`: it animated, the
inspector changes the map's height when a frame opens, and Leaflet finishes an animated zoom at the size it started
with — so the first fit (taken while the inspector was still empty) lost to the layout, while every later fit was
taken at full height. On top of that, `openFirstFrame` fitted in the same tick as the frames arrived, when the
inspector was briefly showing "nothing selected" — its shortest form. The board now draws the zones before the first
fit, waits a tick for the inspector to settle (in `openFirstFrame`, so every plan switch gets the same treatment),
frames once more at mount, and never animates a fit. The same plan now opens identically through either door — and
off-site coordinates are left out of the fit, which is why a plan whose only marker is somewhere else does not open
looking at nobody.

The whole board suite was re-run for this step, because the inspector's group rows and the marker treatment changed
for every screen that shows them: board smoke 22, keyboard shortcuts 18, steps 2–10 **304** browser assertions, the
SQL checks for steps 2–10 green, the PGlite database suite 322, and `npm run build` clean.

**11. Geometry rules: crossings and speed** — M, needs 9
`plan_check` tests each neighbouring on-site pair with `extensions.st_makeline`/`st_intersects` against
`no_go`/`obstacle` zones — **with `extensions` in `search_path` and qualified names (R1)** — and reports the zone
**inside `message`**, since the return type cannot gain a column (R2). Plus a speed error when the implied pace is
beyond running.
**Done when:** two positions 20 m apart whose line clips a no-go zone give exactly one error naming it, **with both
endpoints outside the zone**, and `plan_publish` refuses it.

**DONE.** `048_plan_geometry.sql` teaches `plan_check` the two things a distance cannot see, and `plan_publish` now
says *why* it refused.

- **The crossing.** Each neighbouring on-site pair — the same walk the 25 m rule measures, after 046 taught it to
  skip an off-site row — has its straight line tested against the event's `no_go` and `obstacle` zones: a geography
  line against `zones.shape`, with `extensions` in `search_path` and every call qualified (R1). The zone is named
  **inside `message`** — `... -- the straight line crosses the no-go area "Stores (no-go)"` — because the return type
  cannot gain a column without dropping the function and every caller with it (R2). The fixture already had the
  case the Done-when asks for: Security walks 20 m east through Stores between +0:00 and +1:00 with both ends
  outside, so the bench needed no new geometry.
- **The pace.** 20 m between two frames a second apart: legal distance, 20 m/s. The threshold is a constant in the
  function, `v_max_mps := 6` with a comment — a crowd walks at about 1.4, a sprint across a venue at about 6, and
  above that the plan is asking for wheels. It is not a settings row: there is nowhere to put one yet and the rule is
  not per-event. The message carries the pace (`-- 6.7 m/s is faster than running`) so the planner can see how far
  out it is.
- **One error per pair, most basic first:** over 25 m, then a crossing, then the pace. Three problems for one walk
  would make the counts in the panel and in the refusal meaningless.
- **Publishing.** `plan_publish` (038's body, with the gate rewritten) counts the errors and names the first in time
  order: `This plan cannot be published yet (2 problems). The first is: 20 m in +1:00 (from +0:00 to +1:00) -- the
  straight line crosses the no-go area "Stores (no-go)".` The old sentence — "frames more than 25 m apart" — became
  a lie the moment a 20 m walk could refuse a publish.
- **The board now says the same thing while you draw.** Step 11 first shipped with the board's red still derived from
  the client's 25 m walk, so a crossing was invisible until publish — a track drawn through a no-go zone with nothing
  on screen was the proof. The board now asks `plan_check` after every frame read (a watch on `frames`, so every write
  is followed by a fresh answer) and paints what comes back: a row naming the group and the zone (with **Show** opening
  the frame the stretch ends on), a badge in the toolbar, the same red ring on the badge at each end of the refused
  stretch, the lane row, and the segment itself drawn dashed over the track. The strip is deliberately left to the
  25 m rule: its red dot means "this moment is broken for somebody's walk", and a crossing is already named by the row,
  the badge and the segment. A row for a
  pair the local walk already reports is left to the gap row and its Fill button — matched by group and by the frame
  the walk **ends on**, because the client reports a break from the last frame it looked at (+2:00, a carried frame)
  and the database from the last frame that states the position (+1:00), and both are the same 200 m. The board still
  does not *block* the edit: the drag is written, and the plan stays unpublishable until it is moved out (step 12's
  stretch highlight, built since, is where the picture learned to explain the whole stretch).

Prove it: `node tools/sql.mjs --file dev/checks/step11-geometry.sql` — **59 assertions** in one rolled-back
transaction, on the bench plus "Geometry bench" (b12): three frames, four groups on lanes of their own, a no-go zone
and an obstacle of its own, 600 m north of every fixture plan so adding them cannot change another plan's answer.
It covers the Done-when on Walkthrough (exactly one error for the crossing, the zone named, the 20 m and the two
moments right, both endpoints proved outside the zone *and* the line proved to meet it, so a check that cannot see a
zone cannot pass); the rest of the bench unchanged (Clean walk, Copy bench and Push bench still silent, Twin gap still
only its two distance breaks); publish refusing and naming the crossing while a clean plan still publishes (the
positive control); the no-go **and** the obstacle kind; the pace rule as a pace and not a distance (the same 20 m
legal over four seconds, refused over one); one error per pair when a 30 m hop also crosses; an off-site row still
not an endpoint; the doors re-asserted with `aclexplode` rather than a regex that cannot match; and a member's
`plan_check` still seeing only their own group — and still seeing the zones it has to test against.
Through the screen: `node tools/run.mjs dev/checks/step11-geometry.mjs --session .tmp/session.json` — **29
assertions**: before Publish is pressed, the board already names the crossing (the row, the "1 problem" badge, the
ringed badge in the lane and on the map, the dashed segment, and **Show** opening +1:00); the planner is then asked
to confirm publishing, and the toast that comes back names Stores, says the straight line crosses it, counts both
problems, and does **not** claim a 25 m break; the four groups are still drawn on the map; the plan is still a draft,
still offers Publish, and a reload reads the row back the same way. The last section deletes the frame the crossing
ended on — **the one write in the check** — and waits for the crossing row to give way to the board's own two 25 m
rows, which is the proof that an edit is followed by a fresh answer and not only by a fresh load. Screenshot
`shots/step11-geometry.png`.
**Proven to bite, four times:** with the crossing test switched off, `FAIL 1a: Walkthrough reports 1 error(s),
expected 2`; with the pace threshold raised to 1000 m/s, the refusal counts 2 problems instead of 3
(`FAIL 3h`); with the old publish sentence restored, `FAIL 3b: the refusal does not say it refused`; and with the
gate itself switched off, the browser check waits twelve seconds for a refusal toast that never comes and the runner
reports the excused 400 it expected never happening.
**The rule cost four other checks an edit, which is the point of keeping them:** step 3's planner now sees 2 errors
on Walkthrough (4d), step 5's guard expects 2 before the fill and 1 after it — the crossing survives a fill that only
fixes Sound (1f), step 7's hold compares against 2 problems rather than 1 (3a), and step 9's publish-refusal
assertion follows the new sentence (6e). Step 5's own "Fill bench" also moved 600 m north: it had been standing in
the Stores zone, so its merged 100 m fill wrote a walk straight through it. When the board caught up, step 5's check
gained the row it must now see — after the fill that closes Sound's 200 m, the crossing it did not touch is still
named — which is exactly the boundary between the two badges.
**Finding 40:** `assertThat` wraps an expression in `!!(…)`, so an interpolated toast ending in `|| ''` followed by
`.includes('Stores')` is a **truthy string**, not a boolean — it passes whether or not the toast says the word. Four of
this step's five toast assertions passed vacuously for one run; the negative one ("does not claim a 25 m break") is
what exposed it, because `!text` on a non-empty string is false. A toast pasted into an expression needs its own pair
of brackets.
**The whole suite was re-run for this step**, and again after the board caught up: board smoke 22, keyboard 18,
steps 2–11 **334** browser assertions (step 5 45 — it gained the row the fill must not touch — and step 11 29), the
SQL checks for steps 2–11 green, PGlite 322, `npm run build` clean, and the ledger at 48 files, 48 applied, 0 drifted.
The badge the database's rows add carries its own class (`is-blocked`, styled with `is-bad`) on purpose: a count of
"too far apart" badges must never start counting a crossing, and the older checks' "nothing red" assertions keep
meaning the 25 m rule.

**12. The cumulative rule: highlight the whole impossible stretch** — M, needs 5
Implements the 25 m-per-step budget across frame pairs: broken neighbouring hops are the errors; expansion by
rings marks every frame in the affected stretch. **`resolveTracks` gains an ordinal `index`** (separation is frame
count, not time), rings are capped so a 300-frame plan is not O(n²) per drag, and **inheritance attribution is
fixed** — a group stated only at T+0 and +10:00 is currently reported as breaking at +9:00.
**Done when:** a 10-frame evenly spaced strip, middle frame dragged 200 m away → every frame in the stretch is
marked, the inspector names the group and the span, and publish still fails for the two neighbouring hops.

**DONE.** `resolveTracks` gives every resolved point an `index` — its ordinal among the plan's frames — because the
budget is counted in frames and neither the clock nor the track itself can supply that count. `findGaps` now walks
the **statements** (positions a frame actually holds) rather than the whole resolved track, and compares each walk
with `25 m × (to.index − from.index)`: a walk spanning nine frames may be 225 m, and the pair it reports is the two
frames that *stated* the positions, never the last frame that merely carried the group forward — so a group stated at
+0:00 and +10:00 is no longer said to break at +9:00. `annotate` marks the stretch by walking in from both ends one
ring at a time (capped at `MAX_STRETCH_RINGS` = 24 a side, so a 300-frame plan is not repainted red on every pointer
move), merges touching gaps per group into one `stretches` entry, and draws one band per stretch instead of one per
hop. The inspector gained a line under the frame heading — *This moment is inside a stretch that cannot be walked:
Gate Crew, +1:00 → +1:30* — because a red dot on its own never says why it is red, and the warning row now reads
`(limit 50 m, 2 steps)` when the walk spans more than one step while keeping `(limit 25 m)` when it does not.

The gate had to follow, or the board would have been more forgiving than Publish. `049_plan_cumulative.sql` replaces
`plan_check` with the same arithmetic: a CTE numbers the plan's frames by time and the loop budgets
`25 × (index difference)`, and the sentence names the steps and the budget — *"200 m in +2:00 (from +1:00 to +3:00)
-- 2 steps, so the limit is 50 m"*. One step still says "the limit is 25 m", which is what every older check reads.
`plan_publish` needed nothing: it already refuses whatever `plan_check` calls an error. **Finding 24 is closed** —
the board and the gate name the same pair, so `PlanBoard`'s dedupe is an exact `(group, from, to)` again — and the
two halves of the cumulative rule finally sit in the same place.

Prove it: `node tools/sql.mjs --file dev/checks/step12-cumulative.sql` — **30 assertions** in one rolled-back
transaction. On the bench, Sound's 200 m is reported from +1:00 to +3:00 (not from the carried +2:00) with "2 steps"
and "the limit is 50 m", while Security's crossing is not also a distance. On "Step bench" (b13), a ten-frame strip
whose group is stated only at the ends: 220 m across nine steps is legal, 230 m is not (*"9 steps, so the limit is
225 m"*), and 220 m again is legal. On "Ticks bench" (b14) the same 200 m in the same 100 s is refused with two
frames and accepted with eleven — distance and clock unchanged, only the number of slots — and shrinking the clock to
one second still reports the **pace**, not the distance. Then publish says the same thing: the legal strip publishes
(the positive control), the 230 m one is refused in a sentence naming 230 m, nine steps and 225 m, and the bench's
walkthrough keeps Stores first. The doors and a member's scope are re-asserted because the function was re-created.
Through the screen: `node tools/sql.mjs --file dev/checks/step12-stretch-prep.sql` then
`node tools/run.mjs dev/checks/step12-stretch.mjs --session .tmp/session.json` — **36 assertions**. "Stretch bench"
is the Done-when's strip: ten frames 15 s apart, Gate Crew standing still, Sound 100 m east (the map's own ruler, and
the group whose lane must stay clean). The badge on +1:15 is dragged 200 m east — one gesture, one `frame_save` — and
then: two rows, one per neighbouring hop, each `(limit 25 m)`; "2 too far apart"; exactly three red dots on
+1:00/+1:15/+1:30; one band across exactly those three; the inspector naming Gate Crew and +1:00 → +1:30; one red
lane row and one ringed badge, both Gate Crew's; both hops drawn as their own red segments; and no database row,
because the walk is only too long. Publish is then pressed and refused with "2 problems" and "the limit is 25 m", and
after a reload the same three dots and the same rows are there. Screenshot `shots/step12-stretch.png`.
**Found by looking at that picture:** with the bar zoomed in far enough to click a 15 s gap, the axis labelled two
consecutive ticks "+1m" — the short form rounds to the minute, so 30 s and 60 s both read as one — and the ruler
looked broken. A tick now carries its seconds whenever the bar's step is under a minute (+0:30, +1:00, +1:30), which
is the only thing about this step that was not in the plan.
**Proven to bite:** with the stretches no longer merged, `FAIL the stretch is one band, not two overlapping ones`;
with 048's body put back, `FAIL 0a: plan_check is not the 049 body`. One honest limit: cutting the marks back to the
endpoints of each gap still **passes** this check, and that is worth recording — for two adjacent one-step hops the
endpoints *are* the three frames of the stretch. The ring expansion is therefore proved by step 5's third dot (a
two-step walk marks +1:00, +2:00 and +3:00 where its endpoints are two), and the merge is the half proved here.
**The rule moved two other checks, which is the point of keeping them:** step 5's row is now +1:00 → +3:00 with
`(limit 50 m, 2 steps)` and its strip marks three dots rather than two — 45 → **47** assertions, and because its fill
now starts at the stated frame the frames it opens are found from the fill's own arithmetic instead of being assumed
— and step 11's SQL check reads the new sentence (1m). Step 3's and step 9's counts were unaffected because their
walks are one step.
**The whole suite was re-run:** board smoke 22, keyboard 18, steps 2–12 **372** browser assertions (steps 2–11 are
now 336, because step 5 went from 45 to 47; step 11 is still 29 and step 12 is 36), the SQL checks for steps 2–12
green, PGlite 322, `npm run build` clean, and the ledger at 49 files, 49 applied, 0 drifted.

**13. Undo and redo, and delete from the keyboard** — M, needs 5–12
Inverse-command stack over marker drag, group drag, frame drag, delete, paste and create, on **Ctrl+Z**, with a
**redo stack on Ctrl+Y and Ctrl+Shift+Z** — any new edit clears redo, and an undo that is itself undone must not
push twice. Every inverse re-reads the frame's `rev`; delete restores **with its original id** (step 4's
client-supplied id); both stacks are cleared at any publish boundary, so redo cannot resurrect a pre-publish edit
into a published plan. Ctrl+Z is the one shortcut step 4 did not add, on purpose: a key that silently did nothing
would be worse than no key.
**Done when:** click path — drag 40 m, Ctrl+Z, reload → original coordinates; Ctrl+Y puts the 40 m back; after a
publish, Ctrl+Z and Ctrl+Y both do nothing.

**Done.** `src/composables/usePlanUndo.js` is the whole feature: the two stacks, their storage, and one `apply()` that
knows how to write every kind of command in either direction. **A command is data, not a closure** — `{ kind, label,
… }` holding ids and values — and it holds **no revision**, so an inverse re-reads the frame's rev from the plan on
screen when it runs and PT409 still means "somebody got there first". Because it is data the stack survives a reload
**inside the tab** (sessionStorage, one key per plan), which is what makes the Done-when literal rather than
approximate: drag, Ctrl+Z, *reload*, Ctrl+Y.

Eleven kinds are on the stack: a badge moved (one group, or several moved together), a frame's time, a frame's note,
off site / back on site, a confirmation, a pushed stretch, a hold, a fill, a frame created or pasted, a frame deleted,
and the plan's name. The list is longer than the step asked for on purpose: a kind the stack could not invert would
let Ctrl+Z quietly undo the edit *before* it, which is worse than refusing. The board records one command per
successful write and nothing else — a selection, a tick and a zoom change the screen, not the plan. Undo/redo move a
command between the stacks and touch nothing else (so an undo that is itself undone cannot push twice), a new edit
drops the redo stack, and both stacks are cleared by a publish, by deleting the plan, and per plan — a command names
ids, so it is only ever safe against the plan it came from. `onKeydown` owns Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z whatever
the stack holds (a key the board owns must not reach the browser), ignores them while a write is in flight, and
**Delete** removes the open frame after the same question the Delete button asks — or says why a stretch is not one
frame. The toolbar gained **Undo** and **Redo**, disabled when their stack is empty, and the frame dots carry
`data-frame-id` so a check can say "the same frame came back" rather than "a frame came back".

Prove it: `node tools/sql.mjs --file dev/checks/step13-undo.sql` — **one transaction, rolled back**, five sections, the
inverse of each write at the database: (1) a shift named by its two times comes back by its two times (0/30/90/180 →
0/60/120/180); (2) and when the pushed range holds three frames having moved two — 044 lets a chunk pass a frame that
stays put, so the frame at +3:00 sits *inside* 150..210 — the two go home **by id** and the frame that never moved
does not; (3) a frame's whole position map is its own inverse, flags included, and the inverse leaves exactly the rows
it found; (4) a delete is undone by creating the frame again **with its id**, note and positions, and the restore is
**refused** when another frame has taken that moment; (5) an inverse is a write like any other, so a command carrying
the rev from before somebody else's edit is refused (PT409) and the same call with the current rev lands.
Through the screen: `node tools/sql.mjs --file dev/checks/step13-undo-prep.sql` then
`node tools/run.mjs dev/checks/step13-undo.mjs --session .tmp/session.json` — **70 assertions**, and the keys are
**real presses**: a trusted Ctrl+Z through the DevTools input pipeline arrives and does not hang this browser (unlike
Ctrl+C, which reaches for the OS clipboard and wedges it — step 4's debt), so this step proves the platform's delivery
as well as the handler. "Undo bench" is four frames a minute apart with Gate Crew standing still and Sound 100 m east
as the map's own ruler, so the drag is 33 px for 40 m. Drag 40 m: two rows, three red dots, one save. Ctrl+Z: the
rows and dots go, the badge is back within two pixels, the stack has turned round — and after a **reload** the plan is
legal again, the same four frames are there by id, the redo stack is still there, and the board is framed the same way
(so the pixels mean the same thing). Ctrl+Y: the 40 m and both rows return; Ctrl+Shift+Z does the same from the other
side. Then the push: +1:00 and +2:00 dragged +1:30 land at +2:30 and +3:30 with the +3:00 frame inside their range,
and one Ctrl+Z puts *every* frame back at its own time — the case the two-times inverse would get wrong. Then Delete
on +1:00 → confirm → three frames; Ctrl+Z restores **the same id**, the note "doors", Gate Crew stated and Sound still
carried, and opens the frame it brought back. Add frame at +4:00 → Ctrl+Z → Ctrl+Y re-creates **the same id** (a
lookalike would be a different frame to everything that points at it). Finally Publish: it succeeds, both stacks are
cleared, Ctrl+Z says "Nothing to undo." and Ctrl+Y "Nothing to redo.", **no write is made** (counted by request), and
the badge has not moved. Screenshot `shots/step13-undo.png`.
**Proven to bite:** with the range inverse made unconditional (no id fallback), `FAIL every frame is back at its own
time, the one that never moved included` — the frame that stayed at +3:00 ends up at +1:30, which is exactly the
mistake the guard exists to prevent; with the undo made to push onto the undo stack as well as the redo stack,
`FAIL and the stack has turned round: nothing left to undo, one thing to redo`.
**Found while doing it:** a trusted Ctrl+Z does *not* wedge the headless browser, which is worth recording because
step 4 had to fake Ctrl+C; the board's height is decided by the inspector's content, so a badge's *y* is only
comparable between two states with the same number of warning rows (the check compares x across the reload and y only
where the rows match, which is the same debt step 10 recorded); a dot's title is `Frame +1:00 — doors` when the frame
has a note, so "which moment is this dot" is the title cut at the em dash — the first version compared whole titles and
failed on a frame that was right; and a group stated at +0:00 and carried into +1:00 reads **same**, not **set**, which
the delete-undo assertion had wrong. The one honest limit: the stack is per tab and per plan, so undo does not cross a
tab, and a command left over from a reload runs against whatever the plan is now (every inverse re-reads the rev, so
the worst case is a refusal, not a silent overwrite).
**The whole suite was re-run:** board smoke 22, keyboard 18, steps 2–13 **442** browser assertions (steps 2–12 were
372; step 13 adds 70), the SQL checks for steps 2–13 green, PGlite 322, `npm run build` clean, ledger unchanged at
49 files (this step adds no migration).

### D — the clock, the truth, everyone else

**14. Actuals** — M, needs 2
`plan_progress(session, plan, frame, group, state, at, by)` — **RLS + read policy (R3)**, writes via
`progress_mark()` only, `frame_id` **`on delete cascade`**; `session_status()` returns planned time, state,
lateness. Lateness is computed from `t0_at`, not `starts_at`.
**Done when:** one arrived and one missed return correctly, future frames report no lateness, and **the fixture has
`t0_at ≠ starts_at`** so the two implementations can actually be told apart.

**Done.** `supabase/migrations/050_plan_actuals.sql` adds `public.plan_progress` — one row per group per frame per
session: `state` ('arrived' or 'missed'), `marked_at` and `marked_by` — and two functions. **`progress_mark()`** is
the only writer: it checks membership, then the role (the event's ops, or **the group's own IC or admin**), then
that the frame is in this session's plan, that the group stands in the plan at that moment, that it is not off
site there, and that the instant it is being recorded *for* has happened and is after T+0. Saying it twice **corrects**
one row rather than adding a second opinion — **narrowed in step 28** (064): a person's mark may be replaced by the
person who made it or by the event's ops and by nobody else, while an automatic close may be replaced by any hand.
**Half of the "has happened" sentence was not true until then**: the `p_at` is checked against `now()`, but the
*frame's* planned time never was, so a frame in the future could be recorded with `p_at` defaulting to now and read as
an early arrival (finding 113, still open). **`session_status(p_session, p_at default now())`** returns one row per group
per frame with `planned_at`, `state`, `lateness`, `marked_at` and `marked_by`, walking the plan's carry-forward (a
group's state at a frame comes from its last statement at or before it, exactly as the board draws it). It takes
the clock as a parameter so a screen can ask "how did this look at 18:20" and so the check can stand at a chosen
second.

Five states, and the vocabulary is the point: **pending** (not yet due), **late** (due, nobody has said
anything — lateness grows with the clock), **arrived** and **missed** (somebody said so, lateness is when they
said it minus the plan), and **not_required** (the group is off site at that moment). A frame nobody has marked is
**late, not missed**: a timetable that declares a group missed at the exact planned second would cry wolf all
night, and "missed" is a decision. **Lateness is measured from `t0_at`** — `planned_at = t0_at + t_s` — never from
`starts_at`; the check keeps the two 50 minutes apart and asserts that the wrong formula answers **−2910 s** where
the right one answers **+90 s**. A recorded outcome wins over the position flags, so editing the forecast after the
night cannot erase what was seen. Deleting a frame deletes what was recorded at it (R3's read policy is
`is_event_member`; the table is revoked from `anon`, `authenticated` and `public` and granted back **SELECT only**,
with no write policy at all); an ended session can still be marked, because paperwork happens late.

Prove it: `node tools/sql.mjs --file dev/checks/step14-actuals.sql` — **one transaction, rolled back**, eight
sections. It builds its own plan and starts a real session through `start_event`, so the clock pair is the one the
product produces: "Actuals bench" has five frames (0, 60, 120, 180, 3600 s), Gate Crew on site throughout, Sound
stated off site at +3:00 (so +3:00 reads `not_required` and marking it is refused), and Backstage first stated at
+3:00 (so it has no row before then — no phantom "late"). The event's `starts_at` is exactly 50 minutes after its
`t0_at`, asserted. Before anything is recorded: +0:00 is `late 200 s`, +1:00:00 is `pending` with **null lateness**,
and the timetable has its 12 cells. Then one **arrived** (Gate Crew's IC, 90 s after the frame) and one **missed**
(the planner, 90 s after its frame) come back with their exact state, lateness, `marked_at` and `marked_by`; Sound's
admin records her own group and the planner corrects it (still three rows); the wrong-clock arithmetic is
−2910 s against 90 s. Then the sentences: off site, not in the plan yet, a moment in the future, one before T+0,
"maybe", a frame from another plan, a frame that does not exist, a group that does not exist, a group admin
reaching another group, an outsider, a session with no plan. Then who may read: a planner and an IC see all three
rows, an outsider sees none, a `select` from `anon` and a **direct insert even as root** are both refused. Then the
cascade: `frame_delete` takes the missed frame and its row with it, and the timetable drops to 10 cells. Then the
event is ended and a late reconciliation still records — and reads back.

**Proven to bite:** with `session_status` moved onto `starts_at`, the check stops at 2b with the first frame
planned 50 minutes after the session's own `t0_at` (the wrong clock, printed as a timestamp the run cannot fake);
with the off-site branch removed, `FAIL 2i: an off-site frame reads "late", expected not_required`; with `frame_id`
changed to `on delete restrict`, the frame delete is refused (`23503 … still referenced from table
"plan_progress"`), which is the cascade the step names.

**Found while doing it:** the plan's sketch calls the columns `at` and `by`, and **both are keywords PostgreSQL
cannot read off a PL/pgSQL record** — `r.by` answers "record r has no field by", and quoting it (`r."by"`) answers
the same, so they are `marked_at` / `marked_by` from the start, documented in the migration. A missed mark's
lateness is measured from **its frame's** planned time, not from T+0: marked 150 s after T+0 for the +1:00 frame,
it reads 90 s, and the first version of the check expected 150. `create table if not exists` made a column rename
under a re-applied migration a no-op; the table (and the two functions that depend on its row type) had to be
dropped before 050 could be re-applied, which is worth remembering for every later change to a Done step. And a
member can read **every** group's outcomes, not only their own — the read policy is `is_event_member`, the same
shape as the frames and positions (step 3's finding 23); step 16 is where the member read path narrows.

**The suite was re-run:** board smoke 22, keyboard 18, steps 2–13 **442** browser assertions (unchanged — this step
has no screen), the SQL checks for steps 2–14 green, PGlite 322, `npm run build` clean, ledger **50 files, 50
applied, 0 pending, 0 drifted**.

**15. One read carrying times, state and a revision** — M, needs 14
`session_timetable(p_session)`: one row per group per frame with `planned_at`, state, lateness and `plan_rev`.
`t0_at` **wins** over `plans.for_date`/`t0_time`, which stay display hints.
**Done when:** publishing while another tab holds the old payload makes that tab's fresh `plan_rev` differ **and
the browser runner asserts the staleness text** — a bumped column the client ignores does not pass.

**DONE.** `051_session_timetable.sql` adds `session_timetable(p_session, p_at default now())`: one call answers
with the group's name, the plan's clock time for the frame, the five-state word and its lateness, and the revision
the session follows. It is a **read over 050's engine, not a second copy of it** — `session_status` still owns the
carry-forward and the pending/late/arrived/missed/not_required rule, so there is one place for that sentence to
live; this file adds the two things a screen needs (the name and the revision) and the member scope. `planned_at`
is `event_sessions.t0_at + t_s`; the plan's printed date and time stay display hints. The scope is 040's rule from
its first call — ops staff read every group, an IC or group admin their own, a member with no group nothing — and
R4's grants are on the new function.

The revision needed a fix of its own. 039 gave the session `plan_rev` and stated that publishing moves it; in
fact `plan_publish` only bumped `plans.rev`, so a running session kept the revision it started on for ever and the
staleness the column existed for could never fire (finding 40). 051 re-creates `plan_publish` from **048's** body
(R8) and writes the new revision onto the open session in the same transaction, so a fresh read answers a different
number than a tab that read before the publish, and no reader can see the plan at 4 and the session still at 3.
Ended sessions keep the revision they ran — a closed show is history, not a screen — and a one-time backfill makes
sessions that started before this file tell the truth.

The screen is a strip on the plan board (`PlanLive.vue`, `pv-run-*`). While the page shows the plan the live
session runs, it says **"Live · plan version 3 · T+0 18:45"** and holds the revision it read. When a fresh read
answers a newer one it says so in words — *"This plan was published again while this page was open (version 2 → 3).
What is on screen is version 2."* — with a button that re-reads the plan and its frames and adopts the new revision.
What makes it look again is the **`event_sessions` subscription**: 051's publish moves the session's `plan_rev`, so
another tab's publish arrives as a push; a 30 s poll and a focus check cover the tab that is awake but unpushed.
Publishing a plan that is already live now offers **"Publish again"**, because republishing is how a change made
ahead of the clock is announced (steps 17–19 refine that into forks, compare-and-set and a real plans channel).

Prove it: `node tools/sql.mjs --file supabase/fixtures/plan_bench.sql` then
`node tools/sql.mjs --file dev/checks/step15-timetable.sql` — eight sections in one rolled-back transaction that
builds a "Timetable bench" and starts a real session on it with T+0 ten minutes ago. The row shape, the clock, the
name and the revision on every row; **t0_at wins**, proved by moving the plan's printed T+0 ten minutes forward
*under the running session* while the read does not follow and `plan_t0()` now answers a different number;
publishing moves the revision the session follows; the read carries a recorded arrival (state, lateness, when, by
whom); the member scope (planner 6 rows, Gate Crew's IC 3, Sound's admin 3, a member with no group 0, an outsider
refused, `anon` cannot execute); the inherited refusals (a session with no plan, a session that does not exist); an
edit is not an announcement (a moved frame changes the rows and their `planned_at` but not `plan_rev`); and an
ended session still reads, at the revision it ran. **Proven to bite:** with `session_timetable` built on the plan's
printed clock, `FAIL 2b` (the read is ten minutes late on every row); with 048's `plan_publish` back, `FAIL 3b: the
running session follows revision 2, expected 3`; with the member scope removed, `FAIL 5b: a Gate Crew IC reads 6
rows, expected 3`.

Through the screen: `node tools/run.mjs dev/checks/step15-staleness.mjs --session .tmp/session.json`, 24 assertions
and **two tabs** (25 before step 19 retired the frame-count assertion that no longer holds; see step 19's record). Tab
A opens "Clean walk" (published, started on the plan) and holds version 2 of four frames. Tab
B, the same planner, adds a frame and presses **Publish again**. Tab A is not touched and was not reloaded: the
stale sentence appears with both numbers and the chip still names version 2 (what the board *draws* is not asserted:
since step 19 the added frame may already have reached it, and a publish is the moment the board stops adopting
content),
and tab A has made a **second `session_timetable` request** — counted from the browser's resource timings, which is
what "the tab asked again" means when a sentence alone cannot say so. Pressing "Show version 3" reloads the plan:
five frames, version 3, warning gone. A second republish is noticed again, from the revision the tab had caught up
to. The check puts the bench back (frame deleted, four-frame shape published again, event ended), and refuses to
start unless "Clean walk" is the fixture's four frames. **Proven to bite:** with the strip adopting every fresh
revision instead of comparing, the browser check fails waiting for the stale sentence — the bumped column *is*
ignored, and the runner says so rather than passing. Screenshot `shots/step15-stale.png`.

**Found while doing it:** the revision fix (finding 40) was not a nicety — without it the done-when cannot be
satisfied at all. The strip's text was **white on cream** until a screenshot caught it, because `native.css` already
owns `.pv-live` for the phone shell's events card (finding 41); planova.css's own header warned about `.pv-head` and
the same prefix trap caught the next name. Two assertions in the SQL check could not fail: a record variable that
no query filled is NULL and `IF NULL` is false (finding 42), so "the other group is still late" now proves the row
exists first. And the trigger for the fresh read is a subscription, not a timer, because the tab doing the noticing
is in the background where timers are throttled (finding 43) — the check counts the request instead of trusting the
sentence. The strip also caught its own inconsistency: the chip named the fresh revision beside a sentence saying
the older one was on screen (finding 44). And one harness fix came out of running the whole suite: the first click
of `shortcuts.mjs` landed at coordinates measured before the layout settled, two runs in five (finding 45);
`Tab.click` now asks the page what is under the point and measures again before pressing.

**The suite was re-run:** board smoke 22, keyboard 18, steps 2–13 **442** (unchanged), step 15 **25** (two tabs),
the SQL checks for steps 2–15 green, PGlite 322, `npm run build` clean, ledger **51 files, 51 applied, 0 pending,
0 drifted**.

**16. My schedule** — M, needs 15
Read-only per-group timetable for member / IC / marshal, clock times, arrived/missed; off-site frames read as "not
required"; replaces the board for those roles.
**Done when:** as a member, only their group appears — asserted **in the browser** and **at the database** (step 3
made the second half possible).

**DONE.** The member's Timeline tab is their schedule now, and the board stopped being a screen a follower reads.
`PlanSchedule.vue` renders one moment per frame on the plan's clock: the clock time, the planner's note, and the
five-state word with its detail (a countdown while it is due, how late the clock is while it is late, when an
arrival or a decision was recorded). The header names the plan, the revision the session follows, their group, and a
clock that ticks; the next moment is marked. Off-site moments read **not required** and say there is nothing to
arrive at.

**052 makes "their own timetable" the only read they have.** Until now a member could read, straight from the
database, another plan's frames and notes (finding 23) and another group's outcomes (step 14's debt). 052 closes
that surface: `plans` answers a member with the live one only, `plan_frames` with nothing, `plan_progress` with
their own group's rows, and `session_status` (the engine) now applies 040's scope itself, so the timetable is not
the only scoped door — a client that called the engine directly used to get every group's rows. **`plan_positions`
is deliberately left as 040 wrote it**: a group's own coordinates without their times are not a timetable, and step
3's check asserts that rule. `anon` also loses the tables (finding 1's default ACL was still on `plans`,
`plan_frames` and `plan_positions`; 050 had revoked it only for `plan_progress`).

**The read got the two names it needed.** `session_timetable` now returns `plan_name` and the frame's `note`, so the
header and the labels come back with the times instead of needing a second read (R2: the return type changed, so
DROP + CREATE + re-GRANT). `usePlan.readTimetable` gained the `p_at` argument the screen uses for a closed event.

**Who sees which screen.** Root and planner keep the board; a member, an IC, a group admin and a **marshal** get the
schedule — the ops read is unscoped, so a marshal sees every group's timetable (proved). `EventView` chooses between
them, the tab is labelled *Schedule* for those roles, and the address stays `/timeline`, so the page keeps one name in
the URL. The styles are `pv-sched-*`, checked against `native.css` before they were used: that file already owns
`.pv-row`, `.pv-live`, `.pv-head` and `.pv-title`, which is the trap that made step 15's strip white on cream
(finding 41). `PlanLive`'s strip now carries the instant its T+0 is as `data-t0` (the schedule's clock already did),
so a check can name the second a moment is due instead of parsing a minute.

**The clock is the database's; the wake-up is the screen's.** The states are 050's answer at the instant the read
asks, so the screen never decides "late" from a timestamp. What it decides is when to ask again: at each planned
moment as the clock reaches it, on the `event_sessions` push (a republish), when the tab is looked at, and every
30 s as a floor. Between reads the countdowns are arithmetic on the same `planned_at`. A closed event is read at
its end time, so its timetable says how the night closed instead of turning late all night — and the header says so
and stops the clock.

**The done-when, at the database.** `node tools/sql.mjs --file dev/checks/step16-schedule.sql` builds its own
"Schedule bench" (five frames, T+0 fifteen minutes ago, both groups, four recorded outcomes) and rolls it back. As a
Sound member: five rows, one group, and every state word exactly once — `arrived, not_required, late, missed,
pending` — with `planned_at = t0_at + t_s`, the marks and their recorders, and the notes on the frames. Then the
closed paths, table and function both: frames 0, `plan_frames_list` 0 (the draft's too), `plans` exactly the live
one, positions and outcomes their own group's only, and `session_status` called straight answering five rows instead
of ten. A marshal sees all ten rows, every frame (draft included), eight positions and four outcomes. The other
group's IC sees their own five through all four doors. A member with no group reads nothing but still sees the live
plan. An outsider is refused the read and sees no rows; `anon` cannot execute either function or read any of the
four tables. **Proven to bite:** with `plan_frames_read` back to `is_event_member`, `FAIL 4a: a member reads 24 plan
frames, expected none`; with 050's unscoped engine back, `FAIL 1a: a Sound member reads 10 rows, expected 5` (the
timetable inherits the engine's scope, which is why the rule moved there); with `plans_read`'s membership clause
dropped, `FAIL 8b: an outsider reads 1 plans`; with `plan_progress_read` back to membership, `FAIL 4i: a member
reads 4 outcomes, expected their own 2`.

**The done-when, through the screen.** `dev/checks/step16-schedule-prep.sql` builds the screen's own bench (an event
whose T+0 is fifteen minutes old, so the clock — not the fixture — decides the words), then
`node tools/run.mjs dev/checks/step16-schedule.mjs --session .tmp/session.json` runs **69 assertions over five
tabs**. The planner's page is still the board (five frames, picker, revision on the strip) and it moves the last
moment half a minute ahead and republishes. The member's tab — called *Schedule* — shows the timetable and nothing
of the board: no strip, picker, map, Add frame, Publish, Copy or Undo, and its resource timings contain **no request
for the plan, its frames or its positions at all**; only the timetable. Their five rows are Sound's five, in clock
order, each printing a clock time, the first equal to the header's T+0; the notes are the planner's labels; each
word's detail says what it means. The moved moment reads "due, in 30 s" and then, untouched and with **no reload**,
turns "late" a moment later — with a second `session_timetable` read counted. A marshal opens the same page as
*Timetable* with both groups (10 rows) and the other group's record. And when the planner ends the event, the
member's page still reads it: phase *ended*, the clock stopped at the close, nothing left "due". **Proven to
bite:** with the board rendered for every role, the check fails waiting for the schedule; with the wake removed
*and* the poll pushed to ten minutes, it fails waiting for "late" — while the same check with only the poll pushed
out **passes** (69 assertions), which is what proves the wake, not the poll, is what turns the word.

**Found while doing it:** five findings. A browser profile is one person: the newest tab's seeded session is the one
every tab picks up, so the member's page started drawing the planner's board when the planner's tab opened (46). The
migration ledger said 037 was applied while the `activities` table it created is not in the database — nothing had
noticed, and 052's first version aborted on a policy for it (47). A scope in a wrapper is not a scope; the engine
had to be scoped, and the bite proves the timetable inherits it (48). And an assertion that borrowed another
policy's effect goes vacuous when that policy changes: step 3's check proved RLS *inside* `plan_check`, three more
files asserted a member's read through `plan_frames_list` or `plan_check`, and one counted the fixture's positions
without excluding a plan its own prep adds — all five were re-pointed at what they are about (49). `assertContains`
also reads `innerText`, so the phase chip's CSS uppercase made it "LIVE" (50) — the same trap step 3 recorded.

**The suite was re-run:** board smoke 22, keyboard 18, step 2 11, steps 4–13 **408** (their counts unchanged), step
15 **25** (two tabs), step 16 **69** (five tabs); step 3's browser file is retired (its member assertion is step
16's), and the SQL checks for steps 2–16 are green on a bare bench — step 9's own prep belongs to its browser check,
not to its database check. PGlite 322, `npm run build` clean, ledger **52 files, 52 applied, 0 pending, 0 drifted**.

**17. Fork without teleporting anyone** — M, needs 2, 15
`plan_frames.origin_frame_id` copied by `plan_fork` — **set in a second UPDATE pass, because the new ids do not
exist during the INSERT**; forking anchors each group at its interpolated position; frames at or before the current
offset are refused inside the fork.
**Done when:** fork mid-walk and republish → the position at the cut is unchanged; editing before the cut is
refused.

**DONE.** `053_fork_cut.sql` makes "edit the future of a running plan" a real operation. A plan copied from a
**running** plan remembers the instant it was taken — `plans.fork_cut_s`, the offset the session's clock had
reached — and the copy then contains exactly three things: one **anchor frame at the cut** holding every group's
position *as the walk has it at that instant*; every **later frame**, unchanged, each naming the frame it came from
in `plan_frames.origin_frame_id`; and **nothing at or before the cut**. The past stays on the plan it happened on,
which remains readable. A plan copied when nothing is running has no cut and is the same deep copy it always was,
and a copy taken at T+0 has no past yet either, so it also has no cut.

The anchor is the step's heart, and it is `plan_position_at(p_plan, p_group, p_t_s)` — one statement of the walk's
arithmetic, interpolating between the two statements that bracket the instant when both are on site, carrying the
last statement forward when the group is standing still or off site (046's rule: an off-site row is not a place to
interpolate from *or* into), and returning nothing for a group that has not appeared yet. `plan_fork` calls it for
every group with a statement at or before the cut, and the check proves the numbers against arithmetic, not against
the function.

**Finding 8 is honoured**: `origin_frame_id` cannot be set in the INSERT that copies the frames (the new ids do not
exist while it runs), so a second UPDATE pairs the two plans by their unique times. The anchor is not a copy of
anything and keeps a null origin.

**The past is frozen by a trigger, not by six functions.** `frame_save`, `frame_move`, `frame_delete`,
`frame_shift`, `frames_fill` and `frame_hold` can all land a frame at or before the cut, and `plan_positions` can be
written straight to the table by anyone the RLS write policy admits; one BEFORE trigger on each of the two tables is
one statement of the rule (six copies is six chances to miss one, R8 read the other way round). A frame at or
below the cut cannot be created, moved across, deleted, or carried to another plan, and its positions cannot change;
its **note** can, because a label on the start is not a statement about where anybody was. A plan being deleted
still works: by the time the foreign keys cascade, the plan row is gone and there is no cut to protect. And the cut
itself is set once and never cleared or moved (`plans_guard_fork_cut`), so "the past cannot be edited" is not one
UPDATE away from being false.

**Publishing the copy is the hand-over.** `plan_publish` (051's body, R8) moves the open session running the copy's
original onto the copy in the same transaction — `plan_id`, the new revision, and **not the clock** (the copy
inherited the T+0, and a session's `t0_at` is the clock people were told). In the same loop it records the anchor as
**arrived at the cut** for every group it anchors, through `progress_mark` (the only writer, as step 14 built it).
Without that last part the copy's first row would read "late" the instant it was published, which is a false alarm:
the group is not late, it is where the plan already had it. An off-site group gets no mark and reads "not required";
a republish carries nobody a second time and rewrites no record. The past outcomes recorded against the original's
frames stay attached to them — the copy has no past, and the timetable has no row for one.

On the board (`PlanBoard`, `planova.css`) the copy's first dot carries a ring and `data-cut`, its time field is
disabled (its start cannot move) while its note stays writable, and the inspector says *"This copy starts here, at
+1:38. Everyone is anchored where the walk already had them; the moments before this one stay on the plan it was
copied from."* The copy toast names the cut instead of the old "the original is untouched".

**The done-when, at the database.** `node tools/sql.mjs --file dev/checks/step17-fork.sql` — ten sections in one
rolled-back transaction, on the bench, with a seven-minute-old session started through `start_event`. A plan nobody
is running forks whole (two frames, three positions, the off-site / manual pair, every origin link). The running
plan forks with `fork_cut_s` at the session's offset (~420 s, between the statements at +5:00 and +10:00), four
frames (the anchor and the three after it), one frame at or before the cut, the original untouched with its five
frames and twelve positions; the anchor is **strictly between** the two dots and exactly the fraction of the way the
clock says (`1.33030394` at the cut), Sound's off-site anchor is where it was last seen with its manual flag, and
Backstage — which appears at +15:00 — has no anchor at all. `plan_position_at` answers the same numbers on both
plans, and its read rule is 040's. Every door that could write a frame before the cut raises a sentence naming it
(`frame_save`, `frame_move`, `frame_delete`, `frame_shift`, a direct frame insert, a direct position update, clearing
the cut), while a frame after the cut is still ordinary. Publishing carries the session onto the copy: same
`t0_at`, new revision, the anchor *arrived* with zero lateness and the publisher's name, the off-site group
*not_required*, and exactly one mark — only one of the two groups is on site at the cut. Then the done-when as
numbers: the copy's position at the cut equals the original's to 1e-12, before and after the switch, and the
timetable has no row planned before the cut. **Amended in step 28:** the hand-over records the anchor in the
**publisher's** name through `progress_mark`, so the group's IC can no longer replace it (064's guard; step 17's §8 now
proves the refusal and then has the event's root correct it). A second publish leaves the record as the last person
entitled to make it left it. **Proven to bite:**
with the cut never taken, `FAIL 2a: a plan copied mid-walk has no cut`; with the anchor carried forward instead of
interpolated, `FAIL 3c: Gate Crew's anchor is at 1.3302171, expected 1.33030394 (the walk at 420)`; with the
hand-over not recorded, `FAIL 6g: the anchor reads "pending" on the timetable, expected arrived` (the check's
transaction has a frozen `now()`, exactly at the cut's second; through the browser, where time moves, the same row
reads "late"); with the cut triggers dropped, `FAIL 5a: a frame was written before the cut`; with the session not
moved, `FAIL 6c: the session did not move onto the copy`.

**The done-when, through the screen.** `dev/checks/step17-fork-prep.sql` builds an event whose clock is ninety
seconds into the walk, then `node tools/run.mjs dev/checks/step17-fork.mjs --session .tmp/session.json` runs **44
assertions over three tabs**. The Sound member's tab is opened **first** and closed: before there is a copy, their
schedule is the whole plan — five moments from T+0, the call late because it passed unmarked. The planner's tab is
the board with the live strip at revision 1; **Copy plan** makes a draft whose first dot is the cut, with exactly the
original's moments after it and no others, the inspector's sentence, the disabled time field and a writable note.
The planner edits the last moment ("out late") and publishes: the live strip follows the copy at **revision 2 with
the same T+0** — the clock did not move with the plan — and an edit that would drag the +5:00 frame back to +0:10 is
refused with *"This copy starts at +1:38: the walk before it stays on the plan it was copied from."* while the time
field goes **back** to +5:00 and nothing on the strip moves. The member's tab, reopened after the publish, is the
copy's schedule: it starts at the cut (6:19 am, not T+0), that moment reads **arrived · on time · recorded**, the
kept moments are the original's times, the last one carries the new note, and nothing on the page is planned before
the cut. **Proven to bite:** with the cut never taken, the check waits 15 s for the copy's marked start frame; with
the hand-over not recorded, the member's cut row is not `arrived`; with the cut triggers dropped, no refusal toast
ever arrives. Screenshots `shots/step17-board.png`, `shots/step17-cut.png`, `shots/step17-member-after.png`.

**Found while doing it:** four findings. The schema's default ACL grants EXECUTE to `authenticated` on every new
function, so 040's "revoked all the same" is true of `anon` only — harmless, because Postgres refuses a trigger
function that is called directly, and the check now asserts what is true (51). A refused time edit **left the typed
time in the box**: the field is bound to the frame's time and a failed write does not change it, so the box kept
saying a time the database had refused — the catch now puts the frame's time back (52). Deleting the plan a copy
came from sets the copy's `fork_of` to null through the foreign key, and a rule that "a cut must name its original"
turned that into a refusal, making the original undeletable while a copy existed; the check is on INSERT only now,
and a plan is always deleted whole, because deleting a copy's positions on their own is refused by the cut (53).
And a uuid is global, not per-event: the database check's first version reused the browser bench's plan id, so its
cleanup deleted the browser bench's plan — two benches must not share an id even across events (54).

**The suite was re-run:** SQL checks for steps 2–17 green on a bare bench; browser board smoke 22, keyboard 18, step
2 11, steps 4–13 **408**, step 15 **25** (two tabs), step 16 **69** (five tabs), step 17 **44** (three tabs); PGlite
322, `npm run build` clean, ledger **53 files, 53 applied, 0 pending, 0 drifted**.

**18. Publishing is compare-and-set, and leaves a version** — M, needs 17
`plan_publish` takes the caller's `plan_rev` and refuses a stale one; each publish writes `plan_versions`
(**RLS, R3**).
**Done when:** two planners fork the same plan; the second publishes, the first is refused as stale — **driven
through two browser tabs, and the client must actually send the rev** (a null rev is currently accepted and would
pass silently).

**DONE.** `054_publish_versions.sql`. `plan_publish(p_plan, p_plan_rev)` replaces the one-argument function (R2:
dropped, recreated, re-granted; R4), reads the plan row **for update**, and refuses before it does anything: a plan
that is not there, a caller who is not ops staff, a **null** revision ("Publishing must say which revision the screen
is showing"), and a revision that is not the plan's ("This plan changed while this screen had version 1 on it (it is
now version 2). Nothing was published; reload the plan and publish again." — PT409). Only then does the 25 m gate
run, because the content being validated has to be the content the caller saw. The version is written in the same
transaction as the bump: `plan_versions` (RLS on, one `SELECT` policy for ops staff, `SELECT` and no write grant for
`authenticated`, nothing for `anon`) holds one row per (plan, revision) — the plan's name, date and printed T+0, the
`fork_of`/`fork_cut_s` a copy carries, `published_by`/`published_at`, and `frames` as JSON: every frame in time order,
with its positions ordered by group and each position's `lat`/`lng`/`state`/`verify`. It is a scalar aggregate, so a
plan with no frames still writes a version. The client sends `plan.rev` (`usePlan.publishPlan`); a stale refusal
re-reads the plan, and `PlanLive` now compares the session's revision against the revision the **board** holds rather
than the first one the strip happened to read — otherwise a tab that step 17's hand-over had left on an old picture
would call the newer revision its own and never warn.

**The Done-when, at the database:** `dev/checks/step18-publish.sql` — eleven sections, rolled back, on the bench. A
null revision is refused (22023, nothing written); **two planners on one plan**: testuser1 publishes at revision 1
(rev 2, version 2), testuser2's publish at revision 1 is refused (PT409, both numbers named, no bump, no version),
and testuser2's publish at 2 lands (rev 3, `published_by` the second planner). The version is the plan that went out
(frames in time order, notes, four positions with the `off_site`/`manual` flags, coordinates as numbers,
name/date/T+0, `published_by` five minutes fresh); a frame edited afterwards leaves it identical; a 200 m step is
refused by the gate and writes no version (then publishes once fixed); an empty plan leaves a version holding `[]`.
Publishing a copy taken mid-walk writes `fork_of`/`fork_cut_s` on its version and hands the session over with the
clock untouched — and a refused publish at revision 99 hands nobody over, stands nobody down and writes nothing. Ops
staff (root, planner, marshal) read six versions; a member and an outsider read none; `anon` has no table privilege;
`authenticated` has `SELECT` and no insert/update/delete; RLS is on with exactly one read policy. Deleting a plan
takes its versions and only nulls the link on a copy's version; the copy's death takes its own. `plan_publish(uuid)`
is gone, `(uuid, integer)` exists, and `anon` and `PUBLIC` cannot execute it. **Proven to bite:** no null check →
`FAIL 1a`; no revision comparison → `FAIL 2c`; no version row → `FAIL 2b`; an empty snapshot → `FAIL 4g`; a
member-readable policy → `FAIL 8d`; an insert grant → `FAIL 8h`.

**The Done-when, through the screen:** `dev/checks/step18-publish-prep.sql` builds an event ninety seconds into its
walk; `node tools/run.mjs dev/checks/step18-publish.mjs --session .tmp/session.json` runs **42 assertions, two tabs**.
Tab A copies the live plan and keeps revision 1 on screen; tab B opens the live plan (a draft is opened for nobody),
picks the copy from the plan list, labels the way-out moment and publishes — revision 2, the session handed over. Tab
A's strip then says exactly what it is: "This plan was published again while this page was open (version 1 → 2). What
is on screen is version 1", and the chip reads 1. A's own Publish is
refused by the database (HTTP 409) with the sentence naming 1 and 2 — which is the proof the client *sent* a
revision, because a null is refused as a missing revision and a fresh number would have published — and the page
re-reads itself, so the label appears, the warning clears, the button becomes "Publish again", and the second press
takes the plan to revision 3 with the label intact. (Since step 19 the label may already be on tab A before the
refusal: content travels live, and a publish is the moment the board stops adopting it. The revision is the claim
that has to hold every run, so that is what the check measures — the count went from 43 to 42 for it.)
**Proven to bite:** the client sending `null` → tab B's publish
is refused and no "Published" toast ever arrives; no re-read after the refusal → tab A never adopts revision 2; the
strip taking its revision from the session → the warning never appears (25 s). Screenshots `shots/step18-stale.png`,
`shots/step18-refused.png`, `shots/step18-republished.png`.

**Found while doing it:** five findings. The revision a screen holds was a number the database never asked for — the
publish took a plan id and published whatever was current, so the comparison had to be added *and* locked to mean
anything (55). The client overwrote **every** PT409 with one sentence, which was fine while every conflict was a
frame and useless for a publish that has to name two revisions (56). `PlanLive` took its "held" revision from its
first read, so since step 17's hand-over a tab drawing old frames could legitimately call the newer revision its own
(57). A revision is bumped by a **rename** too (`plan_save`), so a publish can be refused for a change that is not a
timetable change — deliberate, and part of what "the plan's revision" means (58). And the check's own count of
versions was unscoped, so it read the browser benches' versions from three other events as well (59).

**The suite was re-run:** SQL checks for steps 2–18 green on a bare bench; browser board smoke 22, keyboard 18, step
2 11, steps 4–13 **408**, step 15 **25** (two tabs), step 16 **69** (five tabs), step 17 **44** (three tabs), step
18 **43** (two tabs); PGlite 322, `npm run build` clean, ledger **54 files, 54 applied, 0 pending, 0 drifted**.

**19. A published change reaches the other screens** — M, needs 18 (done)

**DONE.** `plans` is in `supabase_realtime` and gets `replica identity full` (055); the plan board listens to it
(`usePlan`: one channel per event, one table). The step expected `plan_frames` and `plan_positions` to be published
too, and a replica identity "for deleted frames". Neither was needed: every write to a frame or a position already
ends by touching its plan row (`update public.plans set updated_at = now()` in 038/041/042/044/045/046/047), so the
plan row is a complete change log and one table is one channel. The replica identity turned out to be for a deleted
**plan** — a DELETE event with the default identity carries only the primary key, so an `event_id` filter could never
match it (finding 60).

**What the client does with a change** is the interesting half. A change whose revision did not move is content: the
frames are re-read. A change whose revision *moved* is a publish or a rename, and the board **does not adopt it** —
the live strip names the newer revision and offers the catch-up (steps 15/18). That split is deliberate: a background
reload that swapped the picture would silence the warning that exists for exactly that (finding 62), and it makes
"the content travels, the announcement does not" the sentence this step is about.

Three races had to be closed before the channel was safe to leave on. A read that lands while a planner is dragging a
badge rebuilds the marker under the hand and Leaflet ends the drag with the removed element, so a background read is
held from pointer-down to pointer-up (`pauseLive`) and the marker layer is not redrawn while a drag owns it. A read
started before another write can also return *after* that write's own reload and put the older picture back, so a
change that arrives while a save is in flight is read again once the save has landed. And the revision to judge by is
the one the read answered, not the one the payload carried: a publish can commit between a frame write's payload and
the read that follows it, and adopting the fresh row then would move the strip's number to the new revision while the
frames under it were still the old ones (finding 63) — which is exactly the silence step 18 exists to prevent.

**The Done-when, at the database:** `dev/checks/step19-realtime.sql` — two sections, rolled back, on the bench. The
channel exists: `plans` is in the publication with insert/update/delete on, its replica identity is full, and
`plan_frames`/`plan_positions` are **not** published (the assertion fails if a later step adds them, so the reason in
055 is not quietly lost). And the change log really is one: the plan's `updated_at` is moved to a sentinel, one write
is run as a planner, and the row must come back touched — for a create, a note, a move, a shift, a hold, a fill, a
verify patch, a rename and a frame delete — while the same verify flag written twice must **not** touch it (a signal
per no-op would be a reload per keystroke). **Proven to bite:** `plans` out of the publication → `FAIL 1a`;
replica identity back to default → `FAIL 1b`.

**The Done-when, through the screen:** `dev/checks/step19-realtime-prep.sql` builds an event two minutes into its
walk; `node tools/run.mjs dev/checks/step19-realtime.mjs --session .tmp/session.json` runs **32 assertions, three
tabs**. Tab A opens the live plan and is not touched again. Tab B changes the call moment's note: tab A's note field
says "wave through" within seconds, without a reload — the board has no timer, so before this step it would never
have asked. Tab B adds a frame: tab A's bar goes from "3 frames" to "4 frames" by itself. Tab B publishes: tab A's
strip says version 1 → 2 while tab A keeps the picture it is drawing. Tab B deletes the plan: tab A lets it go and
shows the empty board — the DELETE-only case, and the reason the replica identity is on `plans` at all. **Proven to
bite:** the subscription removed → tab A never sees the note (15 s); `plans` un-published → the same; replica
identity back to default → every earlier section passes and only the deletion is never heard (15 s).

**Found while doing it:** seven findings. The step named the frames and positions, but the plan row was already the
change log (60). Realtime applies RLS to every event **except DELETE** — its own documentation says there is no way to
check a deleted record — which is the reason not to subscribe to positions: a delete per position that merely stayed,
carrying every group's coordinates (61). A revision bump is not content, and a board that swallowed it would silence
step 18's warning (62). The revision to compare must be the read's, not the payload's (63). Two tabs of one planner
exposed two gesture races that had never mattered while nobody else's writes arrived (64). The typing helper had
assumed its clear had landed (65), and the step-17 bench could be left in a state its own cleanup could not name (66).
Those last two are not the product's: they are what a busier page and a half-deleted bench do to the tools that prove
it, and both are fixed where they live rather than worked around in the step's own check. And step 15's and step 18's
"the other tab does not have my frames" assertions had to become "the other tab may have the frames; what is stale is
the revision", because a publish is now the moment the board stops adopting content (finding 62, and the debts
below).

**The suite was re-run:** SQL checks for steps 2–19 green on a bare bench; browser board smoke 22, keyboard 18, step
2 11, steps 4–13 **408**, step 15 **24** (two tabs), step 16 **69** (five tabs), step 17 **44** (three tabs), step
18 **42** (two tabs), step 19 **32** (three tabs); PGlite 322, `npm run build` clean (the chunk notice only), ledger
**55 files, 55 applied, 0 pending, 0 drifted**.

### E — replacing the live engine

**20. Ops, status, and where a group really is** — M, needs 2, 14 (done)

**DONE.** `plan_ops(p_session, p_at)` (056) answers one row per group per moment of the walk: `pending` / `active` /
`done`, the strip's travel time for that moment, the moment's own position, where the walk has the group at `p_at`
(053's interpolation), and where its ICs really are — the accuracy-weighted midpoint of their newest readings,
computed in the database. `PlanOps.vue` puts it on the Live page for ops staff whenever the session is running a plan:
the one screen a plan session never had, because the run-sheet ops board reads `movement_status` and is deliberately
not shown for a plan (`hasOps` was `!planSession && …`, so a plan session showed a map and nothing else).

**The three words are attached to a moment, not to a group, and that is the step's real decision.** A group has two or
three moments, so a group's own state flips twice and then says "under way" for the rest of the night — while the
done-when asks for a flip as the clock passes **each** frame. A moment's status is the walk that begins at it:
`pending` until its own time, `active` from its time until the group's next moment, `done` once that next moment has
arrived (finding 67). Passing a frame therefore flips exactly one row of that group from pending to active and the row
it left from active to done, which is the done-when literally; and an ops board gets both halves it wants — the moment
the group is on, and the one after it. A last moment has no walk, so it goes pending → done at its own instant and a
one-moment group never reads active: that is stated rather than discovered, and it is why "a group is done" means "its
plan has no more moments", not "it arrived" (finding 70, and step 21 marks the arrival).

**Travel time is the strip's interval**, `next_t_s - t_s`: the time the plan gives a group to get from one statement
to the next. Deliberately not lateness (`now - t_s` is 050's number) and not metres over a pace: the plan states no
route, 048 measures a straight line only as a lower bound, and a pace the strip never agreed to would be this read
inventing a figure. The check asserts 60 s where lateness would say 30, 3420 s across a one-hour gap, and 120 s for a
group whose two statements are the same place.

**Where a group really is** is the accuracy-weighted midpoint — weight 1/accuracy², newest reading per IC from the last
two minutes, only 0 < accuracy ≤ 100 m, and `stop` is not a position — which is 021's rule and has been since Stage 2.
The step says "computed server-side"; it already was, inside the trigger that fills `group_positions`, so the rule
moved into one internal function (`group_position_at`) that 021's trigger and this read both call (finding 68). That is
the point of moving it: the map and the ops board cannot answer the midpoint differently, and the check asserts they
do not. `actual_ics` counts the ICs that are sharing at all, which is not the same number as the readings that were
used; with no usable reading the position is null, not zero metres — "no signal" is an absence, not a place. The scope
is 040's, applied **before** any per-group function is called, because `plan_position_at` refuses a group the caller
may not read: a read that computed first and filtered afterwards would raise for a member instead of answering for
their group (finding 69). An off-site moment has no place to measure to, so `off_m` is null even though the phones'
position is still answered.

**The screen is one read per open board, and only while the Live page is shown** (finding 72). `PlanOps.vue` groups
the rows, picks the active one (or the first pending, or the last done), and wakes at the soonest planned moment —
that is what turns "Not started" into "Under way" at the second the frame arrives rather than at the next poll — plus
a five-second poll for the midpoint, which moves with the readings, and a re-read on a publish, on the session being
handed to another plan, and when the tab is looked at.

**Done when, at the database.** `node tools/sql.mjs --file dev/checks/step20-ops.sql` builds its own five-moment plan
(one group walking a minute a step then standing for an hour, one off site at its second statement, two groups with a
single moment), publishes it, starts a session through `start_event`, and reads at chosen instants: 9 rows over 4
groups at T+1:30; **25 row assertions** at every one of Gate Crew's moments and one second either side of it, plus
nine counts of the moments under way, so the flip is proved at the frame and not merely across the night; the travel
numbers above; two ICs 20 m apart at 5 m and 20 m accuracy put the group **1.18 m** from the walk (`off_m` 1), and
swapping the accuracies puts it **18.82 m** away (`off_m` 19) — neither an average (10 m) nor "trust the best phone"
(0 m or 20 m) can pass; a 150 m reading is counted as sharing and not used; a three-minute-old reading is not used at
all; a `stop` row leaves the group with no position; `group_positions` answers the same midpoint from the same
readings; a member sees only their group, a member with no group nothing, an outsider is refused, a session with no
plan and an unknown session are refused with their own sentences, `anon` has no grant, and the internal helper is not
executable by `authenticated`. **Proven to bite:** the weight made linear → `FAIL 4d` (16 m, not 1.18); the pending
boundary made inclusive → `FAIL 2b` at T+0; the off-site distance computed anyway → `FAIL 6d`; the two-minute window
widened to thirty → `FAIL 4q`.

**Done when, through the screen.** `dev/checks/step20-ops-prep.sql` rebuilds an event two seconds into its walk, and
`node tools/run.mjs dev/checks/step20-ops.mjs --session .tmp/session.json` runs **18 assertions on one tab**: Gate Crew
is under way on its +0:00 moment with 45 s of travel and "1 m from the walk · 2 ICs"; Sound waits for +0:45 and
Backstage for +1:45; then, with nothing clicked, the clock passes +0:45 and the board says Sound is under way on
+0:45 with a minute of travel, Gate Crew is done on its last moment, Backstage is still waiting, and the header has
moved to "1 under way · 1 not started · 1 done". **Proven to bite:** the same linear weight → "4 m from the walk",
and the screen assertion fails; the wake and the poll removed → the flip never arrives (the wait times out at 60 s).

**Found while doing it:** six findings (67–72). The status unit (67); the midpoint that already existed in a trigger,
now one rule with two callers (68); the scope that has to precede the per-group reads because the position function
enforces it (69); the last moment's missing walk (70); the two-minute window being measured from `p_at` rather than
from now, which a check standing at a chosen second has to respect (71); and — caught not by this step's check but by
step 19's, which deletes the live plan — the panel was mounted on every page because the Live page is kept alive by
`v-show` for the map, so it polled `plan_ops` while a planner was drawing and hit the one-instant window where the
plan is gone and the session has not reloaded yet, logging an HTTP 400 in a check that had nothing to do with it (72).

**The suite was re-run:** SQL checks for steps 2–20 green on a bare bench; browser board smoke 22, keyboard 18, step
2 **11**, steps 4–13 **408** (24/47/44/37/49/29/43/29/36/70), step 15 **24** (two tabs), step 16 **69** (five tabs),
step 17 **44** (three tabs), step 18 **42** (two tabs), step 19 **32** (three tabs), step 20 **18** (one tab); PGlite
322, `npm run build` clean (the chunk notice only), ledger **56 files, 56 applied, 0 pending, 0 drifted**.

**21. Pushes, ETA, arrival marking and the hand-back log** — M, needs 20
`plan_push_tick`/`plan_eta_tick`; `verify:'auto'` becomes real; `handover_log` (**RLS, R3**); the migration
schedules the new jobs **and unschedules `gps-push-send`/`gps-route-eta` in the same transaction**, new job before
old job.
**Done when:** `cron.job` lists the new names and neither old one, **each new job shows two consecutive succeeded
runs**, an auto-verified frame closes when an IC is inside its zone, and a hand-back row records who and when.

**DONE.** Migration **057** — four functions, one table, two jobs. `plan_auto_close()`, `plan_collect_pushes()` (the
"now" nudge), `plan_push_tick()` (the 5 s heartbeat: close, nudge, collect No-Go, kick), `plan_eta_tick()` (the 30 s
forecast: leave-now and running-behind), `handover_log` with a read policy for the event's members and no write policy
at all, `handover_take()` and `handover_log_list()`, the three new push kinds (10 → 13), and `plan_ops` re-created with
`marked_state` / `marked_at` / `marked_by` so the board can render a close and say who said it. `cron.schedule` writes
pg_cron's own tables **inside the migration's transaction**, so the swap is atomic: `gps-plan-push` (5 s) and
`gps-plan-eta` (30 s) exist before `gps-push-send` and `gps-route-eta` are unscheduled, and there is no instant with
neither pair. (And one correction the regression run forced: `plan_ops` and 052's `session_timetable` now answer **no
rows** for a session whose plan has been deleted, instead of refusing — finding 79, which step 19's own deletion test
found as an HTTP 400 in a planner's console.)

**The one decision worth naming: `auto` is a rule about the DRAWN POINT, not about the phones** (a claim step 27
half-overturned; see the end of this paragraph). 046 gave a position
`verify` = `auto` (trusted as drawn) or `manual` (somebody must confirm), and nothing read it. The rule now is: the
group's **current** moment, whose position is `auto` and on site, closes itself as `arrived` when an IC **of that
group** (`group_members.is_ic`, not the reading's own group id — who an IC is is a fact about the event, not about the
last phone upload) is inside a zone that contains **the moment's drawn point** (`st_dwithin(shape, point, 0)`, 020's
own containment). The plan has no notion of a destination area, so the only real area a badge can be "at" is the zone a
planner dropped it in; a badge in an empty field can never close itself and waits for a tap. The row is written with
`marked_by` null (the tick, not a person) and `marked_at` = **the later of the planned time and the IC's entry**, so a
tick that runs twenty seconds late still records when the group was actually there. `manual` is not advice: the tick
skips it, and the screen offers the two buttons instead. **Changed in step 27** (063): the place test is still what
decides *whether a moment can close itself at all* — a route point still waits for a tap — but "inside its zone" is no
longer the only way to be there. An IC within **their own arrival radius** of the drawn point closes it too, because a
phone in a pocket is not a polygon; the gate is what this paragraph was really protecting, and it survived (narrowed to
the kinds 062 calls a place, so a cordon is not one).

**The forecast is arithmetic, not a route.** `plan_eta_tick` divides straight-line metres (from the group's midpoint to
its next moment's point) by `group_positions.speed_mps`, with a floor of 0.5 m/s and a default of 1.3 m/s when no speed
has been measured — a group standing still must not read as infinitely late. Two pushes, once per moment and person:
*Leave now for the stage — 307 m, about 224 s at your pace* (60 s before the leave-by time the maths implies, and only
over 25 m: a group at the door is not told to walk) and *Running behind — you arrive 7:14 pm, 2:30 after the plan* (> 60 s
past the moment). No fix in the last two minutes means **no forecast**: silence rather than a number invented from where
a phone was an hour ago. The old jobs' non-run-sheet duties moved into the heartbeat, so nothing went dark: No-Go pushes
are still collected and the sender is still asked to send. What is genuinely lost until step 24 is the OneMap **route**
refresh for run-sheet movements (`gps-route-eta`), which is the engine being retired and a cost this step pays.

**Keeping the chain honest.** `from_user` is read off the previous row of the same session (the caller cannot say who
had it), `plan_rev` is copied from the session (what the person taking over was looking at, which is what step 18's
versions name), `handed_at` is **`clock_timestamp()`** and not `now()` — frozen for a whole transaction, it gave two rows
written in one transaction the same instant and a chain with no order. A plain member can read the log and cannot take
the board; an ended show has no board to take; `authenticated` has SELECT and no write grant, so `handover_take()` is the
only door.

**Done when, at the database.** `node tools/sql.mjs --file dev/checks/step21-push-handover.sql` (one transaction,
rolled back; it builds its own event, four groups, three boxes and a session, because only three of the bench's five
people may be in a group). **Section 1**: the first call closes exactly **one** moment — Gate Crew's, *dated from the
plan* (t0+60) because its IC was already inside — and nothing else: Sound is `manual`, Backstage is off site, and
Security's presence is by a man who is **not yet its IC** (it closes only after the membership row is inserted, and then
it is dated from his **entry**, t0+80, not from the moment). A second call closes nothing. **Section 2**: at t0+190 every
group's current point is outside its box, and nothing closes — "inside its zone" is about the drawn point, not about the
phones. (Since step 27 this section proves something narrower and still true: nothing closes because the phones are far
from the points — a phone *within its radius* would close a placed moment, and a route point would not. The sentence it
was written for, "a drawn point outside every box has no area to be inside", moved into 063's gate.) **Section 3**: the tick queues **one** nudge (Sound's IC), titled "Now: stage", naming the zone, carrying the frame
id a tap opens; a second tick adds nothing; a No-Go entry still becomes a push; the forecast queues exactly **two**
(Security's leave-now and running-behind), carrying the **307 m the database measures**, while Gate Crew (0 m away) and
Sound (no fix at that instant) and Backstage (off site) get nothing. **Section 4**: the chain's second row's `from_user`
is the first row's `to_user`, the revision is the session's, the note is trimmed, the first row has **no** previous holder
(its `from_name` is null, not the word "someone"), a plain member is refused with 42501, an ended show with 22023,
`authenticated` cannot insert. **Section 5**: `plan_ops` reads the automatic close as `arrived` with `marked_by` null and a
hand tap as `arrived` with the IC's id. **Section 6**: `cron.job` lists both new names and neither old one, each new job's
command is the function it should be, and none of the four internal functions is executable by `authenticated`.

**Proven to bite, six times** (each restored by re-applying 057; the ledger then showed 0 drifted): the `manual` check
deleted → `FAIL 1a` (two closed); the zone containment replaced with `true` → `FAIL 2a`; `marked_at` set to the entry
alone → `FAIL 1e` (the close is dated 1:00 before the plan); the nudge's dedup made unique per call → `FAIL 3g`; the IC
join dropped (any presence in the zone) → `FAIL 1a`; the 25 m "already there" threshold dropped → `FAIL 3i` (three
pushes, not two).

**Done when, through the screen.** `dev/checks/step21-ops-prep.sql` builds a live plan whose +1:00 moment is twenty
seconds away, with Gate Crew `auto` + its IC inside the box and Sound `manual` + its IC inside its box; then
`node tools/run.mjs dev/checks/step21-ops.mjs --session .tmp/session.json` runs **15 assertions on one tab**. Both groups
start unrecorded and offering *Arrived* / *Missed*; then, **with nothing clicked on Gate Crew**, the deployed tick closes
its +1:00 moment and the chip reads "Arrived 6:30 pm · the phone was there" — the cron job, the function and the screen
proving each other, and the buttons gone. Sound's manual moment is still open with its IC inside the same zone; the check
presses *Arrived* and the chip reads "· by hand", the buttons gone, Gate Crew's record untouched. The board says nobody
holds it, one press writes "Board with testuser1 since 6:30 pm", and **a reload** still shows both marks and the same
hand-back — the row is in the database, not on the screen. **Proven to bite:** the same fixture with Sound's position
flagged `auto` → the check fails at "Sound's manual moment did NOT close itself", which is exactly the flag's job.

**And the jobs really ran.** `cron.job_run_details` for `gps-plan-push` (dozens of `succeeded`, starting within 5 s of
the migration) and for `gps-plan-eta` (three consecutive `succeeded` at 10:24:43, 10:25:13, 10:25:43) — the step's two
consecutive runs, plus one; and while the browser check watched, the live tick closed a moment at exactly its planned
second. `zz-walk` and the other seven jobs are untouched.

**Found while doing it:** eight findings (73–80). The CHECK constraint re-stated from the files rather than the database,
which refused to apply until the tenth kind (`sos`) that no migration writes was carried forward (73); `now()` being
frozen, so a hand-back chain had no order until `handed_at` became `clock_timestamp()` (74); the first hand-back naming a
previous holder called "someone", because a coalesce fell through when there was nobody (75, caught by the browser check
and not by the SQL one); a fixture that had to give the measured speed and the zone entry to two different phones,
because one phone cannot both walk into a box and have a realistic speed (76); the ticks' `p_session`/`p_at` parameters,
which exist so a check can stand at one session and one second while cron passes neither (77); and the nudge's
one-minute bound, which means a cron gap loses the nudge rather than backfilling it (78). Two came from the regression
run rather than from the step: a poll outliving the plan it asks about — the deletion in step 19's check put an HTTP 400
in a planner's console, and **both** plan reads now answer no rows for a session whose plan has been deleted (79); and a
step-20 check that had silently depended on the hour, because the bench's fixed 18:45 session starts covering readings
inserted "ten seconds ago" after 18:45 (80, fixed in the check).

**The suite was re-run:** SQL checks for steps 3–21 green on a bare bench; browser board smoke 22, keyboard 18, step 2
**11**, steps 4–13 **408** (24/47/44/37/49/29/43/29/36/70), step 15 **24** (two tabs), step 16 **69** (five tabs), step
17 **44** (three tabs), step 18 **42** (two tabs), step 19 **32** (three tabs), step 20 **18** (one tab), step 21 **15**
(one tab); PGlite 322, `npm run build` clean (the chunk notice only), ledger **57 files, 57 applied, 0 pending, 0
drifted**.

**22. Broadcasts, targeted ack, and playback** — **DONE** (058). `plan_log` is the plan's own record: a message a
planner sends to the plan's groups, and every publish that moved somebody's walk. Each row carries its audience
(`all`, `group`, `ops`), one recipient row per person, and **one tap** to ack it; `plan_log_list` answers the sender's
tally ("3 of 5 got it · waiting on Sound") and a member's own rows and nothing else. The push is the targeted half:
publishing compares the walk it announces with the walk it replaces, group by group and moment by moment, and queues
`plan_changed` only to the members of the groups whose walk moved — a republish that changes nothing writes no row and
queues no push, a first publish tells nobody, and a **copy's** first publish compares against the plan it was cut from,
from the cut onward, because that is how a running session is moved onto it. On the screen the strip plays the run
(Play/Pause/Stop, 1×/10×/60×, a cursor between the moments, badges interpolated along the walk) and the ops board grows
the log under the board it already had. **`show_log.kind` stays what it is** — twenty run-sheet values, `broadcast`
included — because nothing in this step writes that table: a plan message must not be deleted with the engine step 25
removes.

**Why a second log, and not a kind on the old one.** `show_log` is the run sheet's log — cues, GO, holds, written by
026–031 — and step 25 deletes it. A plan's message written there would be a message deleted with the engine, and a plan
session has no cue to attach it to; the plan log is per plan, outlives the session, and its audience is the plan's
groups. The step's own done-when says it plainly: **one row to the new log, zero to `show_log`**, and the check counts the
session's `show_log` rows at zero after every message and every publish it makes.

**One tap, not two instants.** 032's broadcast keeps a `seen_at` (the banner rendered) and an `acked_at` (a person
pressed). A plan message has no banner: it is on the schedule the person is already reading, so "seen" would be this app
guessing that a browser painted something. `plan_log_ack` writes one `clock_timestamp()`, and a second press returns the
first instant without moving it (finding 74's lesson, and the check proves the second press changes nothing).

**The comparison is the walk, not the positions.** `plan_version_walk` expands a version's frames into **each group's
effective position at every frame time** — carry-forward included, the frame's note included, an off-site statement
emitted as a gap. Comparing only the frames that *state* a position misses every group a frame-time move carries, which is
exactly the group that has to be told; the check asserts that a group with no position at the moved frame is still a
recipient (`FAIL 6b` when the walk was reduced to statements). Coordinates are rounded to six decimals — about a tenth of
a metre — so a float that comes back a hair different is not a notification. And the fork's window is `> fork_cut_s` on
**both** sides: the copy's anchor is a new moment at the cut for everybody, but nobody's walk changed there, and including
it told every group on every fork publish (`FAIL 7c` when it did).

**Done when, at the database.** `node tools/sql.mjs --file dev/checks/step22-log-targeting.sql` (one transaction, rolled
back; its own event, four groups, a plan, a session and four publishes). **Section 0**: the first publish writes a version
and no log row. **Section 1**: a message to Gate Crew writes **one** row, **zero** `show_log` rows, two recipient rows and
two `plan_message` pushes, trimmed, dated, named; the group's IC reads the row, the tally is hidden from them, the ack
writes one instant and a second ack returns the same one; a person the message was not sent to reads nothing and is
refused the ack (42501); the sender reads "1 of 2 · waiting on Gate Crew"; a message to a group with no part in the plan is
refused (22023), an empty one is refused, and a member may not send. **Section 2**: "every group" reaches the plan's two
populated groups (3 people), not the memberless one, not the group with no part in the plan, and never the sender.
**Section 3**: "ops" from the second planner reaches the root only and carries the URGENT prefix. **Section 4**: a
republish that changes nothing writes no row and queues no push — and still writes its version. **Section 5**: moving
Sound's +1:00 point 5 m east writes one `timeline` row for version 4, whose recipients are Sound's one person and nobody
in Gate Crew. **Section 6**: moving the +2:00 frame to +2:30 names all three walks — Gate Crew, which states it, and
Sound and Backstage, which carry into it — and puts three people in the inboxes. **Section 7**: a copy cut 90 s in and
published untouched tells nobody and is carried by the running session; edited for Sound only and republished, it tells
Sound and not Gate Crew. **Section 8**: the push kinds are additive (`sos` still legal), the walk helper is not executable
by `authenticated`, both tables are RLS-protected with no write grant, a direct insert is refused, a stranger is refused
the read, and a deleted plan answers no rows. **Section 9**: nothing ever wrote `show_log`, and the log's instants are all
distinct.

**Proven to bite, four times** (each restored by re-applying 058; 0 drifted after): the diff replaced with `where true` →
`FAIL 4a` (a republish that changed nothing wrote a row, and would have told everybody); the walk reduced to stated
positions → `FAIL 6b` (the two carried groups dropped out of the sentence); the fork window opened to the anchor →
`FAIL 7c` (the copy's first publish wrote a row); the ack's `acked_at is null` dropped → `FAIL 1p` (a second press moved
the record).

**Done when, through the screen.** `dev/checks/step22-play-prep.sql` builds a live plan three moments long, thirty
seconds into its clock, with one published change that moved Gate Crew's last moment and left Sound's alone; then
`node tools/run.mjs dev/checks/step22-play.mjs --session .tmp/session.json` runs **23 assertions on five tabs**. The
planner presses Play and the strip's clock runs from near +0:00 to the end of the walk at 60×, the cursor travels 47 px,
the badge on the map moves 90 px, the caption names the next moment and says it is playing, and the run stops itself at
+2:00; Stop reopens the moment it ended on. The ops board shows the publish's own row ("Times changed", "0 of 2 got it ·
waiting on Gate Crew") before anybody types anything, and the planner's message appears above it at "0 of 3 · waiting on
Gate Crew, Sound". The Gate Crew IC's schedule carries **both** rows; the Sound admin's carries **only** the message — the
targeting, read as a person reads it — and each presses Got it once: the row says "got it 8:35 pm" and the button is gone,
while the timeline change is still waiting for them (one tap, one row). A **fresh** planner tab then reads "2 of 3 got it ·
waiting on Gate Crew" for the message and "0 of 2" for the change, so the count is in the database and not on the screen
that sent it.

**The suite was re-run:** SQL checks 2–22 green (21 files, each on a rebuilt bench); browser board smoke **22**, step 2
**11**, steps 4–13 **408** (24/47/44/37/49/29/43/29/36/70), step 15 **24**, step 16 **69** (5 tabs), step 17 **44**, step
18 **42**, step 19 **32**, step 20 **18**, step 21 **15**, step 22 **23**; PGlite **322**; `npm run build` clean (the chunk
notice only); ledger **58 files, 58 applied, 0 pending, 0 drifted**.

**Found while doing it:** seven findings (81–87). The log had to be its own table because step 25 deletes the old one (81);
a copy's first publish had to compare the future rather than the anchor (82); a tally read from the recipients' group
column cannot show a group with nobody in it (83, my check's mistake); three checks clicked the bar head's **second
button** for zoom and this step's new controls moved it, so they now click a name (84); two publishes are two versions,
not two revisions (85); and the bench's identity is the **browser's**, not the tab's — the Gate Crew tab re-read after
the Sound tab was seeded and answered as Sound, so the timeline row vanished mid-check (86). The seventh is an
observation, not a defect: step 8's drag failed twice under load and passed twice clean (87).

**23. CSV export and import** — M, needs 15 — **done**

**Done.** `src/utils/planSheet.js` is the plan's own file: `sheetText`/`sheetFileName` write it, `readSheet` reads it,
`sheetGaps` holds the 25 m rule over what was read, and `gapDetail` — moved into `planFrames.js` — is the *one*
sentence the strip's warning and an import's refusal both use. `059_plan_import.sql` adds
`plan_import(p_plan, p_frames)`: one call, one transaction, the plan's moments replaced. On the board, two quiet
buttons beside the plan's name (**Export CSV**, **Import CSV**) and a hidden file input; a refusal is a one-button
dialog (`askConfirm` grew `lines` and `cancelText: null`) and a successful import reports in a toast, while the export
is the browser's own download (`saveFile`, so Android's Save screen works too). No ExcelJS and nothing from
`runSheetFile.js`, which is the run sheet's workbook and dies in step 25.

**The file is a table, not a document.** One row per statement, seven columns: `t_s,note,group,lat,lng,state,verify`.

    0,"Call, everyone at the ""gate""",Gate Crew,1.2966123456789,103.773102,on_site,auto
    0,"Call, everyone at the ""gate""",Sound,1.29662,103.7732,on_site,auto
    90,,Gate Crew,1.2967,103.7731,on_site,auto
    180,,Back at the gate,,,,,

A moment nobody stands at is one row with the group cells empty; a group missing from a moment is carried from the one
before it, exactly as the model does, so the sheet is as sparse as the plan. `t_s` is **seconds from T+0**, a whole
number: Excel turns a time-looking cell into a fraction of a day and saves it back as 1:30:00 AM, which would be a
different plan. The reader still takes the strip's own label as a courtesy ("+1:30", "90s", "2m"), because a planner
typing into a spreadsheet will write what the board says. Coordinates are written with `String()`, the shortest exact
text for the double: six decimals would move a marker by up to 6 cm on every round trip. The file starts with a BOM (so
Excel reads accented names) and a `#` line (so a person knows what the numbers are); both are skipped on the way back,
and the reader also takes semicolons — Excel in a locale where the comma is the decimal separator saves them.

**Four decisions.**

1. **One function, one transaction, and it calls `frame_save` per frame.** A client loop would be N transactions: a
   refusal at the ninth frame leaves eight frames of a plan nobody asked for. Calling `frame_save` keeps one copy of
   every rule a frame has (the time's range, the words, a group from another event) — the next fix cannot forget the
   importer (R8). The refusals roll the whole thing back, which is why three of the check's seven cases fail *after*
   the delete has run.
2. **A sheet replaces; it never merges.** It is the whole plan, so the target's moments are deleted first and the
   confirmation says so in both counts. It **may not erase what happened**: a plan with any `plan_progress` rows is
   refused before anything is deleted, in words that say to copy the plan and import into the copy — those marks hang
   off frame ids and would cascade away with them (050). The client cannot read progress, so this refusal can only
   arrive after the confirmation; it is shown in the same dialog, not as a toast.
3. **The 25 m rule is refused by the client, in the board's sentence.** `sheetGaps` runs `findGaps` over the read
   frames and the dialog lists `groupName: gapDetail` — character for character the red row under the strip, which is
   the step's own proof. The function deliberately does **not** repeat the rule: the database's gate is still
   `plan_check` at publish, and everything the map is needed for (a no-go crossing, an impossible pace) lands as a
   warning on the board exactly as if it had been drawn, because those are planning questions and not file errors.
4. **An import ends the undo stack**, like a publish: a sheet is a whole plan and the inverses are frame-level, so
   replaying one would write a single frame into the sheet's plan. The confirmation says it cannot be undone.

**Done when, at the database.** `dev/checks/step23-import.sql` builds its own event, two groups, a plan at revision 7
and a session, and rolls it all back — eight sections. One call replaces the moments, their notes and every position:
both flags come back (`off_site`/`manual`), an omitted flag takes its default, an empty note is null, a moment nobody
stands at survives, every old frame id is gone and the plan's revision stays 7 while `updated_at` moves (the channel
reads again). The read back through `plan_frames_list` is the same plan. An empty sheet empties it. Then **seven
refusals** — two frames at one time, a time that is not one, positions that are not a map, a group from another event,
a state word that is not a state, a sheet that is not a list, a plan that is not there — each leaves the frames and
positions exactly as they were, with two of them (a group from another event, a state word that is not a state) failing
after the delete has run, so it is the rollback that saves the plan. A planner (not only the root) may import;
a participant and a stranger are refused in `frame_save`'s sentence; `anon` has no execute grant and `PUBLIC` is not on
the ACL; the function is `security definer` with `search_path = public`. A sheet with a 100 m step **imports** and
`plan_check` then reports one break — the client is where that refusal lives. And once a session has marked one
arrival, an import is refused with the count, the instruction to copy, the moments untouched and the mark surviving.

**Done when, through the screen.** `dev/checks/step23-sheet-prep.sql` builds one event with two plans: "Sheet bench"
(four moments; a note with a comma and quotation marks, a group carried through a moment that does not state it, an
off-site position confirmed by hand, a 13-decimal latitude, and a moment nobody stands at) and "Sheet gap" (two
moments, Sound 100 m from where it stood a minute earlier). Then
`node tools/run.mjs dev/checks/step23-csv.mjs --session .tmp/session.json` runs **43 assertions on one tab**, with
**the browser's own download** read off disk and **a real file** handed to the board's hidden input. The export is a
BOM, a `#` title, seven columns and six rows, with the note quoted the CSV way and the latitude whole. The plan is then
thrown away, a new empty plan is made with the same name and the file is imported into it: the counts in the
confirmation are the file's, the toast reports what went in, and **the second export is the first file byte for byte** —
so every moment, note, place and flag came back. On screen the open moment's note is the file's, the off-site and
manual flags are the row's, the undo stack has started again and the four frames are new ids. Then "Sheet gap": the
strip says `Sound: 100 m between +0:00 and +1:00 (limit 25 m)`, its sheet is imported back untouched, and the
refusal's list line is **character for character that sentence**, one button, nothing written (the same two frame ids
afterwards) and the walk still red. Finally the same file with that one longitude typed over imports: the warning goes
out, the moments are new, and the export carries the number the planner wrote.

**Proven to bite, four times** (each restored, re-run green): the progress refusal disabled (`> 100`) → `FAIL 7a` (a
sheet imported over recorded actuals); the refusal's line written a second way ("100 m too far") → the screen check's
sentence equality fails; coordinates written `toFixed(6)` → the exported row is no longer the board's value; the 25 m
refusal bypassed → the dialog is a *confirmation*, not a refusal, and the check stops there.

**The suite was re-run:** SQL checks 2–23 green (22 files, each on a rebuilt bench); browser board smoke **22**, step 2
**11**, steps 4–13 **408** (24/47/44/37/49/29/43/29/36/70), step 15 **24**, step 16 **69** (5 tabs), step 17 **44**,
step 18 **42**, step 19 **32**, step 20 **18**, step 21 **15**, step 22 **23** (5 tabs), step 23 **43**; the sheet's
own test `npm run test:sheet` **58**; PGlite **322**; `npm run build` clean (the chunk notice only); ledger **59 files,
59 applied, 0 pending, 0 drifted**.

**Found while doing it:** seven findings (88–94). Deleting the open plan while another one exists left the board **with
no plan under it** — an empty strip and both sheet buttons disabled — so `removePlan` now opens the remaining plan (88;
the step's own wipe hit it). A missing SQL function inside an RPC comes back as **HTTP 404 on the RPC path** — "the
function is not exposed" and "the function called something that does not exist" look identical, and only the dialog's
body said `jsonb_object_length(jsonb) does not exist` (89; Postgres has `jsonb_array_length`, not an object equivalent,
so the count now comes from `plan_positions` after the write). Postgres here prints a float8 to **fifteen significant
digits**, so a 16-decimal fixture reads back as `1.2966123456789`: the file carries exactly the value the board holds,
which is all there is (90). A participant's read of `plan_frames` is scoped to their group (040), so a "nothing changed"
count taken as the participant answers 0 whether or not the write happened — a check that cannot fail; the refusal is
theirs and the count is the owner's (91). `assertThat` takes two arguments and silently drops a third, so an assertion
written with its condition in the detail slot passes trivially — the old truthy-string trap in a new costume (92). The
`#` title line is quoted when the plan's name has a comma, so filtering comments with `startsWith('#')` keeps the title
as a data row (93). And waiting for a frame count that is the same before and after an import proves nothing: the gap
plan has two moments either way, so the signal is the warning going out and the ids changing (94).

**Owing.** The export is the planner's: a member's board has no CSV button, so the part of the plan a person follows
still cannot be taken home as a file. The file has no identity of its own — the plan's name is a comment, and importing
"Sheet gap.csv" into another plan is allowed and silent about the source, which is a template feature and a way to
overwrite the wrong plan. A sheet cannot carry a frame's `rev` (irrelevant) or a plan's status, printed date, name or
T+0, so a round trip through the file keeps the moments and not the plan. Nothing checks a sheet against the locked
polygons before writing: a crossing imports, goes red on the board, and is refused at publish, which is the same
"content and revision can disagree" debt as any edit. The import is not undoable. A coordinate is effectively fifteen
significant digits everywhere in the plan stack (finding 91), so the file cannot be a decimal archive. The reader
accepts a header without a `group` column (a bare timetable of times and notes) but the import then empties the plan's
positions — a deliberate reading that no screen offers yet. And the whole thing is one CSV with one sheet: no template,
no run-sheet-style multi-tab workbook, and no way to export the plan's log or its published versions.

**24. Retire the last callers** — M, needs 21, 22
The simulator's `sim_follow_plan`/`sim_plan_movements` move onto the strip; `start_event`/`schedule_event_start`
lose `p_run_sheet` (**DROP + recreate + re-grant**, R2/R4); **every remaining cron job repointed, including the
unexplained `zz-walk`**, and the three tick jobs unscheduled **in the same migration that drops their functions**.
**Done when:** scanning `pg_proc.prosrc` and `cron.job.command` for the old names returns zero, and each surviving
job is asserted **individually** — "all succeeded recently" fails on the hourly ones.

**DONE.** `060_plan_only_engine.sql`. After step 21 replaced the two run-sheet cron jobs, four doors still called the
old engine; this file closes all four and moves the simulator onto the strip.

* **The start functions lose the parameter.** `start_event(event, plan)` and `schedule_event_start(event, at, plan)`
  are new signatures, and `session_engine` is down to `(event, plan)`; the three-argument versions were DROPped,
  recreated and re-granted (R2/R4), so a client written against 039 gets PostgREST's 404 instead of a session it did
  not ask for. The parameter is **removed, not guarded**: a boolean inside the body would leave `start_event(event,
  sheet)` in the catalogue still meaning "run a run sheet". New sessions still write `run_sheet_id = null` (the column
  is step 25's), and the update branch clears a value a scheduled session was carrying.
* **The simulator walks the strip.** `sim_follow_plan` gives each virtual group a leg to **its own next on-site plan
  moment** — the first frame ahead of the clock that states a position for it — and times the departure so it arrives
  a minute early. One leg per moment, a retarget when that moment has passed, and **a repeated position is not a new
  leg**. The behaviours keep their meanings: `late_2min` leaves two minutes later, `stops_halfway` halves the leg and
  then stays stopped (retargeting it would turn "never arrives" into "arrives late"), `loses_signal` is silent for
  2.5 minutes from 40 % of the walk, `wrong_zone` is not called by the plan at all. `sim_tick` calls it for the live
  session **before** it steps anybody. `sim_plan_movements` had no strip counterpart — its job was to write a Draft run
  sheet into movements, and a plan already says where each group stands and when — so it is gone, with the Simulator
  panel's "Plan their movements" card. `sim_start` now starts the event **on the published plan** (it used to start
  tracking-only and then follow movements a plan session cannot have), refuses with no groups, and refuses with no
  published plan.
* **Three jobs die in the migration that drops them.** `gps-show-tick` (`show_tick`), `gps-move-tick` (`move_tick`)
  and `zz-walk` (`zz_walk_tick`) are unscheduled **before** their functions are dropped, in one transaction — a 2 s
  job against a dropped function does not fail once, it buries every later error in the run log. `zz-walk` was the
  unexplained job of finding 7: a hand-made 5-second walk for one hard-coded event, group and person, driven by a
  hand-set `zz_walk.t0` rather than any session clock — a demo that outlived its event and is replaced by the
  simulator above. Its function and its one-row table go with it, both `if exists` because neither ever came from a
  migration and a project without the hack must still apply this file.

**Done when, at the database.** `dev/checks/step24-retire.sql` — one transaction, rolled back, its own simulation
event, five virtual groups (one per behaviour), a plan with four moments and a running simulation, and **no zones at
all**, so a leg pointing at a plan point cannot be the old movement-to-zone walk. **Section 2**: `sim_start` refuses
with no groups, refuses with no published plan, then starts the event on the plan — `plan_id` = the plan, `t0_at` =
the plan's own clock, no run sheet, the run "running". **Section 3**: each group's leg is its moment (SIM-001 a ~99 m
leg from where it stands; departure = 300 − path − 60), `late_2min` +120 s, `stops_halfway` half of *this* leg,
`loses_signal` 40 %/150 s, and `wrong_zone` untouched despite the plan stating a moment for it. **Section 4**: at
+5:10 the next moment takes over from where the group stood, at +10:10 the repeated position is not a new leg, and a
stopped group is not restarted. **Section 5**: a session with no plan is left alone. **Section 6**: one `sim_tick()`
re-aims a group whose leg was put back where it started and advances it. **Section 7**: the catalogue — the new
signatures exist and the old ones do not; **no function has a parameter called `p_run_sheet`**; **no body in `public`
names `show_tick`, `move_tick`, `zz_walk_tick` or `sim_plan_movements`**; those four functions and the `zz_walk` table
are gone; `cron.job` holds **exactly seven** jobs, each asserted by name, schedule, command *and the age of its last
success* — five minutes for the tick jobs, forty-five for the quarter-hour one, **two days for the daily one**, which
is the assertion finding 7 said a blanket "succeeded recently" would fail. **Section 8**: `authenticated` may call
the two start functions and not `session_engine`, `sim_follow_plan` or `sim_tick`; `anon` may call neither start
function.

**Done when, through the screen.** `dev/checks/step2-session-plan.sql` was rewritten to the new rule: its "both at
once is refused" is now "the run-sheet door is gone" — no three-argument `start_event`, and a real run-sheet id
handed in as `p_plan` is refused as "not in this event" from both the Start and the Schedule path, leaving no session
behind; a tracking-only start is still possible, with no clock and no sheet; and the old positive control (the ticks
still drive a run-sheet session) cannot exist any more, so it is replaced by the absence of those ticks plus
`push_collect_moves` still finding nothing to say about a plan. `node tools/run.mjs
dev/checks/step2-start-on-a-plan.mjs` is now **12 assertions**: the added one is the dialog's own copy
(`!/run sheet/i`), which the old screen really failed ("Run sheets must be Ready; plans must be published first"),
and the rest still prove the picker, the disabled draft, the confirm naming the plan, and "Running plan: Clean walk"
with no run-sheet machinery on screen.

![The Start dialog after step 24 — plans only, and the sentence that says so](shots/step24-start-dialog.png)

**Proven to bite, six times** (each restored, the check re-run green): the one-minute-early departure removed →
`FAIL 3e`; the `wrong_zone` guard removed → `FAIL 3k`; `sim_start`'s "published" condition removed → the check stops
on the plan engine's own "not published"; a function body naming `move_tick` added → `FAIL 7h`; `gps-plan-eta` moved
from 30 to 45 seconds → `FAIL 8c`; and the `sim_follow_plan` call removed from `sim_tick` → `FAIL 6b`.

**Found while doing it:** three findings (95–97). PowerShell's `Set-Content -Encoding utf8` is not the UTF-8 the
files are: reading a BOM-less UTF-8 file as ANSI and writing it back **double-encoded** a middle dot into `Â·` in
three checks, and the only symptom was step 21 failing on a body `LIKE '% m · about %'` and step 22 failing on an
"URGENT" string — a silent corruption that looked like a product regression, found by running the suite and fixed by
reversing the byte mapping and re-normalising the files to LF (95; the ten files the edit touched were all normalized
back). The `wrong_zone` assertion **passed trivially** the first time: with no plan moment for that group, "the plan
does not call it" was true whether or not the guard existed, and only giving the fixture a moment for it made the
bite fail (96 — R7 again, caught by trying to bite it). And `cron.schedule` on an existing name **replaces the job
with a new `jobid`**, so a rescheduled job has no run history: after the bite rescheduled `gps-plan-eta` the "last
success in five minutes" assertion failed for a few minutes, which is honest but means a cron change needs a minute
before the check means anything (97).

**The suite was re-run:** SQL checks 2–24 green (**23 files**, each on a rebuilt bench); browser board smoke **22**,
step 2 **12**, steps 4–13 **408** (24/47/44/37/49/29/43/29/36/70), step 15 **24** (2 tabs), step 16 **69** (5 tabs),
step 17 **44** (3 tabs), step 18 **42** (2 tabs), step 19 **32** (3 tabs), step 20 **18**, step 21 **15**, step 22
**23** (5 tabs), step 23 **43**; `npm run test:runsheet` **105** (the workbook is step 25's to delete), `npm run
test:sheet` **58**, PGlite **322**; `npm run build` clean (the chunk notice only); ledger **60 files, 60 applied, 0
pending, 0 drifted**. Two of the browser checks needed sessions the runner did not have — step 16 wanted
`.tmp/session5.json` (the marshal) and step 17 `.tmp/session3.json` — and step 6 failed once on a toast that never
appeared and passed on its re-run at 44 assertions: I could not reproduce it, and I would rather say so than call it
fixed.

**Owing.** The Run sheet tab is still there and can still be edited, checked and made Ready, but **nothing can run
it any more** — starting the event with a sheet is not a call that exists, so a planner who prepares one has no way
to use it. That is the interval step 25 closes by deleting the tab and the tables, and it is a real end-user
consequence of this step rather than a cosmetic one. (**Closed in step 25**: the tab, the editor, the workbook and the
tables are gone.) The simulator panel has **no browser check** (it needs a simulation event and a minted virtual
account), so the panel's plan name, its disabled Start and the vanished card are
proven by the build and by reading, not by a screen. `sim_start` picks the **most recently updated live plan**, and
nothing in the schema forbids two live plans for one event — publishing is per plan, so the choice is arbitrary in a
state the product does not prevent; a plan's own pace does not exist, so the virtual group keeps the 1.0–1.5 m/s it
was set up with rather than a speed the strip implies. `sim_setup` still requires a zone to start its groups from
(the first leg is random around a zone even though the plan takes over immediately). The `run_sheet_id` column, the
`session_run_sheets` function, `switch_live_run_sheet`, `move_step`/`show_step`, `push_collect_moves` and
`rs_runnable` are all still in the database with no caller left — precisely the inventory step 25 must drop without
`CASCADE`. And the run-sheet file test still passes because `runSheetFile.js` is still imported; step 25 removes the
component that uses it. (**Closed in step 25**: all of those objects are dropped without `CASCADE`, and
`npm run test:runsheet` is gone with the workbook it tested.)

**25. Drop the stack** — M, needs 24
The real inventory, from the catalogue — `movements`, `movement_status`, `movement_routes`, `run_sheet_switches`,
`run_sheets`, `cues`, `show_state`, `show_log` and ~8 components. (`session_run_sheets` is a **function**, and
`ic_moves`/`delays` **do not exist** — the earlier list was wrong.)
**Done when:** the migration **aborts rather than half-applies** if any function, view, trigger or cron job still
references a dropped object, asserted via `pg_depend` inside the same migration — and it must **not** use `CASCADE`,
which would "succeed" while silently dropping a referenced object.

**DONE.** `061_drop_run_sheet_stack.sql`. Step 24 closed the last callers, so this file could finally delete the engine
itself; what it took out is ten tables, sixty-two functions, one trigger, and **two columns on tables that survive**.

* **The inventory is the catalogue's, and it was bigger than the plan's list.** The plan named eight tables and "~8
  components"; the catalogue had **ten** tables — `show_cues` was missing from the list and `group_messages` (the ops
  board's note to one group, written by `message_group` and by nothing else) was not on it at all — plus the one
  trigger, and **`sim_groups.movement_id`**, a column on a table that survives which pointed at `movements`. A
  `drop table` would have failed on it, which is finding 3 being *completed* rather than corrected: the list in a plan
  is a hypothesis, and the catalogue is the answer. `session_run_sheets` is indeed a function, and `ic_moves`/`delays`
  never existed.
* **The guard is inside the migration, because the failure mode is a `drop table` that succeeds.** Postgres records in
  `pg_depend` what a view, a trigger, a default, a foreign key and a **function's return type** depend on — and not what
  a plpgsql body reads. `drop table movements` against a function that still selects from it succeeds, and the failure
  arrives on the next tick in production. So the file makes four assertions first, and any one aborts the transaction
  (which is the only way "abort rather than half-apply" is true): every object in the inventory exists (a stale list run
  against another database must fail, not no-op); no object outside the inventory depends on anything inside it (the
  `pg_depend` walk, through indexes and row types and then one step along normal dependencies, so an incoming foreign
  key, a view, a trigger on another table, a column default or a function's return type is caught, while an object
  hanging off a table this file drops is recognised as part of the plan); no surviving body and no `cron.job` command
  names any of it (the half `pg_depend` cannot see, and the half that would actually break); and the inventory is
  seventy-five objects long, because a guard that inspects nothing passes.
* **No `CASCADE`, and the same walk again as a post-check.** `cascade` would drop whatever was in the way and report
  success — the exact outcome the guard exists to prevent. Every drop names its object. Afterwards the file re-runs the
  `pg_depend` question **by oid**, so there is no second list to keep in step, and adds the two things worth knowing
  after ten tables go: the cron inventory is still exactly the seven jobs of step 24, and every remaining table still
  has row level security on.
* **Three survivors were rewritten rather than dropped.** `start_event` and `schedule_event_start` set the dropped
  column to null (part of their `create or replace` in 060; the line goes, the signatures and grants stay), and
  `broadcast_send` (032) wrote a `show_log` line when a show was running — a plan session has no show and a
  tracking-only session never had one, so the branch and its `show_state` probe go. `zones_guard_live` and its trigger
  are deleted: it refused to delete a zone that a **live movement** pointed at, and a plan's positions are lat/lng, so
  a plan never pins a zone to anything. What that stops guarding is recorded in the debts.
* **What survives that looks like it belongs here.** `show_who(uuid)` — a display-name helper the plan's broadcast and
  publish call; `push_collect_nogo` — the zone No-Go push the plan's tick still runs; the whole `plan_*` family;
  `handover_log`; the GPS recording playback (`playback_list`, `location_history`, `delete_recording`); and the
  event-wide message of 032. The last two are not the run-sheet engine and are the reason half this file is a guard
  rather than a list.
* **The client went in the same change.** The Run sheet tab and its editor (`RunSheetPanel`), the Excel import,
  `MovementEditor`, `ShowBar`, `ShowPanel`, `CueChips`, `OpsQueue`, `OpsDecision`, `OpsSummary`, `NextMoveCard`,
  `useRunSheets`/`useShow`/`useOps`/`useMyMoves`/`useGroupMessages`, `utils/opsStatus.js` and its stylesheet, the
  workbook `runSheetFile.js` (and `npm run test:runsheet`), the `route-eta` Edge Function — the only caller of
  `route_claim`/`route_save` — and the six legacy PGlite suites that tested the dropped functions. `EventView` loses the
  "open the classic run sheet" button, the show bar and panel, the ops queue and the member's next-move card; `?next=1`
  lands on the Schedule instead of scrolling to a card that no longer exists; the map loses its ops clusters and status
  rings; Playback loses its "Ran with" line; the Zones card loses its per-zone movement count; and the Start
  dialog's copy is unchanged because step 24 had already made it plan-only.

**Done when, at the database.** `dev/checks/step25-drop.sql` — one transaction, rolled back. **Section 1**: the ten
tables are absent **by name**, `event_sessions.run_sheet_id` and `sim_groups.movement_id` are gone, and the tables that
survive are still there (a drop that took too much would pass the first three assertions). **Section 2**: all
sixty-two functions and the zone trigger are absent, and the helpers that are *not* the stack — `show_who`,
`push_collect_nogo`, `plan_ops`, `plan_push_tick`, `session_timetable` — are still there. **Section 3**: no surviving
body in `public` and no `cron.job` command names any retired object, and the scan is **proved not vacuous** by finding
a name that is still in use. **Section 4**: as the bench's root, `start_event` starts a tracking-only session (no plan,
no clock) — which is what proves the rewritten body stopped writing the dropped column — `broadcast_send`'s dry run
answers and writes no broadcast row, and `plan_frames_list` still opens the bench board. **Section 5**: the cron list
is the seven of step 24, every table still has RLS, and no function name still starts like the retired engine
(`show_who` is the one exception, by name). **Five bites**, each refused with the offender named: a foreign key from
`events` to `run_sheets` (`constraint events_bite_sheet_fkey`), a view over `cues` (`view bite_cues`), a function that
reads `movements` (`bite_reads_movements`, which `pg_depend` cannot see — the body scan catches it), a cron job running
`move_step` (`zz-bite-61`), and the migration applied twice (`no such table in public: movements, ...`).

**Done when, through the screen.** `dev/checks/step25-gone.mjs` — ten assertions over four tabs, and every one of them is
about something that used to exist and must not come back: on the Timeline the page mentions **no run sheet at all** and
the plan board is what it shows; on the Live page there is **no show bar and no ops queue**, the map has **no cluster
hint and no clusters toggle**, the map itself is still there, and the table that tells the staff where their groups are
is `plan_ops` with all three of step 20's groups on it; on Playback there is **no "Ran with" line** and the recording is
still listed; on the Zones card there is **no movement count and no mention of the run sheet**, and the event's zones are
still listed. Each absence is paired with the thing that is there instead, so a page that failed to render cannot pass.
A check that asserts an absence is only worth keeping if the absence is what the step sold, and that is why it asserts
the replacement too. The rest of the suite is green after the deletions (see below), and the screenshots are the review's
evidence: `shots/step25-live.png`, `step25-timeline.png`, `step25-playback.png`, `step25-zones.png`.

**Found while doing it:** five findings (98–102). The `pg_depend` walk does not see plpgsql bodies at all, which is the
finding this step is really about and the reason the guard also scans `prosrc` (98). `create or replace` cannot remove a
parameter default, so replacing `broadcast_send`'s body failed until its two defaults were restated (99). The first
guard run reported nine `pg_policy` rows as "dependents outside the plan", because a policy depends on its table
normally even though `drop table` removes it — the walk had to learn that an object hanging off a table in the plan is
part of the plan (100). A second application of the file failed on the scratch table's name rather than on the
inventory, which made the one error a developer will actually see worse than the one it was hiding; `drop table if
exists pg_temp._target` fixes the message (101). And the `Â·` "corruption" that looked like it had spread beyond step
24's ten files was a **reading** artefact — PowerShell's `Get-Content` without `-Encoding UTF8` renders a clean middle
dot as `Â·`, and the only real mojibake left in the repository was an em dash in `step3-group-scope.sql`'s comments;
finding 95's trap has a second face, and a scan for corruption has to read bytes through node (102).

**Suite.** SQL checks 2–25 green (**24 files**, each on a rebuilt `plan_bench.sql`); browser board smoke **22**, step 2
**12**, steps 4–13 **408**, step 15 **24** (2 tabs), step 16 **69** (5 tabs), step 17 **44** (3 tabs), step 18 **42**
(2 tabs), step 19 **32** (3 tabs), step 20 **18**, step 21 **15**, step 22 **23** (5 tabs), step 23 **43**, step 25
**10** (4 tabs);
`npm run test:db` **322**, `npm run test:sheet` **58**, and `npm run test:runsheet` is **gone** with the workbook it
tested (its 105 assertions died with `runSheetFile.js`); `npm run build` clean.

**Owing.** Zone deletion is no longer refused while an event is live: the guard existed because a live movement pointed
at a zone, and a plan's positions do not, so a planner can now delete a zone mid-event and its alerts and presence rows
go with it (`on delete cascade`) — a live-event guard for zones is a product decision, not a leftover to keep. The
`route-eta` Edge Function's **source** is deleted but the deployed function must be removed in the Supabase dashboard
(a migration cannot), and `send-reminders` is now the only one. The ops board that a marshal used to read (queue,
filters, clusters) is gone for run-sheet sessions by construction and has no plan equivalent on the map: `PlanOps` is a
table of moments, not a drawing, so "zoomed out, one bubble per zone" has no replacement and its disappearance is a
product loss worth naming. `show_who` still carries a `show_` name for a helper the plan uses. And the debts below
that name a row or a function that no longer exists are closed by this file, not fixed.


---

**26. A row says where the moment is** — M, needs 16 — **DONE** (062).

**The model this serves, restated because the step is small and the model is not.** A moment is a point. A point
inside a zone is a **place** — "be at Main Gate by 7:40" — and a point outside every zone is a **route point**: it
exists so the map can draw the walk and so nobody thinks the group went through a wall. Nothing is refused for
standing in open ground; a walk may cross the whole venue. The member's schedule says the place. That is the whole
of this step, and it is worth having because a follower used to read "6:45 pm · doors" with no answer to "where".

**What now exists.** `session_timetable` gains a trailing `place text`: the name of the zone the moment's own drawn
point stands in, or null. It is a **drop and re-create**, not a `create or replace`, because the return type changed
(R2, the same dance 052 did for the same reason), the body is **057's** (R8) with the deleted-plan guard intact, and
both grants are named again (R4). The lookup is 057's own convention — stage first, then an entrance, then any other,
then the name — **copied rather than reinvented**, because two functions answering "the zone this point is in"
differently is the kind of second opinion this plan keeps refusing (finding 48). Two kinds are excluded: a
**no-go area** and an **obstacle** are zones, but "be at Store room (no-go)" is not an instruction anybody can
follow, so a point inside one answers null. An **off-site** moment is not a place either, even when the excursion
keeps a coordinate inside a zone. And a **carried frame has no point at all**, so it has no place: the plan does not
say the group is somewhere at that frame, it says the previous statement still stands. The client is one span with
its own testid and one CSS rule, placed between the state word and the detail so a row reads `7:40 · due · Main Gate`.

**Fixture.** `step16-schedule-prep.sql` gained three zones — the dock, the stage and the main gate — because its
event had none, so every row would have said nothing and the screen proof would have been vacuous. The three steps of
Gate Crew's walk stay outside all three, so the same screen shows the placed and the unplaced case.

**Done when, at the database.** `dev/checks/step26-place.sql` — one transaction, rolled back, twelve assertions. The
read answers **eighteen rows** (three groups × six frames); Gate Crew's call answers **Main Gate**; a carried frame
answers **null**; a route point answers **null** *and* is proved to stand in **no zone at all**, so the null is not a
point in open ground that would have been null anyway; the stage point is proved to stand in **two** zones before the
read is asked which, so the tie-break is exercised and not assumed; the answer is **Stage**; a point inside the no-go
area answers **null** and is proved to stand in **exactly one** zone; an off-site moment whose coordinate is inside
the stage answers **null**; and the same read through a **member's own door** still answers **Stage** (six rows). **Two bites**, each
restoring the file afterwards: dropping the kind filter makes it fail `FAIL 1g: a point inside a no-go area answered
the place Store room (no-go)`; dropping the `state = 'on_site'` condition makes it fail `FAIL 1h: an off-site moment
answered the place Stage`.

**Done when, through the screen.** `dev/checks/step26-place.mjs` — twelve assertions over two tabs. Sound's member
reads `Sound Dock`, then nothing (off site), then `Stage`, then nothing twice (carried), with the five state words
**unmoved** — a place that displaced a word would be a regression this step could otherwise hide. The page is proved
to have asked `session_timetable` **and** to have made **zero** requests for the plan's frames or positions, so the
place came from the one read and not from a lookup the member's screen is not allowed to make. The marshal's tab then
shows both groups on one frame saying **different** places (`Main Gate` / `Sound Dock`), which is what makes this a
row-level fact rather than a frame-level one. Evidence: `shots/step26-member-place.png`,
`shots/step26-marshal-place.png`.

**Found while doing it:** three findings (103–105). `my_schedule` **never existed** — the name came from the 052
filename and had travelled into this plan's step list, where it read as a function (103); a name invented in a
conversation can survive a document and then a search that finds nothing, so step names are checked against the
catalogue before they are used. **057 already answered this question twice** (`plan_collect_pushes` and
`plan_eta_tick`) and answered it with no-go areas included, so copying the convention for a *label* meant inheriting
"be at Stores (no-go)"; the ordering is shared and the kinds are not, which is worth knowing before a third copy
appears (104). A **thirteenth column is safe only because every consumer reads by name** — there is no positional
destructuring anywhere in the client or the checks — while three assertions pin exact text in three elements, so the
new fact needed its own element and its own testid rather than being appended to the detail line (105).

**Suite.** `step26-place.sql` **12**; the timetable's neighbours re-run green: **step15-timetable**, **step16-schedule**,
**step17-fork** (with its prep), **step22-log-targeting**, **step23-import** (with its prep); browser **step16** 69
(5 tabs) and **step17** 44 (3 tabs) unchanged, so the extra span broke no exact-text assertion; **step26** 12 (2
tabs); `npm run test:db` **322**; `npm run build` clean; ledger **62 files, 62 applied, 0 drifted**.

**Owing.** The place is a **name and nothing else**: a route point is silent, so a planner cannot label one "the corner
of the road", and a member cannot tell a walk from a gap. A **carried frame is silent too**, even though the group is
still standing wherever the last statement put it — the read reports what the plan states at that frame, not where the
group is, and carrying the point forward would be a second copy of the walk 051 owns. **Overlapping zones resolve by
kind then name**, so two zones of the same kind covering the same point resolve alphabetically, and nothing tells a
planner their zones overlap. The **ops board still identifies a moment by its numbers**: `plan_ops` returns
`plan_lat`/`plan_lng` and no place, so a marshal reading the table sees the walk's midpoint rather than the name —
giving it one is a second `drop`/`create` of a 26-column function, and a decision rather than a fix. And the state
chip and the place now sit side by side and read as one phrase ("ARRIVED Sound Dock"); a long zone name pushes the
detail onto a second line, which is legible but not designed.

**27. Arrival by distance, per IC** — M, needs 21 — **DONE** (063).

**The model this serves, in your words.** "The planner is the one who plans routes by creating new frames; the map's
line between two moments is indeed the path." On the member's end the timeline says what time to be at which zone and
the map draws the route; the intermediate moments **are** the route and nobody is judged for cutting a corner, though
a marshal may confirm one. "What really matters is if they are in their zone by the planned time." On the ground that
is a **distance**: "we calculate reached a moment as distance from planned latlng to actual latlng (let planner
configure)". 057 could only close a moment when an IC stood inside the polygon the point was drawn in, which is a
claim about a drawing, not about a phone in a crowd.

**What now exists.** `group_members` gains **`ic_tolerance_m`** — `integer not null default 30`, `check (between 5 and
100)`. It lives on the membership row because that row already says "this person, in this group, at this event": one
radius per IC per event, no new table, and 002's read policy already lets the event's people read their own. The CHECK
is the band's real door — nothing can store 4 or 400, whatever a function forgets to ask. **`set_arrival_tolerance(
p_event, p_metres, p_user default null)`** is the only writer (R3: `group_members` has a read policy and no write
policy anywhere), security definer, and it admits the same three callers 050's `progress_mark` admits: the person
themself, the event's root or planner, and the group's own admin. It refuses a person who is not an IC ("only an IC
shares a phone, so only an IC has an arrival radius") and answers the metres now in force.

**`plan_auto_close` is re-created from 057's body** (R8, `create or replace` — its signature did not change, so its
grants from 057 stand: revoked from everyone and run by the tick as its definer). Two things changed and nothing else:

* **the place gate is kept, and narrowed to a place.** A moment may close itself only when its drawn point stands in a
  zone of the kinds 062 calls a place — `zone`, `stage`, `entrance`. That is what keeps a **route point** from closing
  (a phone passing within thirty metres of a corner is not an arrival), and it means a moment drawn inside a cordon now
  waits for a tap, so "somewhere to have arrived at" answers the same way in the read and in the tick (finding 104).
* **the evidence is a phone as well as a polygon.** For each IC of the group: inside a zone containing the point
  (057's test, unchanged) **or** within *that IC's own radius* of the point. The distance test is the live map's, not a
  new one (021): a reading older than **two minutes** or worse than **100 m** is not evidence, and the radius is
  widened by **`min(accuracy, 15)`** exactly as 021 widens a zone's edge. `locations` carries no session id, so the
  window is also bounded by the session's own `t0_at` — a reading from before the clock the group was told says where
  somebody was, not that they are here — and `source = 'stop'` is not a position at all. The **earliest** evidence
  dates the arrival and `marked_at = greatest(planned, first)` (057's expression, unchanged), `marked_by` null.

**The screens.** The IC's own number is on **"My GPS details"** — a card under the database status: *"Your group counts
as arrived at a moment when your phone is this close to its point — or anywhere inside the zone it stands in"*, a box,
`metres`, Save, and the database's sentence in red when the number is outside the band. The planner's is on the
event's **People** page: ICs get a `Radius` box beside their IC switch, the group admin who does not share a phone does
not, and a change is toasted in words ("testuser4 now counts as arrived within 25 m."). `useEventData` carries
`toleranceM` on each member so both screens read the same row.

**Fixture.** `step27-tolerance.sql` builds its own plan on the bench event: **eight frames ten minutes apart**, Gate
Crew walking due east 20.59 m a step (so every step is legal and the strip's only subject is the tick), a **Gate** box
round the first moment, a **Crossing** lane over the third to the seventh, and a deliberate **gap** with no zone for
the second — the route point. It publishes through the product's gate and starts a real session through
`start_event()`, then stands at chosen seconds with readings it wrote itself. The no-go cordon for the last section is
added **after** the publish, because a walk that ends inside a cordon is a crossing the publish gate refuses.

**Done when, at the database.** `dev/checks/step27-tolerance.sql` — one transaction, rolled back, **41 assertions**.
**A**: every membership row carries 30 m, and 4 and 101 are refused by the column itself. **B** (thirteen): the door —
the IC sets their own (and the row says so), 4, 101 and null are refused through the function, a person who is not an
IC is refused **even by themselves**, an admin of *another* group is refused, one IC cannot set another's, the same
call goes through once the caller is made that group's admin, an outsider is refused, a client cannot call the tick,
the planner sets both numbers the check then stands on, and the anon key cannot execute the function at all. **C–D**:
an IC at **distance 0** ten seconds before T+0 closes **nothing**; the same IC at 25 m closes nothing through a **5 m**
radius and closes the moment through **30 m** — same reading, same second, one changed number — dated to the reading
and marked by nobody. **E**: an IC standing exactly on the route point closes nothing, and the point is first proved to
stand in **no** zone. **F**: two ICs of one group, 30 m and 100 m; the same 60 m reading is refused through the first
(whose number is re-read in the same breath) and closes the moment through the second. **G**: a five-minute-old reading
is refused, a 200 m accuracy is refused, and a 40 m reading with a 30 m radius and 20 m accuracy **counts**, because
`30 + min(20, 15) = 45`. **H**: 057's zone branch still closes — with no reading at all — and dates the arrival to the
plan, not to the IC's early entry. **I**: `manual` stays open with the IC on the point. **J**: the same person at the
same distance, no longer an IC, closes nothing. **K**: a moment drawn in a cordon stays open, the point first proved to
stand in exactly one zone. **L**: four moments closed in all, and no others.

**Proven to bite, four times** (each restored by re-applying 063; the ledger then showed 0 drifted). Dropping the
kind filter from the gate → `FAIL K2: an IC standing in a no-go area closed 1 moment(s), expected none`. Dropping the
session-start bound → `FAIL D1`. Replacing `gm.ic_tolerance_m` with a constant `30` → `FAIL C1`. Dropping the zone
branch from the evidence query → `FAIL H1`.

**Done when, through the screen.** `dev/checks/step27-radius.mjs` — **17 assertions over three tabs**. The IC's page
opens on the radius the row carries, saves a new one (worked out from what it found, so a repeat run proves the same
thing), the call is proved to have gone to the database, and a **reload** still reads the new number — the row, not the
box. `4` is then refused and the check asserts the message is the **server's** sentence ("An arrival radius is between
5 and 100 metres, not 4."), excusing exactly one HTTP 400. The planner's People page shows that same number, has a
radius control for **both** ICs and none for the group admin, and a change made there comes back from a re-read of the
list. A third tab (a group admin who does not share a phone) has no card and no box at all. Evidence:
`shots/step27-ic-radius.png`, `shots/step27-ic-refused.png`, `shots/step27-planner-radius.png`.

**Found while doing it:** three findings (106–108). The first version of the **session-start assertion could not
fail**: its reading sat exactly on `p_at - 2 minutes`, the comparison is strict `>`, and the window's own edge excluded
it whether the T0 bound was there or not — so the check passed for a reason that had nothing to do with the rule it
named (106). A reading placed ten seconds before T+0 made the bite appear. **A cordon cannot be reached by a legal
walk**, so the no-go assertion had to add its zone after the publish: the publish gate refuses a crossing, and the
assertion is about the tick, not about the gate (107). And the plan itself said `auto` was "about the DRAWN POINT, not
about the phones" — true of 057, half-false from this file on, so step 21's paragraph is amended where it stands rather
than left to contradict the code (108).

**Suite.** `step27-tolerance.sql` **41**; the plan's own neighbours re-run green: **step14-actuals**,
**step15-timetable**, **step16-schedule** (with its prep), **step17-fork** (with its prep), **step21-push-handover**
(with its prep), **step22-log-targeting**, **step23-import** (with its prep), **step26-place**; browser **step16** 69
(5 tabs), **step17** 44 (3 tabs), **step21** 15 (1 tab — the tick that closes a moment by zone still closes it),
**step27** 17 (3 tabs); `npm run test:db` **322**; `npm run test:sheet` **58**; `npm run build` clean; ledger **63
files, 63 applied, 0 drifted**.

**Owing.** The radius is **not on the ops board**: a marshal sees a group that has not closed itself and cannot see why.
**Two ICs of one group each have a number and the first one close enough wins**, so a group with one tight and one
loose IC is judged by whichever is nearer, and nothing on any screen says so. **A radius is per event, not per venue**:
two events at one venue copy nothing between them, so a planner sets it twice. Nothing **tells an IC** that a planner
changed their radius — the change is a toast on the planner's screen only — and the IC's card does not say **who** last
set it. The **planner's box has no sentence**: the IC's card explains what the number does, the People page's label says
only `Radius`, so the explanation is on the other person's page. The IC's own card **leaves a refused number in the
box**: the message is right and the row is unchanged, but the field still reads 4 until it is retyped. A moment drawn
inside a **no-go area can now never close itself**, which is the intended reading of "not a place" and a surprise for
anyone who meant "a staffed gate inside a closed area" — that has to be a second, plain zone. And the **100 m ceiling
is a judgement, not a measurement**: the band is a product decision (5 m is below any honest fix, 100 m is where "here"
stops meaning anything in a crowd) and nothing in the system tests it against a real venue.

**28. The IC's own "we're here" press** — M, needs 21 — **DONE** (064).

**The gap this closes.** `progress_mark` (050) has admitted the group's IC and its admin since the day it was written,
but the only client caller was the ops board — and the ops board is mounted only for root, planner and marshal
(`EventView.vue`'s `seesWholeEvent`), exactly the three roles the function exempts. Half of its role check had never
been reached by anything: the door was real and no screen knocked on it, and the guard the earlier plan asked for ("a
second person must not replace a mark") would have protected a case that could not happen. So this step is the screen
first: the timetable step 16 gave every member offers its IC **one** press — "We're here" on the moment the clock is on
— and the guard comes with it, because now two people marking is a real thing.

**What now exists — the screen.** `PlanSchedule.vue` gains a `canPress` prop, passed as `isIC` from `EventView`; the
press is rendered on the row whose state is `late` (050's word for "its time has come and nobody has said anything")
and only on the moment the clock is on (the last one whose time has come), so the moments ahead and the off-site ones
offer nothing. Pressing calls **`markProgress`** in `usePlan` (one `progress_mark` call), then re-reads: the row the
database reports is the one shown, never a mark guessed by the browser. A refusal keeps the database's sentence. The
ops board says which writer closed a moment — `marked_auto` (064) rather than a missing name — and a write's error is
**sticky**: `PlanOps` used to clear `errorMsg` on every successful five-second poll, so a sentence saying why a mark
was refused was wiped before anyone could read it, and a refused mark left the stale row's buttons in place; both
screens now keep a write's error until the next write (or a dismiss) and the ops board re-reads after a refusal.

**What now exists — the door.** `plan_progress` gains **`marked_auto`** — `boolean not null default false`, true only
for the tick's own close. It exists because a null `marked_by` already meant three things (the tick, a deleted profile,
a repair) and the FK is `on delete set null`: deleting a person silently turned their mark into the tick's, which the
board read as "the phone was there" and which the new guard would then let anyone overwrite. The one-time backfill is
the truth for older rows — until this file only the tick left the name null. **`progress_mark`** is re-created from
050's body (R8, `create or replace` — the signature is unchanged) with one guard between the T+0 check and the upsert:
when a row exists, it is not the tick's, its author is not the caller, and the caller is not the event's ops, the call
is refused with *"<name> recorded that moment already, at <time>. Ask the event's ops to change it."* — the name from
`show_who` and the time from `sg_hms`, the two helpers 026 and 028 already ship. The maker may correct their own, the
event's ops may correct anything (that is what ops are for), and an automatic close is nobody's statement, so any hand
may correct it. `plan_auto_close` writes `marked_auto = true` (063's body, one column), and `plan_ops` answers the
column (a DROP + CREATE, R2, because the return type changes).

**Fixture.** `step28-mark-guard.sql` builds its own event: two ICs in one group, an admin in the other, a plan whose
printed T+0 is seventy seconds ago, and a stage box round Gate Crew's +1:00 point. A reading on that point lets the
tick close the moment, which is what the "a hand may correct the phone's close" section stands on.
`step28-here-prep.sql` is the browser bench: a live plan at +0:00 / +5:00 / +10:00 with T+0 a few seconds old, Gate
Crew's IC on the moment with **no reading at all** (so only the press can close it), and Sound's IC standing on its own
+0:00 point so the deployed five-second job closes that one by itself.

**Done when, at the database.** `dev/checks/step28-mark-guard.sql` — one transaction, rolled back, **32 assertions**.
**A**: `marked_auto` exists, is `not null`, defaults false. **B**: the IC's own press names them and is not flagged
automatic. **C**: a second IC is refused, the sentence names the marker and the time, and the row is unchanged. **D**:
the maker may correct their own, dated to the instant they give. **E**: the group's admin may record its own group.
**F**: an IC of another group still gets the role sentence, not the guard's. **G**: the tick closes Gate Crew's +1:00
(and only it), with no name and the flag set. **H**: a hand may correct that close, and the row then names the person
and stops being automatic. **I**: a person's mark whose profile is gone (name null, flag false) is still refused —
"someone recorded that moment already" — which is the bug the flag fixes. **J**: the event's ops may correct anything.
**K**: `plan_ops` answers `marked_auto` and the mark in force. **L**: the timetable carries the mark, and the IC still
sees only their own group.

**Proven to bite, four times** (each restored by re-applying 064; the ledger then showed 0 drifted). The guard never
fires (`v_prev.marked_auto is null`) → `FAIL C1: a second IC replaced the first IC's mark`. Protect only rows that
still carry a name → `FAIL I1: a mark whose author is gone was treated as the tick's and replaced`. No ops bypass →
`FAIL J1: the ops correction was refused: someone recorded that moment already...`. The tick not flagged
(`null, true` → `null, false`) → `FAIL G2: the tick's close is not flagged automatic`.

**Done when, through the screen.** `dev/checks/step28-here.mjs` — **23 assertions over four tabs**. The IC's schedule
offers exactly one press, on the +0:00 moment and not on the +5:00 one; pressing it writes `progress_mark` (the
browser's own resource timings), the row turns "arrived" and records when, and the press is gone afterwards. A
**reload** finds the same row, so the mark is the database's. The group's **second IC** opens the same page and reads
the moment already recorded, with nothing to press. The planner's ops board says **"Arrived … · by hand"** for Gate
Crew's press and **"Arrived … · the phone was there"** for Sound's tick, and neither recorded moment offers
the Arrived/Missed buttons. Evidence: `shots/step28-here.png` (the press on the row), `shots/step28-arrived.png` (the
row after it) and `shots/step28-ops.png` (the two writers, side by side).

**Found while doing it:** findings 109–113. The guard was **dead code** until this screen existed (109). Adding it
**broke step 17's §8**, which had Gate Crew's IC overwrite the hand-over mark; the section now proves the refusal first
and then has the event's root correct it — the documented correction path, and a stronger assertion than before (110).
The ops board's **poll wiped a write's error** within five seconds, and a refused mark left its buttons on a stale row
(111). `marked_by`'s null was **three meanings**, which the flag separates (112). And one more was found by writing
064 and is **not fixed here**: `progress_mark`'s comment has always claimed that a moment "that has not happened yet
cannot be recorded", but only the `p_at` is checked — a frame in the future can be recorded with `p_at` defaulting to
now and reads as an early arrival (113; the trap is `plan_publish`'s hand-over, which marks the anchor on a session
whose clock may not have started).

**Suite.** `step28-mark-guard.sql` **32**; the plan's neighbours re-run green: **step2-session-plan**,
**step3-group-scope**, **step4-frame-id**, **step5-fill-gap**, **step11-geometry**, **step14-actuals**,
**step15-timetable**, **step16-schedule** (with its prep), **step17-fork** (with its prep, amended),
**step20-ops**, **step21-push-handover**, **step22-log-targeting**, **step23-import** (with its prep),
**step26-place**, **step27-tolerance**; browser **step16** 69 (5 tabs), **step17** 44 (3 tabs), **step21** 15 (1
tab), **step27** 17 (3 tabs), **step28** 23 (4 tabs); `npm run test:db` **322**; `npm run test:sheet` **58**;
`npm run build` clean; ledger **64 files, 64 applied, 0 drifted**.

**Owing.** The press is the **IC's only**: `progress_mark` also admits the group's admin, but the admin's timetable has
no press — and no screen offers a "we were not here" (missed) press to anyone but the ops board. The **refusal cannot
be staged in the browser** (two people and one stale screen, one browser profile), so the guard's sentence is proved at
the database and not through the interface. The ops board still has **no "change this mark" control** — ops can correct
through the API, not on the screen — and it still reports the marker as a **uuid**, so it cannot name the person whose
mark it is showing. The **future-frame hole** (113) is the next thing on the door. And the hand-over marks the anchor
in the **publisher's** name, so the IC can no longer correct an anchor it disagrees with: the guard working as
intended, with "the publisher or another ops hand" the only correction path.

---

## Coverage

| Asked for | Step |
|---|---|
| Undo and redo, keyboard delete | 13 (done) |
| Locked map, frames, 25 m rule | done |
| A walk that clips a no-go zone; a pace beyond running | 11 (done) |
| Cumulative impossibility, whole stretch flagged | 12 (done) |
| Copy/paste, fill a gap, chunk shift, hold | 4–7 (done) |
| Move several groups at once, in one write | 8 (done) |
| Fill an impossible stretch in one call | 5 (done) |
| Push a stretch of frames; select a run; step between close frames | 6 (done) |
| Hold one group where it stands, until a later moment | 7 (done) |
| Per-group-per-frame verification, bulk toggles | 10 (done) |
| Off-site positions, ignored by every check | 9 (done), 10 (done) |
| Off-site groups; members see only their own | 3 (done), 9 (done), 10 (done), 16 (done) |
| Actuals: arrived/missed per group per frame, lateness from `t0_at` | 14 (done) |
| Own timetable; live clock | 15 (done), 16 (done) |
| Fork, edit ahead, republish, versions | 17 (done); 18 (done); 19 (done) |
| Weighted midpoint, ops status, travel time from the strip | 20 (done) |
| Auto-closed frames, plan pushes and ETAs, hand-back log | 21 (done) |
| Targeted broadcast, single ack, playback | 22 (done) |
| CSV | 23 (done) |
| Old stack gone | 24 (done), 25 (done) |
| A timetable row says where the moment is | 26 (done) |
| A moment closes when the IC's phone is close enough, at a radius the IC or the planner sets | 27 (done) |
| A mark belongs to the person who made it, and the IC can say "we're here" from their own schedule | 28 (done) |

**Out, by your decision:** named states / waypoint hierarchy · undo across a publish boundary.

## Carried debts

The seeded plan is disposable test data; `dev/preview.js` is a development tool, not product; `shiftFrom` in
`planFrames.js` is **gone** — nothing ever called it, and its per-frame clamp at zero would have compressed a chunk
onto T+0 instead of refusing to move it (step 6 does the clamp on the delta, and the server does the refusal); the
step-4 `copyFrame` was replaced by `snapshotAt`, which is live, and `subdivide` went in step 5 when the merge moved
into SQL; mobile has not been re-checked since the class rename.
**New from step 2:** the push path has no plan-session check and no test with real movement (step 21);
`event_sessions.t0_at` is set only when a session is started, so a plan's T+0 moved after the start does not move
the session's clock — **decided in step 15**: that is the intended order, a running session's clock is the one
people were told and `session_timetable` never consults the plan's printed date/time. **Answered in step 17:** a
copy taken mid-walk carries the original's T+0 and publishing it moves the running session onto the copy **without
moving the clock**, so a republished plan still cannot move a running event's zero point; a planner who edits the
copy's printed T+0 changes a display hint, and the session keeps the clock it started on until it is started again.
**New from step 3:** a member could read an unpublished plan's frames and notes at the database until step 16
replaced the member read path (finding 23) — **closed in 052**, and its browser half moved to step 16's check
because the board it asserted is no longer a member's screen. What remains is only the bench's habit: a check that
publishes "Clean walk" leaves the bench "live plan present", so a later check that expects the fixture's own state
has to rebuild it.
**New from step 4:** the browser check leaves a pasted frame in "Copy bench", so the bench is three frames there
after a run and `step4-frame-id.sql` refuses to start until `plan_bench.sql` is rebuilt (its guard says so). The
client-id create path spent nine steps proved at the database with no product caller; step 13's undo stack is the
caller it was built for (a restored delete and a redone paste both name their id). `frame_save` still refuses to
*move* a frame between plans, which is the behaviour undo relies on.
**New from the keyboard work:** a real Ctrl+C sent through CDP wedges this sandbox's headless browser (the copy
command reaches for the OS clipboard and the renderer blocks), so `dev/checks/shortcuts.mjs` sends the key as a DOM
event and cannot prove the platform's delivery of a physical Ctrl+C — see step 4. Ctrl+Z was left without a handler
until step 13, which added it, and a trusted Ctrl+Z *does* arrive without hanging anything: undo and redo are proved
by real presses, so only Ctrl+C carries that debt.
**New from step 5:** the browser check leaves the walkthrough filled (14 frames) and "Twin gap" filled (10), so both
SQL checks and every later browser run need `plan_bench.sql` rebuilt first — their guards say so. Filling is refused
when a group already stands in the middle of the stretch, so a stretch with a deliberate midpoint has to be filled in
two halves; that is the rule that keeps the operation from overwriting a decision, and it is worth a planner-facing
sentence on the button later. The fill sizes steps at 24 m, so a generated strip can hold more frames than a
hand-drawn one; a planner who wants fewer has to move the ends closer instead. `frames_fill` has no keyboard
shortcut — it is one button per warning, and the button is the only way in.
**New from step 6:** the browser check leaves "Push bench" at 0/5/7/8, so a second run needs `plan_bench.sql`
rebuilt (its first guard says so). **A push is undoable now** (step 13): one Ctrl+Z puts the stretch back, by its two
times when the moved range still holds exactly the frames it moved, and one frame at a time by id when a frame that
stayed put has ended up inside that range — the case 044's crossing rule makes possible, proved in
`dev/checks/step13-undo.sql` and through the screen. **"Push the rest" has no control**: the ripple form (`p_to_s`
null) is still in the function and nothing in the UI asks for it, so pushing everything after a moment means selecting
to the end of the strip with Shift+click first; that is one rule instead of two, but it is two gestures instead of one,
and step 8 or 13 should decide whether it earns a button. A bounded push that crosses a frame that stays put
**reorders the strip**, which can turn a legal plan into one with gaps — visible, and undoable now, but a planner who
does not notice both facts has a plan that no longer reads as it did. The group ticks in the inspector first only
dimmed the map; step 8 gave them a meaning (they are the groups a drag moves together) and step 10 adds verification.
A sweep across the bar does not auto-scroll, so a strip wider than the window is swept in more than one pass.
**New from step 7:** the browser check leaves "Copy bench" at 0/1/5, so a second run needs `plan_bench.sql` rebuilt
(its first guard says so). **A hold is undoable now** (step 13): the command holds the later frame as it stood before
the call, or the id of the frame the hold invented, so one Ctrl+Z puts that frame's own map back — or takes the
invented frame away again. The "a group that moves before then" rule is deliberately strict, and it has a consequence
worth knowing: holding a group *through* an existing statement is refused, so "hold until the end of the run" means
either holding from the frame the group last moved at, or pushing the frames in between later first (step 6) — the
sentence names the frame, but it is two gestures. The hold has no keyboard shortcut (it is three buttons, one per
duration, in the inspector). The group ticks now do two things — narrow a hold and step the map back — and steps 8 and
10 add two more; if that gets crowded, the ticks should become a selection *mode* rather than a fourth meaning. A hold
is a statement about place, so it carries no note, and the strip's dot for it looks like any other empty frame.
**New from step 8:** the browser check leaves "Copy bench" at +0:00 with a 71 m hop, so a second run needs
`plan_bench.sql` rebuilt (its first guard says so). **A drag is undoable now** (step 13), and it is the gesture that
needed it most: a marker that slips 2 px is a 1 m edit written to the plan with no confirmation, and one Ctrl+Z takes
it back — the frame's whole position map, so a group the frame did not state stays unstated and the step 12 budget sees
what it saw. **A drag is pointer-only**: there is no keyboard nudge, so a planner who cannot use a mouse cannot move a
group at all, and step 10's bulk toggles will not help with that. The **ticked set does not survive a reload or a plan
switch**, which was harmless when the ticks only dimmed the map and is not harmless now that they decide what a drag
moves: after a reload the sentence says "drag a badge to move that group", so it is not silent, but the planner's set
is gone — and it is the one thing about this screen that a reload *does* keep for undo (the stack) and not for
selection. Grabbing an **unticked** badge while others are ticked moves only it; the sentence names the movers, so the
words and the picture agree, but if that turns out to read as a bug the fix is to make the grab replace the ticks. A
ticked group that stands nowhere at the open frame is dropped from the drag without saying so beyond not being named.
Nothing snaps: a drag is freehand, and there is no readout of the distance while dragging (the toast reports it
afterwards), no alignment guides and no clamping to keep a step inside 25 m — the plan reports the break instead, in
the same red it uses for every other break. Dragging carries positions only: it cannot move a group to *another* frame,
which is what "hold" and "fill" are for.
**New from step 9:** the browser check needs `dev/checks/step9-off-site-prep.sql` (it leaves "Off-site twin" in the
bench; the file is idempotent and a bench rebuild removes it, and it sorts last so nothing opens differently).
**Step 10 closed the rest of this list**: it added the toggle, the confirmation chips and the bulk writes, replaced
the hollow badge with **one fewer marker**, broke the dashed track at an off-site point (drawing the runs between
on-site statements), made the map's fit ignore off-site coordinates, and gave `verify` its first reader. What is
still owing from this step: `frames_fill` still interpolates between its two ends without looking at their flags, so
filling a stretch that ends off site writes on-site points along a line nobody walked — it should refuse or skip
those groups when the fill button is next touched. And because an off-site excursion is invisible to the 25 m rule by
design, a published plan can contain a group that "teleports" while it is off site: the rule guarantees the walk
between the statements it can see, not the trip nobody can see. `positionAt` (the live view's interpolation, so far
unused) would slide a group through its off-site point; step 20 or 22 should decide what a play scrubber shows for a
group that is not there.
**New from step 10:** the board's state controls write **the open frame**, not the selected stretch: "off site" is a
statement about one moment, and a bulk over several frames would be a different (restating) edit that nobody asked
for — the confirmation controls are the ones that take the whole selection, because a flag on an existing row is the
same statement wherever it is read from. The Flags panel's count is a count of **positions the frames state**, not of
positions that will change: pressing "By hand" on a grid where two of four are already manual reports 2, and the
button cannot say beforehand which. A group that only inherits its position cannot be confirmed from that frame at
all, which is right but means a planner has to find the frame that states it (the row says "same", the chip is
disabled, and the tooltip explains). Turning a group **on site** reuses the coordinate the off-site row already
holds, so "they are back" means "back where the plan last put them", not where they actually are — the drag is the
gesture for a different place, and a group that comes back somewhere else is reported as one long hop from where it
was last on site (step 9's stated consequence). `frames_fill` still ignores the flags, and a fill that ends off site
will write on-site points along a line nobody walked (unchanged from step 9). **`frame_set_verify` has no rev to
guard** on purpose: it patches one column on rows that are still there, so a planner holding an old copy of a frame
is not overwritten — but it also cannot tell whether the *positions* it flags are the ones the planner was looking
at; if two planners edit the same stretch at once, the later flag wins and nothing says so (step 18's versions are
where that gets a history). The off-site flag is still **not shown to a member's timetable** (step 16) and **not used
by publish**: a plan can go live with positions still waiting to be confirmed. The state chips have **no keyboard
path** (they are buttons, so they are tabbable, but there is no shortcut and no arrow-key way to them), which is the
same pointer-first gap step 8 recorded for drags. **The board's height is still decided by the inspector's content**,
so opening a frame resizes the map; the camera is only fitted at the moments the board chooses (the plan opens, the
zones arrive, the layout settles once), and a window resize is Leaflet's own business — there is no re-fit for it,
and a planner who resizes keeps whatever framing the resize leaves. The bulk state control is the open frame only,
so stating "these four groups are off site for the next twenty minutes" at four frames is four clicks on four
frames; if that turns out to be a real gesture it belongs in one call with the confirmation's shape.
**New from step 11:** the board asks the database after every write, so a crossing and a pace now appear while
drawing — but the **refusal** still names only the first problem, ordered by time, so a plan with three problems tells
the planner about one per attempt, while the board lists them all. The board **does not block the edit**: the drag is
written and the plan stays unpublishable until it is moved, which is a choice (the writing planner keeps the gesture)
and a debt (a planner who does not read the panel can leave a plan in that state). A group that **stands** inside a
no-go zone with a single statement is not reported: the rule tests the line between two statements, and one point has
no line — if standing inside matters it is a different rule with different words ("inside", not "crosses"). A pair that
is both over 25 m and crossing a zone is reported as the distance only, so a zone can be crossed by the one hop that
is too long to be plausible. The pace threshold is **6 m/s for everybody**: a marshal on a bicycle, a buggy, or a
group that really does take a lift has no way to say so, and an off-site excursion is deliberately not measured, so a
plan can still contain a group that travels 200 m while nobody is looking. `frames_fill` still ignores both flags, so
closing a distance gap can write a walk through a zone — the fill button and the crossing rule do not know about each
other yet. And the pace rule makes a **timing** mistake read as a **place** mistake: two frames a second apart with
20 m between them is refused as "faster than running" when the real fix is usually to move one frame's time, not to
move the group — the sentence says the pace, and the planner has to work out which lever that is.
**New from step 12:** the budget counts **every** frame between the two statements, including frames where the group
is off site — an excursion is still not measured, but its frames still pay for the walk that spans it, which is the
generous side of the rule and worth knowing before it is relied on. The **ring cap** (24 frames in from each end)
means a stretch longer than 49 frames has unmarked dots in its middle; the band still spans it, so the reach is
visible, but a reviewer counting red dots would undercount a very long stretch. `frames_fill` still sizes its steps by
distance alone (24 m each, between the two ends it is given) and ignores how many steps the pair already had, so a
pair the cumulative rule already allows can still be filled — harmless, and it adds frames nobody asked for. Bands and
stretches are **per group**: two groups walking the same impossible stretch are two bands, deliberately, because the
lane under each is that group's (step 9's check depends on it). The inspector's new line names every stretch the open
frame is inside but offers no jump to either end — the warning rows' **Show** button is still the only way to open an
end, and it exists only for the database's rows. The row still reports the **whole** walk's distance and the
**whole** budget when a stretch has several hops, so "199 m, limit 25 m" on a one-hop row is honest but a planner
reading only the number may miss that the fix is a frame, not a place. And the check leaves "Stretch bench" with a
200 m hop, so `dev/checks/step12-stretch-prep.sql` has to run again before a second run.
**New from step 13:** the stack is **per tab and per plan** (sessionStorage), so undo does not cross a tab, and a
reload keeps the commands while losing the selection and the ticked groups — the two memories disagree, and the one
that survives is the one that can change the plan. Forty commands is the cap and there is **no history panel**: the
planner sees the last thing undone in a toast and nothing else. Undo **does not republish**: taking back an edit to a
plan people are already following changes the draft, and the next publish is still a deliberate act (steps 17–19 give
that a flow). The one thing that is *not* on the stack is a **deleted plan**, whose own dialog says so; a **fill** is
undone one frame at a time, so a thirty-frame fill is thirty calls and thirty reloads, and if fills get bigger that
wants a batch delete. A **fill** also leaves the frames it did not add alone, so an undo of a fill is exact, but a
**hold** that wrote into a frame somebody had since edited is refused rather than merged (PT409) — both are the same
rule, and it is the right one, but the sentence is about the frame and not about the hold. Between an edit and its
undo, another tab's edit on the same frame wins (its rev is what the inverse re-reads), which is exactly what step 18
is for. Ctrl+Z is ignored, not queued, while a write is landing; a **stretch selection blocks Delete** with a sentence
rather than a guess; and **Cmd**+Z / Cmd+Y are wired (metaKey) but have only ever been pressed as Ctrl on this
platform. The check leaves "Undo bench" published, and `dev/checks/step13-undo.mjs` needs `plan_bench.sql` and
`step13-undo-prep.sql` before a second run — two new files in the bench's lifetime, so a rebuild is now the first step
of any hand-run.
**New from step 14:** there was **no screen** for actuals until step 16 — `progress_mark` still has no client caller
(step 21's arrival marking is where a tap is made), so what step 14 proved is the data and its rules, and step 16
proved that the timetable *reads* them (arrived, missed, when, by whom) on a member's own schedule.
A mark WAS **last write wins**: two marshals recording the same frame both succeeded and the later `marked_at` /
`marked_by` replaced the earlier with no history — **changed in step 28** (064): two ops hands still both succeed (ops
may correct), but two ICs no longer do — the second is refused with who marked it and when — and a deleted profile no
longer turns a person's mark into the tick's (`marked_auto`). What is still missing is the history the hand-back log
would have to carry; nothing records an overwrite. The table was readable by **any member** until 052 narrowed it to the caller's own group (step 3's
finding 23, closed).
**Deleting a
frame erases what happened at it**, by design, and undo does not bring the record back: step 13 restores the frame
with its id, but the progress row cascaded away and the new frame is one nobody has marked — the id is the same, the
history is not. `progress_mark` accepts a session that has **ended** (deliberate: paperwork happens late), so a
closed event's timetable can still change, and nothing records who closed it. `session_status` judges "late" against
`p_at` but does **not** consult `ended_at`, so a frame after an event was cut short still reads "late" rather than
"not run" — step 20's ops view is where that gets decided. The carry-forward is one lateral lookup per (frame ×
group) per call, fine for four groups and six frames and **not measured** against a hundred-frame run. And the
column names are `marked_at`/`marked_by` rather than the plan's `at`/`by`, because both are keywords PostgreSQL will
not read off a PL/pgSQL record — every later reader inherits the better names, and the sketch's ones never existed in
a table anyone used.
**New from step 15:** the timetable's **content can change without its revision**. An edit to a running plan (a
dragged badge, a moved frame) moves frames and times but only a publish moves `plan_rev`, so a tab that re-reads
sees new rows without being told anything changed — the announcement is the publish, and steps 17–19 (fork, a
compare-and-set publish, a real plans channel) are where "who sees the edit, and when" is settled. `plan_publish`
now writes `event_sessions.plan_rev`; a **rename** still bumps `plans.rev` without moving the session, which is
deliberate (a rename is not a timetable change) but means "the plan's revision" is two numbers in two places — step
18 settled which one a publish takes from a caller: the plan's own, so a rename makes the next publish stale
(finding 58). The strip's read is **one call per open board every 30 s**, plus
one per push — trivial next to a map's tile load, and not measured. The rows had **no screen** of their own until
step 16 rendered them for a member (off-site as "not required", the clock times, arrived and missed); the strip is
still only the revision and T+0 on the planner's board. The read was scoped to the caller's group while the
**table** behind it was not — `plan_progress` was readable by any member until 052 narrowed it (step 14's debt,
closed). The strip has **no history and no "what changed"** — it names versions, not edits;
step 18's `plan_versions` and step 21's log are where a person can see the difference. And the two-tab check is
the first one that depends on Supabase Realtime for its *timing* rather than for a redraw: if the subscription is
slow the check waits up to 20 s, and if it is down the 30 s poll would still notice — the assertion counts the
request, so a page that simply never asked cannot pass.

**New from step 16:** the schedule's **scheduled** branch and its never-started empty state are built and read by
eye, not by a check: the screen's bench always has a live session (and ends it, which is how the closed branch got
written), so nothing exercises a start that is still ahead or an event that has never been started. A **scheduled**
session is a real case (a planner schedules tomorrow's start) and is the first thing to add to
`step16-schedule.mjs` when it matters. The schedule re-reads on a publish, a look, the 30 s
floor and at each planned moment, but **an edit to a live plan is still not announced** — a planner dragging a badge
changes what a member's next read will show, and nothing tells them; steps 17–19 (fork, compare-and-set publish, a
real plans channel) are where that is settled, and step 16 deliberately did not invent another trigger. The read
returns **every frame of the plan**, not the part still to come, so a hundred-frame run is a hundred moments on a
phone; the read and its carry-forward are **not measured**. A moment carries the planner's **note** but no **place**
— a frame has no zone or waypoint (named states were ruled out), so a follower reads "6:45 pm · doors" and not "at
the stage". There is **no arrival marking on the schedule**: `progress_mark` still has no client caller, so step 21's
hand-back is where a person taps "arrived" rather than a table being filled by nobody. `plan_check` now answers a
member with **no rows** (052 closed their frames), which makes the board's second opinion a planner's tool; if a
member is ever given a plan view again, the policy and the function have to be reconsidered together (finding 49).
`plan_frames_list` is now only ever answered for ops, and it is still `security invoker`, which is exactly why the
member's answer is zero rather than a second door. And the ledger still says 037 is applied while its `activities`
table is missing (finding 47): step 25's drop inventory has to read the catalogue, never the ledger.

**New from step 17:** a copy is **named "… (edited)"** whatever it is — a continuation of a running plan reads as a
revision of a document, not as "the rest of tonight"; renaming it is one field away, and a better default is a product
decision, not a fix. The copy carries the **same printed T+0** as its original, and a planner can still edit that
field afterwards (`plan_save`), which changes nothing for the running session (`t0_at` wins, step 15) and everything
for the *next* start: a copy whose printed T+0 was moved is a hint that disagrees with the clock. Publishing a copy
moves a session **only onto the plan it was cut from**; a session running a different plan of the same event is
carried by nothing, and a copy of a copy is carried only if the session ran the immediate original. The **hand-over
marks every on-site group arrived** at the cut — the plan's own position, not a report from the ground — so a group
that is actually elsewhere is recorded as where the walk had it until steps 20–21 give the ops view real positions
and arrival marking; an off-site group gets no mark and reads "not required". A copy taken **at T+0 itself** has no
cut, so its whole walk is editable: the rule is "the past is what has happened", and at the zero point nothing has.
The strip still starts at T+0, so a copy taken twenty minutes in draws twenty minutes of empty bar before its first
dot — honest, and plainly so, but not pretty. `plan_position_at` is the walk's arithmetic in one place and is
**not measured** against a hundred-frame plan (one ordered lookup each way per call), and it reads any group's
position for ops staff, own group only for everybody else, exactly as `plan_positions` does. And the frozen `now()`
of a single transaction made one bite read "pending" where a moving clock reads "late": a check that compares a
clock to a frame has to say which clock it means (finding 42's cousin, and why the browser is the second witness).

**New from step 18:** a version is written and **nothing reads it yet** — no function, no screen, only a policy, so
"what changed between 2 and 3" is a JSON comparison somebody makes by hand (step 21's log is where a person sees it).
A version is **never deleted except with its plan**, so every publish of every plan keeps a whole snapshot for ever;
nothing prunes them and the size is **not measured** (a hundred-frame plan with four groups is maybe 100 kB, and a
busy event publishes dozens). It records the plan's **printed** T+0, not a session's `t0_at`, and it names **no
session**: it is a record of the plan, not of who was following it. The stale refusal is **one sentence, one
outcome**: the board re-reads the plan and clears its undo stack, so the edit a planner was publishing cannot be
taken back with Ctrl+Z afterwards (it can be re-edited) — and because a rename bumps the revision too (finding 58),
two planners on the same draft will see the refusal whenever either of them renames. The comparison is locked with
`SELECT … FOR UPDATE` on the plan row, and the snapshot is taken under that lock, so a publish of a very long plan
holds the row for the length of the aggregate (**not measured**). `published_by` is `auth.uid()` and `NOT NULL`, so
a publish from the SQL editor — no JWT — is refused; a cron job that ever needs to publish will need a caller. And
the client sends `plan.rev`, which only renames and publishes move: frame edits are deliberately *not* a revision
of the plan (step 15's debt), so a tab whose frames are stale can still hold a current revision — which is why the
refusal is about the plan row and the strip is about the timetable, two different questions with two different
answers.

**New from step 19:** a plan's **content and its revision can be out of step on screen**, by design: another
planner's frame edit is drawn as soon as it lands, so a board can be showing revision 2's content while still calling
itself revision 1 — and the picker's "(N frames)" (read from `plan_list`) can disagree with the dots under it for the
same reason. The strip says so in words, but a planner reading only the picker would not know. Every content write is
**one full `plan_frames_list` read per open board**, so a hundred-frame plan is a hundred rows per keystroke somebody
else makes; the cost is **not measured**, and neither is the cost of the subscription itself (Realtime authorises
every event per subscriber — one table and one filter, but unmeasured). The channel is **per event and
unconditional**: a planner's board hears about every plan of the event, including drafts it is not looking at, and
reloads the list each time. A DELETE event is sent to **any** subscriber whose filter matches (a deleted row cannot be
RLS-checked), so a deleted plan's name and printed T+0 leave the database to whoever knows the event id — the walk
does not. The board holds background reads during a pointer gesture and releases after five seconds if the pointer
never lifts, which is a heuristic, not a guarantee. Deleting the **live** plan still leaves the running session on
nothing (`event_sessions.plan_id` is `on delete set null`), so the event silently becomes tracking-only: the board
lets the plan go (step 19's deletion test), the timetable says "running without a plan", and nobody was asked.
Nothing subscribes to `plan_progress` or `plan_versions`, so an arrival marked in another tab — or a publish's
version row — reaches no screen (the board draws neither). And step 15's and step 18's "the other tab does not have my
frames" assertions became "the other tab may have the frames; what is stale is the revision", because a publish is
now the moment the board stops adopting content: a deliberate consequence, but it means those two checks no longer
prove that a stale tab is stale *in its content*.

**New from step 20:** the ops board's group word is **derived on the client** from the rows (any active → active, else
pending while one is ahead, else done), so the five-line rule now exists twice — the read's per-row status and the
screen's derivation. Both are asserted (the SQL matrix and the browser's chip), but a third reader would be a third
copy. The panel is the first screen to **poll a plan read**: one `plan_ops` call every five seconds, and each call asks
`group_position_at` per group, which is a window scan of `locations` per group — fine for four groups, **not measured**
at a hundred. It is **live-only**: `plan_ops` accepts a `p_at`, but no screen asks it about a closed show (the schedule
is the closed view), so "how did this look at 18:20" has a function and no button. The read carries **no revision**: it
draws whatever frames the plan holds now, so a publish mid-session can show the new walk's moments under the old
version in the header — the content/revision split of step 19, in a read that names neither number itself. A group with
no moments in the plan **does not appear at all**, so the board cannot say "nothing is planned for this group" while
the map still shows them standing there. The midpoint counts **any reading that carries the group**, not only its
current ICs (`is_ic` is never consulted, as in 021), so a person who is no longer an IC stays in their group's position
for up to two minutes. `off_m` compares the midpoint with the walk's straight-line interpolation, which means a group
on its own route but off that line reads as "N m off" though it may be exactly where it means to be — the plan states
no routes. And travel time is the strip's interval and says nothing about whether the walk is *possible*: the 25 m and
pace rules are publish-time (048/049) and the ops board never shows them, so a published plan whose leg is impossible
would still read "45 s of travel".
**New from step 21:** the **early moments never close**. The tick only looks at a group's *current* moment, so a moment
the group was at twenty minutes ago and nobody recorded stays unrecorded for ever — the auto-close is not a backfill, and
a cron gap is a silently missed nudge (finding 78). **One IC is enough** to close a moment: the movements engine required
all of a group's sharing ICs (or a stated minimum) for twenty seconds, and a plan moment asks for one phone on the ground,
so a single IC standing in the right box can record a whole group — a stronger statement than the data supports if the
group is spread out. A moment can only close **arrived**: nothing auto-marks `missed`, which stays a person's decision
(050's rule). The close needs a **zone that contains the drawn point**, so a badge in an empty field, or a zone drawn
after the plan, never closes itself — the planner's drawing decides whether a moment can ever be automatic, and nothing
warns them that a moment they marked `auto` is uncloseable. `marked_by` null is the **only** way to tell the tick's close
from a person's, which is an overloaded null: any future writer that leaves it null (an import, a repair) reads as
"automatic". The forecast is **straight-line** metres, so it is optimistic — a group told "you will make it" may not —
and it takes the group's **last-minute speed**, which is an average over the ICs that moved (021), with a 0.5 m/s floor and
a 1.3 m/s default nobody chose: a group standing still reads as walking at 1.3. The ETA is queued **once per moment**, so
a group that starts fast and then slows is told nothing new. `plan_push_tick` runs **every five seconds across every live
plan session** on the project, and `plan_eta_tick` every thirty, each asking a midpoint per group: **not measured** at a
hundred sessions, and it is the first job that reads `locations` on a schedule. The push kinds now number thirteen and the
sender passes title/body through untouched, so a new kind gets no styling on the phone. `handover_log` is **per session**
and has **no notification**: a hand-back is silent, nobody is told they are now responsible, the log is not on any screen
outside the live ops board, and the only way to see the chain is that one line — while an **ended show cannot be taken**,
so the last shift's row is the final word and there is no "closed by" entry. Any of the event's ops can take the board
(there is no shift, no rota, no "who is expected"), and the `plan_rev` copied onto the row names a version that **nothing
reads yet** (step 18's debt, unchanged). The retirement of `gps-route-eta` leaves run-sheet movements with whatever route
they last fetched, so their ETAs **frozen** until step 24/25 remove that engine — the plan path is what this build is for,
and it is a deliberate cost, but it is a live one for anyone using the old engine this week. (**Closed in step 25**: the
engine and the movements went, and the Edge Function that fetched those routes went with them.)
**New from step 22:** playback is the **planner's** board only — a member's own run is the schedule, which has no play
control and no sign of where they "should" be mid-leg, and there is no way to export or share a run. The badge between two
moments moves on a **straight line**, because the plan states no routes: it is an illustration of the strip's arithmetic,
not a track, and an off-site stretch holds the badge and then removes it rather than walking anybody off the map. The
cursor is **component state**, so a reload during a run starts again from the first moment — there is no "resume where I
was". Playback does **not** show the actuals: where groups really were at that instant is the ops board's read (`plan_ops`
at now), and putting the two on one map is a later decision. The log has **no take-down** (a message stays until it is
acked, and an acked one stays as a record), no reply and no thread, and its only phone surface is the schedule card: a
member who never opens their schedule learns about a message from the push alone, and a member who has no push token
never learns at all. The tally is read on a **poll** — 5 s on the ops board, 30 s on the schedule — because nothing
subscribes to `plan_log`; a second planner sitting on the log sees an ack up to five seconds late. The audience `all` means
**the plan's groups**, so somebody in the event but in no group is never told and there is no "everybody in the event"
audience; and a group the plan never places cannot be messaged (22023) even though it exists. `plan_log` rows are **deleted
with the plan**, so the record of what a cancelled plan's groups were told goes with it — the one place this build deletes
a record instead of keeping it. The timeline comparison ignores `verify` — a position switched from `auto` to `manual`
with the same point and time is not a change anybody is told about, which is right for "your times" and wrong for "who
confirms it". Two copies cut from the same live plan compare against the **same** latest source version, so a copy cut
earlier cannot represent what *its* people were following if the source was published again in between. And the diff runs
per publish — `plan_version_walk` over every frame for every group, twice — which is **not measured** on a plan of a
hundred moments.
**New from step 25:** **zone deletion is no longer refused while an event is live.** `zones_guard_live` refused to
delete a zone that a live movement pointed at; a plan's positions are lat/lng, so a plan pins no zone to anything and
the guard would have refused with no reason. The loss is real: a planner can delete a zone mid-event, and its alerts
and presence rows go with it (`on delete cascade`). A live-event guard for zones is a decision to make, not a leftover
to restore. **The map has no plan ops layer.** A marshal used to get clusters of groups by zone, a worst-status ring and
a dashed line to the zone they were walking to, all drawn from `movement_status`; `PlanOps` is a table of moments and
has no map counterpart, so "zoomed out, one bubble per zone" is simply gone. **The `route-eta` Edge Function's source
is deleted and the deployed function is not**: a migration cannot remove an Edge Function, so it has to be deleted in
the Supabase dashboard, and until someone does, `send-reminders` is the only function the repository knows about while
the project still lists two. `show_who` keeps a `show_` name although it is a display-name helper the plan calls.
**Zero is now the only possible value for two counts**: the Playback tab's "Ran with" line and the Zones card's
per-zone movement count were removed rather than given a plan equivalent, so the product says less about a recording
and a zone than it did — honestly, because the number they showed no longer exists. And the debts below that name a
row, a function or a test the stack owned are **closed by deletion, not fixed**: the frozen run-sheet ETAs, the
`run_sheet_id` column, the unrunnable Run sheet tab, `session_run_sheets`/`switch_live_run_sheet`/`move_step`/
`show_step`/`push_collect_moves`/`rs_runnable` with no caller, and the 105 assertions of `npm run test:runsheet`.

**New from step 24:** the Simulator panel has no browser check at all, so its plan name, its disabled Start and the
removed "Plan their movements" card are proved by the build and by reading. `sim_start` takes the **most recently
updated live plan**, and nothing forbids an event having two — publishing is per plan — so the choice is arbitrary in
a state the product does not prevent. A plan has no pace, so a virtual group walks at the 1.0–1.5 m/s it was set up
with rather than at a speed the strip implies, and `sim_setup` still starts every group around a zone even though the
plan takes over on the first tick. And a cron change now costs a few minutes of the step-24 check's meaning:
`cron.schedule` on an existing name mints a new `jobid`, so the per-job "succeeded recently" window starts empty
(finding 97).

**New from step 23:** the sheet is the **planner's**, so the part of a plan a person follows still cannot be taken home
as a file, and there is no export of the log or of the published versions. The file has **no identity**: the plan's name
is a comment, so a sheet can be imported into another plan and nothing says where it came from — a template feature that
is also a way to overwrite the wrong plan. A round trip keeps the **moments**, not the plan: status, name, printed date,
T+0 and the running revision have no column. The import is **not undoable** (it ends the stack, like a publish), and
nothing checks a sheet against the locked polygons before writing, so a crossing imports, shows red, and is refused at
publish — the same "content and revision can disagree" debt as any edit. A coordinate is effectively **fifteen
significant digits** in the whole plan stack (finding 91), so the file is the board's value and cannot be a decimal
archive. The 25 m refusal lives in the client, which means a caller that bypasses it can import an impossible walk (the
database's own gate is still `plan_check` at publish). The reader accepts a header without a `group` column — a bare
timetable of times and notes — and importing one empties the plan's positions, a reading no screen offers. And it is one
CSV with one sheet: no template, no workbook, no second tab.

**New from step 26:** the place is a **zone name or nothing**, so the screen cannot say "on the way to the stage" and a
member cannot tell a walk from a gap; a carried frame is silent even though the group is still standing there, because
the read reports what the plan *states* at that frame. The lookup answers with the **first** zone by kind and then by
name, so a point inside two zones of the same kind resolves alphabetically, and nothing anywhere warns a planner that
two zones overlap — the same silence that made the no-go question worth deciding. The **ops board still speaks in
coordinates**: `plan_ops` has `plan_lat`/`plan_lng` and no place, so the marshal's table and the member's schedule
now describe the same moment in two different vocabularies, and closing that is a 26-column drop-and-create rather
than a column. The member's page remains **one read** on purpose (step 16's check forbids a `plan_positions` request),
which is what made a server-side column necessary — and also means the place can never be a client-side enrichment of
something the plan did not state.

**New from step 27:** the radius is a number **nothing shows on the ops board** — `plan_ops` has no tolerance and no
"how far off was the phone", so a marshal watches a group stay late and cannot see whether the phone was 40 m short or
had stopped reporting. **Two ICs of one group each carry a number and the nearest close wins**, so the group's honesty
is the loosest phone in it, and no screen says which IC closed what. It is **per event**, so two events in one venue
share nothing. A planner can change an IC's radius **without telling them**: the change is toasted on the planner's
own screen, and the IC's card says neither who set the number nor that it moved. The **whole band is a judgement**
(5 m .. 100 m, default 30) written into a CHECK, and nothing in the product tests it against a venue. And the
**session-start bound is a workaround**: `locations` has no session id, so the tick bounds its own window by `t0_at` —
a reading written during setup, within two minutes of T+0, still counts if the group happens to be standing on the
moment's point when the clock starts.

**New from step 28:** the **future-frame hole** is the next thing on the door — `progress_mark` refuses a future
`p_at` but not a future *frame*, so a hand-crafted call can record "arrived" two and a half minutes early (113); the
fix has to decide what `plan_publish`'s hand-over does on a session whose clock has not started, which is why it was
not smuggled into this step. The **press is the IC's only**: the group's admin is admitted by the door and has no
screen, and nobody can record "we were not here" except the ops board. The **refusal cannot be staged in the
browser** (two people, one stale screen, one browser profile), so the guard's sentence is proved at the database and
not through the interface. The ops board has **no "change this mark" control** and still answers the marker as a
uuid, so it can neither offer a correction nor name the person who made the mark it is showing. And the hand-over
records the anchor in the **publisher's** name, so after this step the group's IC cannot replace it — the guard
working as intended, with "the publisher or another ops hand" the only correction path.