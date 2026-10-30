
# DESKTOP

## D-Admin-Attendance-Absent — Planova · Attendance, Absent filter
- headings: Kinetic Dance Crew | Attendance | 17:30–18:20 · Assemble
- actions: Back to schedule | All 32 | Present 29 | Late 1 | Absent 2 | Not marked 0 | Edit attendance
- terms: roles=[group admin] compare=[attendance,absent,present,late]
## D-Admin-Attendance-Present — Planova · Attendance, Present filter
- headings: Kinetic Dance Crew | Attendance | 17:30–18:20 · Assemble
- actions: Back to schedule | All 32 | Present 29 | Late 1 | Absent 2 | Not marked 0 | Edit attendance
- terms: roles=[group admin,ic] compare=[attendance,present,late,absent]
## D-Admin-Attendance — Planova · Take attendance
- headings: Kinetic Dance Crew | Attendance | 18:30–18:40 · Go to Backstage
- actions: Back to schedule | All 32 | Present 29 | Late 0 | Absent 0 | Not marked 3 | Mark everyone not marked as present | Present | Late | Absent | Cancel | Send attendance
- terms: roles=[group admin,ic] compare=[attendance,present,late,absent]
## D-Admin-Group — Planova · Group schedule and attendance
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Members needing attention | Your contacts
- actions: Group Admin | IC | Take attendance · 29/32 | Mark me | Show route | Stop sharing | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check
- terms: roles=[group admin,ic,planner] live=[location] compare=[attendance,present,late,absent] geo=[entrance,exit]
## D-Admin-Members-Blocked — Planova · Removing the last IC
- headings: Members | Add people to Kinetic Dance Crew | Group members | Remove Daniel Koh as IC?
- actions: Add | All 32 | ICs 1 | Invite pending 2 | Make IC | Remove IC | Remove | Show all 32 | OK
- fields: Name or email | Also make them an IC · their phone shares its location with Planners while they’re IC
- terms: roles=[ic,group admin] live=[location] compare=[attendance]
## D-Admin-Members — Planova · Group members
- headings: Members | Add people to Kinetic Dance Crew | Group members
- actions: Add | All 32 | ICs 2 | Invite pending 2 | Remove IC | Remove | Make IC | Show all 32
- fields: Name or email | Also make them an IC · their phone shares its location with Planners while they’re IC
- terms: roles=[group admin,ic] live=[location] compare=[attendance]
## D-Admin-Route — Planova · Route sheet
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Members needing attention | Your contacts
- actions: Group Admin | IC | Take attendance · 29/32 | Mark me | Show route | Stop sharing | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check
- terms: roles=[group admin,ic,planner] live=[location] compare=[attendance,present,late,absent] geo=[entrance,exit]
## D-Create-CSV — Planova · Create event — Step 2 CSV import
- headings: Create event | Users and roles | Add people | Event team
- actions: Event details Completed | 2 Users and roles Current step | 3 Groups Not started | 4 Review Not started | Search by name | Invite by email | Import CSV | Choose another file | Add 4 people | Remove | Back | Next
- terms: roles=[root user,planner,participant,group admin,ic] geo=[exit] data=[csv,import]
## D-Create-Details — Planova · Create event — Step 1 with validation errors
- headings: Create event | Event details | Basics | Timeline
- actions: 1 Event details Needs attention | 2 Users and roles Not started | 3 Groups Not started | 4 Review Not started | Add phase | Edit | Delete | Next
- fields: Event name * | Short description * | Location * | Expected attendees * | Category | Public Can be found by others | Private Only people you add
- terms: time=[timeline] live=[location] geo=[exit]
## D-Create-Done — Planova · Event created
- headings: Create event | Event created
## D-Create-Groups — Planova · Create event — Step 3 edit group
- headings: Create event | Groups | Edit group: Kinetic Dance Crew
- actions: Event details Completed | Users and roles Completed | 3 Groups Current step | 4 Review Not started | Back to groups | Kinetic Dance Crew 4 | SMU Symphonic Band 2 | Delete group | Remove | Add | Cancel | Save changes | Back | Next
- fields: Group name | Search the event team
- terms: roles=[ic,participant,group admin,planner] change=[hold] geo=[exit]
## D-Create-Invite — Planova · Create event — Step 2 invite by email
- headings: Create event | Users and roles | Add people | Event team
- actions: Event details Completed | 2 Users and roles Current step | 3 Groups Not started | 4 Review Not started | Search by name | Invite by email | Import CSV | Add invitation | Remove | Back | Next
- fields: Email address | Planner Plans zones and movements | Participant Takes part in a group
- terms: roles=[planner,participant,root user,group admin,ic] geo=[exit] data=[import,csv]
## D-Create-Participants — Planova · Create event — Step 2 search by name
- headings: Create event | Users and roles | Add people | Event team
- actions: Event details Completed | 2 Users and roles Current step | 3 Groups Not started | 4 Review Not started | Search by name | Invite by email | Import CSV | Add | Remove | Back | Next
- fields: Search by name or email
- terms: roles=[participant,root user,planner,group admin,ic] geo=[exit] data=[import,csv]
## D-Create-Review — Planova · Create event — Step 4 review
- headings: Create event | Review | Before you create | Event details | Timeline | Users and event roles | Groups and group roles
- actions: Event details Completed | Users and roles Completed | Groups Completed | 4 Review Current step | Edit | Back | Create event
- terms: roles=[root user,planner,participant] time=[timeline] live=[location] geo=[exit]
## D-Create-Wizard — Planova · Create event
- headings: Create event | Event details | Basics | Timeline
- actions: 1 Event details Current step | 2 Users and roles Not started | 3 Groups Not started | 4 Review Not started | Add phase | Edit | Delete | Next
- fields: Event name * | Short description * | Location * | Expected attendees * | Category | Public Can be found by others | Private Only people you add
- terms: time=[timeline] live=[location] geo=[exit]
## D-IC-Now — Planova · IC schedule
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Your contacts
- actions: Take attendance · 29/32 | Mark me | Show route | Stop sharing | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check
- terms: roles=[ic,group admin,planner] live=[location] compare=[attendance,present,late,absent] geo=[entrance,exit]
## D-Join — Planova · Join event
- headings: SMU Arts Fest 2026 · Padang Showcase | Create your account to join
- fields: Full name | Email | Mobile number (optional) | Password
- terms: roles=[ic,group admin] live=[location,gps,checkpoint]
## D-MyEvents — Planova · My events
- headings: My events | Good evening, Hazel | What each role can do
- tabs: Ongoing 1 | Upcoming | Past
- actions: Ongoing 1 | Upcoming | Past
- terms: roles=[planner,root user,participant,ic,group admin] live=[live monitor,gps] compare=[attendance]
## D-Participant-Attendance — Planova · Participant takes group attendance
- headings: Kinetic Dance Crew | Attendance | 18:30–18:40 · Go to Backstage
- actions: Back to schedule | All 32 | Present 29 | Late 0 | Absent 0 | Not marked 3 | Mark everyone not marked as present | Present | Late | Absent | Cancel | Send attendance
- terms: roles=[participant,group admin,ic] compare=[attendance,present,late,absent]
## D-Participant-Home — Planova · Participant schedule
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check | Mark me · opens 18:35
- terms: roles=[participant,ic,group admin] compare=[attendance,present,late,absent] geo=[entrance,exit]
## D-Participant-Mark — Planova · Mark myself late
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check | Mark me · opens 18:35
- fields: Present I’m here with the group. | Late I’m on my way. Your IC will expect you. | Absent I can’t make this activity. | Minutes late (optional) | Note (optional)
- terms: roles=[participant,ic,group admin] compare=[late,attendance,present,absent] geo=[entrance,exit]
## D-Planner-Live-NoSignal — Planova · Live monitor, No signal panel
- headings: Live monitor | Event timeline · now 18:26 | No signal · 1 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 4 | On track 2 | Arrived 1 | At risk 1 | No signal 1 | Not tracked 1 | Auto | All names | No names
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,no signal,at risk] change=[shift,hold] compare=[on time] geo=[entrance,exit,no-go]
## D-Planner-Live — Planova · Live monitor
- headings: Live monitor | Event timeline · now 18:26 | Needs attention · 4 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 4 | On track 2 | Arrived 1 | At risk 1 | No signal 1 | Not tracked 1 | Auto | All names | No names
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[attendance,absent,late,on time] geo=[entrance,exit,no-go]
## D-Planner-Overview — Planova · All schedules
- headings: All schedules
- actions: Share schedules with groups | Plan movements | All schedules | Live monitor | Playback | Fix in the plan | Check-in | Rehearsal | Break | Assemble | Wait | Go to Backstage | Perform | Return
- terms: roles=[planner,group admin,ic] live=[live monitor] change=[hold] compare=[attendance,present] geo=[exit,entrance]
## D-Planner-Playback — Planova · Playback
- headings: Playback | Playback time | Groups · planned vs actual | Timestamps · 22 shown
- actions: Plan movements | All schedules | Live monitor | Playback | Auto | All names | No names | Selected route | Problems | All routes | Now | 18:00 Show starts | 18:16 Lion Dance lost signal | 18:30 Kinetic to Backstage
- fields: Time
- terms: roles=[planner,ic] live=[live monitor,no signal,at risk] compare=[on time] geo=[entrance,exit,no-go]
## D-Planner-Timeline-Errors — Planova · New activity with errors
- headings: Plan movements | Event timeline | Groups · 6 of 6 | Groups on the timeline | Ushers and logistics | Timeline · Ushers and logistics
- actions: Share plan with groups | Plan movements | All schedules | Live monitor | Playback | Auto | All names | No names | 18:00 Show starts | 18:16 Lion Dance lost signal | 18:30 Kinetic to Backstage | K Kinetic Dance Crew 18:30–18:40 · Go to Backstage 9 activities | V Voix a cappella 18:30–19:05 · Hold 7 activities | T Taiko Drummers 17:30–19:00 · Assemble 6 activities
- fields: Time | Activity * | Starts * | Ends * | Starts from | Group node (destination) *
- terms: roles=[planner] time=[timeline] live=[live monitor] change=[hold] geo=[entrance,exit,no-go,zone]
## D-Planner-Timeline — Planova · Planner workspace
- headings: Plan movements | Event timeline | Groups · 6 of 6 | Groups on the timeline | Kinetic Dance Crew · Go to Backstage | Timeline · Kinetic Dance Crew
- actions: Share plan with groups | Plan movements | All schedules | Live monitor | Playback | Auto | All names | No names | 18:00 Show starts | 18:16 Lion Dance lost signal | 18:30 Kinetic to Backstage | K Kinetic Dance Crew 18:30–18:40 · Go to Backstage 9 activities | V Voix a cappella 18:30–19:05 · Hold 7 activities | T Taiko Drummers 17:30–19:00 · Assemble 6 activities
- fields: Time | Activity * | Starts * | Ends * | Starts from | Group node (destination) *
- terms: roles=[planner] time=[timeline] live=[live monitor] change=[hold] compare=[attendance] geo=[entrance,exit,no-go,zone]
## D-Planner-Zones — Planova · Venue zones
- headings: Venue zones | Zones · 7 | Zone properties
- actions: Discard | Save zones | Add zone | Main stage Stage | Backstage Restricted | Holding area C Holding | Assembly area B Assembly | Entrance A · St Andrew’s Rd Entrance | Exit · Esplanade Bridge Exit | Cricket pitch No-go | Delete zone
- fields: Name | Type | Capacity | Who can enter
- terms: roles=[planner] live=[live monitor] geo=[entrance,exit,no-go,zone]
## D-Root-AsParticipant — Planova · Root user as participant
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Participant | Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check
- terms: roles=[root user,participant,ic,group admin] compare=[attendance,present,late,absent] geo=[entrance,exit]
## D-Root-Groups — Planova · Groups
- headings: Groups | Not in a group | Kinetic Dance Crew | SMU Symphonic Band | Voix a cappella | Taiko Drummers | Lion Dance Troupe | Ushers and logistics
- actions: Export list | Create group | Move | Appoint IC
- terms: roles=[root user,group admin,ic] data=[export]
## D-Root-Overview — Planova · Event overview
- headings: Event overview | SMU Arts Fest 2026 · Padang Showcase | Setup checklist | Invite link | Waiting for approval | Recent activity
- actions: Edit event | Root user | Show QR code | Approve
- terms: roles=[root user,participant,ic] geo=[no-go,zone]
## D-Root-Participants — Planova · Participants and roles
- headings: Participants and roles | Daniel Koh
- actions: Import CSV | Invite people | All roles | Planners 2 | Group Admins 6 | ICs 7 | To approve 3 | Move to group | Change role | Remove from event | Approve | Resend | Save changes
- fields: Group | Participant Sees their group’s schedule. | IC Leads the group and shares GPS on the live map. | Group Admin Manages members and attendance for one group. | Planner Plans zones and movements for the whole event.
- terms: roles=[root user,planner,group admin,ic,participant] live=[gps] compare=[attendance] data=[import,csv]
## D-Stress-Live-Late — Planova · Stress live monitor, Late panel
- headings: Live monitor | Event timeline · now 18:26 | Late · 2 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 6 | On track 24 | Arrived 1 | At risk 1 | Late 2 | No signal 2 | 10 | 11 | 12
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[late,on time] geo=[no-go,zone,entrance,exit]
## D-Stress-Live — Planova · Stress live monitor
- headings: Live monitor | Event timeline · now 18:26 | Needs attention · 6 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 6 | On track 24 | Arrived 1 | At risk 1 | Late 2 | No signal 2 | 10 | 11 | 12
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[late,attendance,absent,on time] geo=[zone,no-go,entrance,exit]
## D-Stress-Overview — Planova · Stress schedules, 30 groups
- headings: All schedules
- actions: Share schedules with groups | Plan movements | All schedules | Live monitor | Playback | Fix in the plan | Arrive and check in | Assemble | Watch from the audience | Hold | Go to Backstage | Perform | Return to Backstage | Dismiss
- terms: roles=[planner,group admin,ic] live=[live monitor] change=[hold] compare=[attendance,present] geo=[no-go,zone,entrance,exit]
## D-Stress-Plan — Planova · Stress plan, 30 groups
- headings: Plan movements | Event timeline | Groups · 30 of 30 | Groups on the timeline | Kinetic Dance Crew · Perform | Timeline · Kinetic Dance Crew
- actions: Share plan with groups | Plan movements | All schedules | Live monitor | Playback | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18
- fields: Time | Activity * | Starts * | Ends * | Starts from | Group node (destination) *
- terms: roles=[planner] time=[timeline] live=[live monitor] change=[hold] compare=[attendance] geo=[no-go,zone,entrance,exit]
## D-Stress-Playback — Planova · Stress playback
- headings: Playback | Playback time | Groups · planned vs actual | Timestamps · 34 shown
- actions: Plan movements | All schedules | Live monitor | Playback | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19
- fields: Time
- terms: roles=[planner] live=[live monitor,no signal,at risk] change=[hold] compare=[late,on time] geo=[zone,entrance,exit,no-go]
## Main — Planova · Log in
- headings: Plan the venue. Move every group on time. | Log in
- fields: Email | Password | Keep me logged in on this device
- terms: roles=[ic] compare=[on time] geo=[no-go]

# MOBILE

## M-Admin-Attendance — Planova mobile · Attendance, Not marked
- headings: Kinetic Dance Crew | Attendance | 18:30–18:40 · Go to Backstage
- actions: Back to schedule | All 32 | Present 29 | Late 0 | Absent 0 | Not marked 3 | Mark everyone not marked as present | Present | Late | Absent | Cancel | Send attendance
- terms: roles=[group admin] compare=[attendance,present,late,absent]
## M-Admin-Group — Planova mobile · Group Admin route sheet
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Members needing attention | Your contacts
- actions: Group Admin | IC | Take attendance · 29/32 | Mark me | Show route | Stop sharing | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check
- terms: roles=[group admin,ic,planner] live=[location] compare=[attendance,present,late,absent] geo=[entrance,exit]
## M-Admin-Members-Error — Planova mobile · Add member error
- headings: Members | Add people to Kinetic Dance Crew | Group members
- actions: Add | All 32 | ICs 2 | Invite pending 2 | Remove IC | Remove | Make IC | Show all 32
- fields: Name or email | Also make them an IC · their phone shares its location with Planners while they’re IC
- terms: roles=[group admin,ic,planner] live=[location] compare=[attendance]
## M-Admin-Members — Planova mobile · Group members
- headings: Members | Add people to Kinetic Dance Crew | Group members
- actions: Add | All 32 | ICs 2 | Invite pending 2 | Remove IC | Remove | Make IC | Show all 32
- fields: Name or email | Also make them an IC · their phone shares its location with Planners while they’re IC
- terms: roles=[group admin,ic] live=[location] compare=[attendance]
## M-Attendance-Late — Planova mobile · Attendance, Late with notes
- headings: Kinetic Dance Crew | Attendance | 17:30–18:20 · Assemble
- actions: Back to schedule | All 32 | Present 29 | Late 1 | Absent 2 | Not marked 0 | Edit attendance
- terms: roles=[group admin] compare=[attendance,late,present,absent]
## M-Create-Details — Planova mobile · Create event (interactive)
- headings: Create event | Event details | Basics | Timeline
- actions: 1 Event details Current step | 2 Users and roles Not started | 3 Groups Not started | 4 Review Not started | Add phase | Edit | Delete | Next
- fields: Event name * | Short description * | Location * | Expected attendees * | Category | Public Can be found by others | Private Only people you add
- terms: time=[timeline] live=[location] geo=[exit]
## M-Create-Errors — Planova mobile · Create event — validation errors
- headings: Create event | Event details | Basics | Timeline
- actions: 1 Event details Needs attention | 2 Users and roles Not started | 3 Groups Not started | 4 Review Not started | Add phase | Edit | Delete | Next
- fields: Event name * | Short description * | Location * | Expected attendees * | Category | Public Can be found by others | Private Only people you add
- terms: time=[timeline] live=[location] geo=[exit]
## M-Create-Groups — Planova mobile · Create event — Groups
- headings: Create event | Groups
- actions: Event details Completed | Users and roles Completed | 3 Groups Current step | 4 Review Not started | Create group | Show ungrouped | Edit group | Back | Next
- fields: Group name
- terms: roles=[ic,group admin] geo=[exit]
## M-Create-Participants — Planova mobile · Create event — CSV import
- headings: Create event | Users and roles | Add people | Event team
- actions: Event details Completed | 2 Users and roles Current step | 3 Groups Not started | 4 Review Not started | Search by name | Invite by email | Import CSV | Choose another file | Add 4 people | Remove | Back | Next
- terms: roles=[root user,planner,participant,group admin,ic] geo=[exit] data=[csv,import]
## M-Create-Review — Planova mobile · Create event — Review
- headings: Create event | Review | Before you create | Event details | Timeline | Users and event roles | Groups and group roles
- actions: Event details Completed | Users and roles Completed | Groups Completed | 4 Review Current step | Edit | Back | Create event
- terms: roles=[root user,planner,participant] time=[timeline] live=[location] geo=[exit]
## M-IC-Attendance — Planova mobile · IC takes attendance
- headings: Kinetic Dance Crew | Attendance | 18:30–18:40 · Go to Backstage
- actions: Back to schedule | All 32 | Present 29 | Late 0 | Absent 0 | Not marked 3 | Mark everyone not marked as present | Present | Late | Absent | Cancel | Send attendance
- terms: roles=[ic,group admin] compare=[attendance,present,late,absent]
## M-IC-Location-Off — Planova mobile · IC location off
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Your contacts
- actions: Take attendance · 29/32 | Mark me | Show route | Share my location | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check
- terms: roles=[ic,group admin,planner] live=[location,no signal] compare=[attendance,present,late,absent] geo=[entrance,exit]
## M-IC-Now — Planova mobile · IC schedule
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Your contacts
- actions: Take attendance · 29/32 | Mark me | Show route | Stop sharing | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check
- terms: roles=[ic,group admin,planner] live=[location] compare=[attendance,present,late,absent] geo=[entrance,exit]
## M-Join — Planova mobile · Join event
- headings: Join event | SMU Arts Fest 2026 · Padang Showcase
- fields: Full name | Email | Password
- terms: roles=[ic] live=[location]
## M-MyEvents — Planova mobile · My events
- headings: My events
- actions: Ongoing | Upcoming | Past
- terms: roles=[planner,root user,participant,ic,group admin]
## M-Participant-Attendance — Planova mobile · Participant takes group attendance
- headings: Kinetic Dance Crew | Attendance | 18:30–18:40 · Go to Backstage
- actions: Back to schedule | All 32 | Present 29 | Late 0 | Absent 0 | Not marked 3 | Mark everyone not marked as present | Present | Late | Absent | Cancel | Send attendance
- terms: roles=[participant,group admin] compare=[attendance,present,late,absent]
## M-Participant-Checkin — Planova mobile · Mark myself absent (error)
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check | Mark me · opens 18:35
- fields: Present I’m here with the group. | Late I’m on my way. Your IC will expect you. | Absent I can’t make this activity. | Reason (required)
- terms: roles=[participant,ic,group admin] compare=[absent,attendance,present,late] geo=[entrance,exit]
## M-Participant-Home — Planova mobile · Participant route sheet
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check | Mark me · opens 18:35
- terms: roles=[participant,ic,group admin] compare=[attendance,present,late,absent] geo=[entrance,exit]
## M-Planner-Live-Detail — Planova mobile · Live monitor, At risk panel
- headings: Live monitor | Event timeline · now 18:26 | At risk · 1 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 4 | On track 2 | Arrived 1 | At risk 1 | No signal 1 | Not tracked 1 | Auto | All names | No names
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[on time] geo=[entrance,exit,no-go]
## M-Planner-Live — Planova mobile · Live monitor
- headings: Live monitor | Event timeline · now 18:26 | Needs attention · 4 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 4 | On track 2 | Arrived 1 | At risk 1 | No signal 1 | Not tracked 1 | Auto | All names | No names
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[attendance,absent,late,on time] geo=[entrance,exit,no-go]
## M-Planner-Overview — Planova mobile · All schedules
- headings: All schedules
- actions: Share schedules with groups | Plan movements | All schedules | Live monitor | Playback | Fix in the plan | Check-in | Rehearsal | Break | Assemble | Wait | Go to Backstage | Perform | Return
- terms: roles=[planner,group admin,ic] live=[live monitor] change=[hold] compare=[attendance,present] geo=[exit,entrance]
## M-Planner-Playback — Planova mobile · Playback
- headings: Playback | Playback time | Groups · planned vs actual | Timestamps · 22 shown
- actions: Plan movements | All schedules | Live monitor | Playback | Auto | All names | No names | Selected route | Problems | All routes | Now | 18:00 Show starts | 18:16 Lion Dance lost signal | 18:30 Kinetic to Backstage
- fields: Time
- terms: roles=[planner,ic] live=[live monitor,no signal,at risk] compare=[on time] geo=[entrance,exit,no-go]
## M-Planner-Timeline — Planova mobile · Plan movements
- headings: Plan movements | Event timeline | Groups · 6 of 6 | Groups on the timeline | Kinetic Dance Crew · Go to Backstage | Timeline · Kinetic Dance Crew
- actions: Share plan with groups | Plan movements | All schedules | Live monitor | Playback | Undo point | Done | Auto | All names | No names | 18:00 Show starts | 18:16 Lion Dance lost signal | 18:30 Kinetic to Backstage | K Kinetic Dance Crew 18:30–18:40 · Go to Backstage 9 activities
- fields: Time | Activity * | Starts * | Ends * | Starts from | Group node (destination) *
- terms: roles=[planner] time=[timeline] live=[live monitor] change=[hold] compare=[attendance] geo=[entrance,exit,no-go,zone]
## M-Planner-Zones — Planova mobile · Venue zones
- headings: Padang Showcase
- tabs: Zones | Plan | Live | Playback
- actions: Save | Edit details | Delete
- terms: roles=[planner] geo=[no-go]
## M-Root-AsParticipant — Planova mobile · Root user as participant
- headings: Kinetic Dance Crew | 18:30–18:40 · Go to Backstage | Today’s schedule | Need help?
- actions: Participant | Take attendance · 29/32 | Mark me | Show route | 14:00 –14:30 Check-in · Entrance A Done · 260 m · attendance check | Present | 31/32 · View | 14:30 –16:30 Rehearsal · Main stage Done · 190 m · attendance check | 16:30 –17:30 Break · Holding C Done · 160 m · attendance check | 17:30 –18:20 Assemble · Assembly B Done · 150 m · attendance check | 30/32 · View | 18:20 –18:30 Wait · Holding C Done · 150 m · attendance check | 18:30 –18:40 Go to Backstage Next · from Holding C · 120 m · attendance check | 18:40 –18:52 Perform · Main stage From Backstage · 130 m · attendance check
- terms: roles=[root user,participant,ic,group admin] compare=[attendance,present,late,absent] geo=[entrance,exit]
## M-Root-Groups — Planova mobile · Groups
- headings: Padang Showcase
- tabs: Overview | People 3 | Groups | Settings
- actions: Appoint IC
- terms: roles=[root user,admin,ic]
## M-Root-Invite — Planova mobile · Share invite link
- headings: Padang Showcase | Share invite link
- tabs: Overview | People | Groups
- actions: Share link
- fields: Approve each new person 3 waiting now | Link expires
- terms: roles=[root user]
## M-Root-Overview — Planova mobile · Event overview
- headings: Padang Showcase
- tabs: Overview | People 3 | Groups | Settings
- actions: Root user
- terms: roles=[root user,participant,ic]
## M-Root-Participants — Planova mobile · Participants
- headings: Padang Showcase
- tabs: Overview | People 3 | Groups | Settings
- actions: All | To approve 3 | ICs 7 | Admins 6 | Save changes
- fields: Participant | IC Leads the group and shares GPS on the live map. | Group Admin | Planner | Group
- terms: roles=[root user,planner,group admin,ic,participant] live=[gps]
## M-SignIn — Planova mobile · Log in
- headings: Plan the venue. Move every group on time. | Log in
- fields: Email | Password
- terms: compare=[on time]
## M-Stress-Live — Planova mobile · Stress live monitor
- headings: Live monitor | Event timeline · now 18:26 | Needs attention · 6 | Groups · planned vs actual | Groups on the timeline
- actions: Message all ICs | Plan movements | All schedules | Live monitor | Playback | Needs attention 6 | On track 24 | Arrived 1 | At risk 1 | Late 2 | No signal 2 | 10 | 11 | 12
- fields: Time
- terms: roles=[planner,ic] time=[timeline] live=[live monitor,at risk,no signal] change=[shift,hold] compare=[late,attendance,absent,on time] geo=[zone,no-go,entrance,exit]
## M-Stress-Overview — Planova mobile · Stress schedules
- headings: All schedules
- actions: Share schedules with groups | Plan movements | All schedules | Live monitor | Playback | Fix in the plan | Arrive and check in | Assemble | Watch from the audience | Hold | Go to Backstage | Perform | Return to Backstage | Dismiss
- terms: roles=[planner,group admin,ic] live=[live monitor] change=[hold] compare=[attendance,present] geo=[no-go,zone,entrance,exit]
## M-Stress-Plan — Planova mobile · Stress plan
- headings: Plan movements | Event timeline | Groups · 30 of 30 | Groups on the timeline | Kinetic Dance Crew · Perform | Timeline · Kinetic Dance Crew
- actions: Share plan with groups | Plan movements | All schedules | Live monitor | Playback | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18
- fields: Time | Activity * | Starts * | Ends * | Starts from | Group node (destination) *
- terms: roles=[planner] time=[timeline] live=[live monitor] change=[hold] compare=[attendance] geo=[no-go,zone,entrance,exit]
## M-Stress-Playback — Planova mobile · Stress playback
- headings: Playback | Playback time | Groups · planned vs actual | Timestamps · 34 shown
- actions: Plan movements | All schedules | Live monitor | Playback | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19
- fields: Time
- terms: roles=[planner] live=[live monitor,no signal,at risk] change=[hold] compare=[late,on time] geo=[zone,entrance,exit,no-go]

# TERM TOTALS

- roles: 169
- time: 18
- live: 68
- change: 26
- compare: 126
- geo: 114
- data: 11
- notify: 0