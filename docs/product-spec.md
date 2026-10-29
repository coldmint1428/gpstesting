# Event Coordination & Live Tracking — Product Spec

Saved from the working spec notes. Sections follow the original outline.

## Problem being solved

Large-scale events have many moving parts across many groups. Coordination runs through
Telegram group chats, multiplying into ~100 messy chats. Hard to plan, and no visibility into
where the bottlenecks are, whether physical or time-based.

## Roles and access

- Sign up → create a new event (you become root) or join someone else's.
- Root is a single person per event, and can do everything.
- On creating an event, root may invite users as planners, admins, ICs or users, and create
  groups. This is optional and need not be complete.
- Planners are event-level: layouts, timings, sequences, groups. Once invited, they can add
  admins and groupings.
- Admins, ICs and users are group-scoped.
  - Admin: add/delete users in their group, promote a user to IC. Only their own group.
  - IC: the person in the group whose device is connected to GPS, enabling live status for
    planners/root.
  - Users, admins and ICs all see their own timeline and location, where to where, at what time.
- One person can hold several roles at once (planner, IC, admin). Everything is event-scoped; no
  cross-event mixing. IC in event A, planner in event B.
- Let's add a Marshal role: positioned at checkpoints or sit with spectators, marking group
  locations manually (drag and drop if GPS fails). They are the fallback for tracking. Small
  feature but useful.
- No other roles for now.

## Joining

- Invited by email, or enter a code from the home page.
- A person can belong to several events, kept separate.

## Layout

- The floor plan is uploaded and overlaid on the map with its corners/edges anchored to lat/lng.
  It is a reference layer only, a tracing aid, not a source of truth.
- The base map (Google Maps) is the main substrate; the overlay just shows the planner where to
  draw what.
- Polygons are drawn natively on the map, in lat/long, not in pixel space. So the raster can be
  swapped without moving any zone.
- Polygons mark zones, no-go areas, obstacles, exits and entrances.
- Laying out the floor plan is work; it can be skipped where satellite imagery suffices.

## Time model

- One shared time grid for the whole event. No independent per-group clocks.
- The timeline is an ordered list of time spans. Durations are not fixed and need not be even:
  15s, 1min, 5min, whatever is needed.
- Each time span holds its own snapshot: the positions of all nodes at that time.
- A state is a named time span, with a name and description.
- Unnamed waypoints sit under a state, tracing the movement within that span.
- The master clock is T+0. The backend computes in T+0 only; conversion to wall clock happens on
  the front end.
- Snapshots are discrete and can sit at any point in time. Playback runs at any interval of
  choice.
- Movement between positions is a straight line, capped at roughly 25m per segment. Longer moves
  require new snapshots. Any segment that cuts through a polygon is rejected. Reason is, this is
  the most straightforward way to plan routing without too much code or edge cases.

## Authoring

- Copy/paste of states and waypoints. A paste lands into a time span, so it inherits that span's
  time, no offset to set. Duplicating a snapshot carries the whole arrangement; you then move only
  the nodes that differ.
- Nodes can be multi-selected and dragged together.
- Adjusting a node flags the affected segments both before and after, especially where rules are
  broken.
- Dragging a node re-validates the path into and out of it against the 25m cap and the polygons.
- No auto-routing or automated placement (it might mess up).
- CSV export, and CSV import is acceptable for bulk schedule.
- Filtering exists for visibility. Groups have names and colours, and hovering a node shows its
  name.

## Live

- Planners see actual movements in real time, e.g. during rehearsals.
- Position sources are IC GPS and marshal marks.
- Multiple ICs per group are allowed. The group's position is the weighted midpoint of them, so
  one faulty device doesn't drag the rest.
  - Marshal marks (if needed) take highest priority, and can hand tracking back to IC at their
    judgement once the IC's GPS is working again (marshal can still see their IC's GPS). The
    handoff is logged.
  - Marshals can also indicate when a group has reached a checkpoint by a specified time.

## Comparison

- Comparison happens only when a planned state is hit. The diff is temporal: arrival versus the
  planned time.
- Whether a state was hit is defined by a human (the marshal), not by automation. The app may help
  by flagging when a group appears to be within the checkpoint, a suggestion, confirmed by the
  marshal.
- Outcomes: hit on time, hit late (with delta), missed, or not yet. A state past its planned time
  with no mark is visibly outstanding by default.
- The comparison is evaluated against the plan version in force at that moment, never the current
  plan, so re-planning cannot retroactively rewrite history.
- Not re-planning is also a decision, and is part of the record.

## Change handling during a live event

- Two operations, both allowed:
  - Shift the remaining span time; moves every group, since the grid is shared. Used when the
    whole event slips.
  - Hold one group; rewrite that group's future spans so its next move happens later. On the
    user's end, only that group's timeline changes. Used when one group is behind.
- Participants receive an updated timeline. Re-planning is a versioned edit.

## Playback

- Traces back the live event to see what went wrong.
- The entire live event converts into the planned style, so it is editable: adjust states, move
  the slider, drag nodes.

## Notifications

- Minimal and small: one event type, "timeline updated", pushed only to the groups affected, with
  a single ack tap. No threads, no replies, no read state beyond the ack.
- This is not a chat app. It solves the group-proliferation problem by being the source of truth,
  not by replacing messaging.

## Change control

- One live head. The same branch for everyone; no two users ever see a different branch. No
  parallel what-if branches.
- All past versions are kept. Every edit captures the time it was made and which planner made it.

## Deliberately not doing yet

- Automated bottleneck detection or group dependencies, playback lets the planner see it.
- Automated routing or auto-placement.
- Parallel branches / what-if planning.
- A chat or comms feature.
