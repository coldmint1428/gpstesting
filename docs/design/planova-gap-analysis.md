# Gap analysis — Planova design vs. product spec

Compares the captured Claude Design canvas (**Planova**, 72 artboards, `docs/design/planova/`) against
the written specification (`docs/product-spec.md`).

**Method:** structural digest of every artboard (`docs/design/planova/_digest.md`) — headings, actions,
form fields and domain vocabulary per screen — read against each spec section. Board names below match
the captured files, so every claim is checkable against a screenshot.

**Headline:** the design is a strong, production-grade elaboration of the spec's *planning* half and a
weaker match for its *live* half. It covers the shared timeline, zones, movement planning, playback and
the multi-role model well. It does not implement the Marshal fallback role, the IC-weighted-midpoint /
handoff model, T+0 as the internal clock, versioned re-planning, or the ack-based notification contract.
It also adds a substantial attendance system the spec never mentions — which may be the most valuable
thing in it.

## Coverage summary

| Spec area | Status | Design evidence | Gap |
|---|---|---|---|
| Problem framing | **Covered** | `Main`, `M-SignIn` — "Plan the venue. Move every group on time." | — |
| Roles & access | **Partial** | `D-Root-Participants` (Planner, IC, Group Admin, Participant), `D-Admin-Members`, `D-Planner-*` | No Marshal; no per-event multi-role *assignment* screen (badges show it: "role per event") |
| Joining | **Partial** | `D-Join`, `M-Join`, `D-Root-Overview` (invite link + QR, approval queue), `D-Create-CSV` | No join-by-code from home; joins are link/email only |
| Layout / zones | **Partial** | `D-Planner-Zones` (7 zones: Stage, Restricted, Holding, Assembly, Entrance, Exit, No-go) | No floor-plan raster overlay; no Obstacle type; no visible polygon-editing affordance |
| Time model | **Partial** | `D-Planner-Timeline` (activities with Starts/Ends per group), `D-Planner-Playback` | No T+0 internal clock; no named "state + description"; no 25 m cap or polygon-crossing validation surfaced |
| Authoring | **Partial** | `D-Planner-Timeline` (add/edit/delete activity, Undo point), `M-Planner-Timeline` | No copy/paste of states; no multi-select drag; no segment rule-flagging; CSV is people-only |
| Live | **Partial** | `D-Planner-Live` (planned vs actual, Needs attention / At risk / No signal / Late), `D-IC-Now`, `M-IC-Location-Off` | No marshal marks; no weighted midpoint of multiple ICs; no handoff or handoff log |
| Comparison | **Partial** | Attendance bands per activity; `D-Admin-Attendance` (Present/Late/Absent/Not marked) | Vocabulary is attendance, not state-hit; no "missed"; no plan-version-in-force |
| Change handling | **Missing** | "Share plan with groups" exists (publish) | No shift-remaining-span, no hold-one-group, no version list |
| Playback | **Covered** | `D-Planner-Playback` (timestamps, Problems, selected/all routes, "lost signal" markers), `D-Stress-Playback` | Not editable back into the plan style |
| Notifications | **Missing** | `D-MyEvents` "Notifications 2", mobile "Alerts" tab | No ack; no "timeline updated" event type |
| Change control | **Missing** | — | No version history / author+timestamp |
| Non-goals | **Respected** | No auto-routing, no bottleneck automation, no branches | See contradiction below re: messaging |

## Where the design genuinely advances the spec

These are additions, not gaps. Several close real holes in the written spec.

1. **Attendance as a first-class object (strongest idea).** Every activity carries its own attendance
   check: `D-Admin-Attendance` shows All 32 / Present 29 / Late 1 / Absent 2 / Not marked 0, with
   "Mark everyone not marked as present" and a Send step. Participants self-mark
   (`D-Participant-Mark`: Present / Late / Absent with optional minutes-late and note;
   `M-Participant-Checkin` makes a reason mandatory for Absent). The spec's comparison model only asks
   *"did the group hit the state"*; attendance asks *"did each person"* — which is what a real event
   actually needs, and it degrades better than GPS.
2. **Partial-authority model made explicit.** `D-Root-Participants` publishes role definitions in the
   UI ("IC Leads the group and shares GPS on the live map"), and `D-Admin-Members` states the IC
   consequence inline: "their phone shares its location with Planners while they're IC". That is the
   spec's consent model, shown at the point of decision rather than in a policy doc.
3. **Guards the spec implies but never names.** `D-Admin-Members-Blocked` — "Can't remove the last IC"
   with a confirm dialog. Cheap, prevents an untrackable group.
4. **Scale is designed, not assumed.** Six dedicated Stress boards at 30 groups / 30 nodes
   (`D-Stress-Plan` is 123 KB of source, the single largest board) plus label-density controls
   (Auto / All names / No names) and an activity rail at 22–34 timestamps. This answers "does the
   timeline survive 30 groups", which the spec never addresses.
5. **Zone semantics richer than "polygons".** Zones carry Type, Capacity and **"Who can enter"**
   (`D-Planner-Zones`). That turns a tracing aid into an actual permission/capacity constraint.
6. **Event setup as a 4-step wizard with real validation** (`D-Create-Wizard` → Details → Users & roles
   → Groups → Review), including a Needs-attention state, duplicate-invite error, CSV preview with
   "Add 4 people", and a review screen. The spec says root *may* invite "optionally and need not be
   complete" — the design supports both the fast path and the full path.
7. **Approval queue + link expiry.** `D-Root-Overview` "Waiting for approval" / Approve,
   `M-Root-Invite` "Approve each new person · 3 waiting now", "Link expires". Not in the spec at all,
   but a public-invite link without it is a liability.
8. **Route sheets and leg distances.** Group Admin and Participant get a route sheet with per-leg
   distance ("120 m · attendance check", "260 m"), which is the *output* of the 25 m-segment constraint
   the spec describes — the planner's rule surfaces as a human-readable route.

## Where the design is thin against the spec

Ordered by how much work each gap implies.

**1. Marshal role is entirely absent.** No board mentions it; the role vocabulary across all 72 boards is
Root / Planner / Group Admin / IC / Participant. This removes the spec's stated fallback for GPS failure
— and note the design *has* the failure (`No signal`, `Not tracked`, `M-IC-Location-Off`) but no recovery
path other than "Message all ICs". The spec's design intent — marshal marks outrank IC GPS, hand back at
marshal's judgement, handoff logged — has no UI at all.

**2. Live position model is single-source.** Design shows "ICs 2" (`D-Admin-Members`, tab "ICs 2") but
never expresses the weighted midpoint of multiple ICs, nor which source is currently authoritative. So
"one faulty device doesn't drag the rest" — a deliberate spec decision — is invisible in the design.

**3. Comparison vocabulary diverges.** Spec: hit on time / hit late (with delta) / missed / not yet, all
against the plan version in force. Design: On track / Arrived / At risk / Late / No signal / Not tracked,
plus attendance bands. There is no "missed", no explicit arrival-vs-planned **delta in minutes** visible
in the digest, and no indication that history is frozen against an old plan version. The "Needs
attention 4" bucket conflates four different spec outcomes.

**4. Change handling has no controls.** The two operations the spec calls out — shift the remaining span
for everyone, or hold one group and rewrite only its future spans — do not appear anywhere. The nearest
affordances are "Share plan with groups" and "Fix in the plan" (a nav link, not an operation). Note
"Hold" is used as an *activity name* ("Hold · Holding C", "18:30–19:05 · Hold"), which collides with the
spec's "hold one group" verb and will confuse naming later.

**5. No version history.** "Share plan with groups" implies publish, but nothing shows who changed what
when, and the spec's "one live head, all past versions kept, every edit captures time + planner" has no
surface. This is also what makes the comparison-against-in-force-version requirement unimplementable as
designed.

**6. Notification contract missing.** Spec is deliberately narrow: one event type, targeted push, single
ack tap. Design has a Notifications count and a mobile Alerts tab, but no ack affordance and no event
type. Meanwhile "Message all ICs" (`D-Planner-Live`, `M-Planner-Live`) is a *messaging* control — see
contradiction below.

**7. Time model under-expressed.** The design speaks in wall-clock ("now 18:26", "18:30–18:40"). Nothing
indicates T+0 as the internal coordinate system, snapshot discreteness, or the "unnamed waypoints under a
state" structure. In practice the design treats an *activity* (name + start + end + destination node) as
the atom — which is workable, but it is not the spec's state/snapshot/waypoint hierarchy, and the mapping
needs deciding before build.

**8. Authoring operations the spec names are missing.** No copy/paste of a state into another span, no
multi-select node drag, no visible flagging of "the segment into and out of this node is now illegal".
`D-Planner-Timeline` exposes Undo point and label density only. The 25 m cap and polygon-intersection
rejection — arguably the spec's most concrete rules — are never shown being enforced.

**9. Zones lack the tracing layer.** There is no floor-plan upload, no corner/edge anchoring, no
transparency control. `D-Planner-Zones` is a zone list + properties panel; the map is presumably a
satellite base. The spec's "reference layer, not source of truth" distinction is therefore untested in
the design.

**10. Join-by-code path missing.** Spec: "enter a code from the home page". Design offers "Join with
link" and email invite. A code is materially different at a 200-person door queue.

## Contradictions to resolve

1. **"Message all ICs" vs "not a chat app."** The spec explicitly refuses a comms feature; the live
   monitor has a broadcast button. Either it is a one-shot push that satisfies the notification contract
   (then rename it and give it an ack), or it is messaging and violates the non-goal. This needs a
   decision, not a redesign.
2. **Attendance vs state-hit as the comparison primitive.** The spec defines comparison as arrival vs
   planned state, human-confirmed by a marshal. The design defines it as per-person attendance, confirmed
   by the group's admin/IC/participant. Both are "human confirms", but the confirmer and granularity
   differ, and the spec gives marshals priority in the live model while the design gives admins the
   attendance authority. Pick one primary, or state the relationship (attendance ⊂ state-hit?).
3. **"Fix in the plan"** (`D-Planner-Overview`) hints at guided remediation. The spec rules out automated
   bottleneck detection but playback "lets the planner see it". A deep-link is fine; a suggestion engine
   is not.
4. **Role naming.** Spec says "users"; design says "Participant". Spec says "admins"; design says
   "Group Admin" (clearer). Align the spec's vocabulary to the design's before writing schema.

## Recommended order of work

1. **Decide the comparison primitive** (attendance vs state-hit) — everything downstream, including the
   live monitor's status taxonomy and the version-freeze requirement, depends on it.
2. **Design the Marshal surface** — 3 boards would do it: marshal sees groups + IC GPS, drop-a-pin
   override, "hand back to IC" with a logged handoff entry. It reuses `D-Planner-Live` structure.
3. **Add the two change operations** — a "Shift remaining" control on the event timeline and a
   "Hold this group" control in a group's timeline, both producing a version.
4. **Add version history + author/time stamp**, since live comparison needs a plan-version pointer.
5. **Add the ack notification sheet** — one event type, one tap, and reconcile "Message all ICs" with it.
6. **Extend `D-Planner-Zones` with the floor-plan layer** and an Obstacle type.
7. **Spike the authoring rules in the plan editor** — segment validity, 25 m cap, copy/paste into a span.
   The Stress boards already prove the canvas copes; this is about the interaction, not performance.

## Questions the design raises that the spec should answer

- Is attendance per activity *required* for every event, or opt-in? It doubles the marking workload.
- Who may override a group's position: marshal only, or any admin? The spec says marshal; the design has
  no one.
- Does "Hold one group" shift that group's attendance windows too?
- At 30 groups, does the planner need the "Needs attention" bucket to be subdivided by outcome (late vs
  no-signal vs missed), given the spec's four outcomes?
- Is the invite link's approval queue mandatory for public events only, or a general setting?
