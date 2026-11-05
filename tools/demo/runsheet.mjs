// node runsheet.mjs <docs/demo/planova-demo-script.html>: rebuilds the run sheet from SEGMENTS below, keeping the page's styles
import fs from 'node:fs'
const file = process.argv[2]
const old = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n')
let head = old.slice(0, old.indexOf('<main>'))
// A sixth speaker colour (Kenneth), light and dark
head = head
  .replace('--s5: #8a5a2b;\n', '--s5: #8a5a2b; --s6: #6b3fa0;\n')
  .replaceAll('--s5: #e0a872; color-scheme: dark', '--s5: #e0a872; --s6: #c3a6f0; color-scheme: dark')
if (!head.includes('--s6')) throw new Error('speaker colours not found')

const WHO = { Komin: 's1', rui: 's2', Hazel: 's3', Ern: 's4', Linus: 's5', Kenneth: 's6' }
const esc = (s) => s.replace(/&(?!amp;|lt;|gt;)/g, '&amp;')

// [title, short label, seconds, speaker, on screen[], say, tags[]]
const SEGMENTS = [
  ['Intro, roles and how it works', 'Intro', 50, 'Komin',
    ['Home: the live event card, then Ongoing, Upcoming and Archive', 'One slide, "Under the hood": website and phone app → Supabase database → OneMap'],
    "Hi, we're Group 11, and this is Planova. Think of an NDP rehearsal: dozens of contingents, one venue, and everyone has to be in the right place at the right moment. Planova lets you plan where every group goes, and on the day, see where they actually are. What you see depends on your role. The root sets up the event, planners build the plan, and everyone else is in a group, led by a Group Admin and an IC whose phone shares its location. It all runs on a Supabase database that also enforces those roles, with maps from OneMap. rui?",
    ['Problem', 'Roles', 'Data store', 'External API']],
  ['Create an event', 'Create', 40, 'rui',
    ['Create event. Type as you talk: NDP Rehearsal 4, the Padang, Saturday 6 pm', 'People: type an email, Add', 'Groups: Navy and Air Force; tick an IC and a Group Admin', 'Review → Create event → Overview: code, QR, invite link'],
    "Thanks, Komin. Making an event takes four steps. The details first: NDP Rehearsal 4, at the Padang, Saturday at six. You can add people by their exact email, though most will just join with a code. Then the groups, Navy and Air Force, each with an IC and a Group Admin. Review, Create, and we're on the Overview, with a join code, a QR code, and an invite link that goes straight into WhatsApp or Telegram.",
    ['Wizard', 'Invite']],
  ['Draw the venue', 'Map', 40, 'Hazel',
    ['Cut to the NE4 event, Map page: the Padang as built for the parade (the floor, the three stands, the formation rows), and around it the posts from the NDP 25 Main map (KML): control stations, ACPs, medical posts, QRTs, the holding area and casing pens', 'Draw area: tap the corners of Esplanade Park, name it, type No-Go, Save', 'Padlock the Padang'],
    "Every plan starts with the venue, and this is the real NDP 25 layout. It came to us as a Google Earth file: just pins and unnamed outlines. In Planova, each one is an area with a name and a type, like an entrance, a medical post or a No-Go area. To add one, tap the corners, name it, pick the type. Esplanade Park is No-Go tonight, so anyone who wanders in lights up on the live map. And the Padang is locked, so nobody moves it by accident.",
    ['External API', 'Map', 'Real NDP 25 map (KML)']],
  ['Build the timeline', 'Timeline', 70, 'Linus',
    ['Timeline: a new plan; Place on map for two groups', 'Add a frame at +5:00 and drag the badges', 'Import the NE4 show matrix CSV: 13 groups, 418 moments', 'Play at 60×, then 120×; Ctrl + wheel to zoom', 'Shift-click a stretch of frames, Delete, then Undo'],
    "Now the plan itself. A plan is a row of frames, each one a moment counted from T+0, when the clock starts. In the first frame we place each group on the map, then add a frame five minutes in and drag them to the formation area, and the app works out the walk in between. A real rehearsal is hundreds of moments, so run sheets come in as a CSV. This is the actual NE4 show matrix: thirteen groups, four hundred and eighteen moments. And a group can walk, take a bus or follow a float, so how far it moves between moments is the planner's call. Press Play, and every contingent walks its route, at sixty or a hundred and twenty times speed. Zoom keeps your frame in view, you can delete a whole stretch at once, and one Undo brings it back.",
    ['Timeline', 'CSV import', 'Playback of the plan']],
  ['Problems, and two planners at once', 'Problems', 45, 'Linus',
    ['A second planner nudges a badge: it moves here too, held for them while they drag', 'A badge walked straight through the No-Go area from segment 3: the Problems panel shows the error', 'Publish is locked while there is an error; Undo puts the badge back, and the error clears', 'Publish'],
    "Two planners can edit at once. When my teammate nudges a badge, it moves on my screen too, held for them until they let go. Under the timeline, the Problems panel checks the plan as you go. If I send a group straight through the No-Go area we drew earlier, it's flagged straight away, with the group and the frames, and Publish stays locked until it's fixed. One Undo puts it back, the problem clears, and now we can publish. That's the version every phone follows.",
    ['Problems', 'No-Go check', 'Plan locks', 'Publish']],
  ['Groups and people', 'Groups', 30, 'Kenneth',
    ['Groups: add one with its colour, sector and radio channel; tick its IC; delete a group', 'People: search, filter by group, change a role, set an IC\'s arrival radius'],
    "Groups and people can change any time before the event. On Groups we add a group with its colour, sector and radio channel, tick its IC, or delete one we don't need. The People page lists everyone. Planners change roles there, and set how close an IC has to be before their group counts as arrived.",
    ['Groups', 'People', 'Roles']],
  ['Rehearsals', 'Reh', 30, 'Ern',
    ['Rehearsals: add one before the event day, with a note; then change its time', 'As a member: Not available, with a reason', 'As a planner: approve or turn down'],
    "Rehearsals get their own calendar, always before the event day. Planners add each one with a note and can move it later. If a member can't make it, they send a not-available request, one per day, and a planner approves or turns it down before it starts. Move a rehearsal, and those answers reset, so nobody's excused for the wrong time.",
    ['Rehearsals']],
  ['Taking attendance', 'Roll call', 35, 'Ern',
    ['Attendance: New roll call → By hand; mark present or excused; Close → who\'s absent', 'QR roll call: the code on the IC\'s phone changes every 5 s; a member scans it'],
    "On the day, the IC takes attendance. By hand, they mark each person present or excused, and closing the roll call shows who's missing straight away. For a contingent of thirty, QR is quicker. The code on the IC's phone changes every five seconds, so a screenshot in a group chat won't work. Everyone scans it, and they're marked present as they go.",
    ['Attendance', 'QR']],
  ['Run it live', 'Live', 55, 'Komin',
    ['Start now → the NE4 plan → T+0: Now → Start event', 'Remind ICs', 'Live page, Operations: the clock; under way, due soon, no signal', 'Move the salute a minute later, Publish again; the IC\'s phone: "Your times changed"'],
    "Right, let's go live. Press Start now, pick the published plan, and set T+0 to now. It's 17:55 on the NE4 night, and Contingents 1 and 2 are already marching onto the Padang. Any IC who isn't sharing gets a reminder, and Remind ICs nudges them again. The Live page opens on Operations: every group against the plan, who's under way, who's due soon, and who's lost signal. And shows slip. Between NE2 and NE4, it was by up to six minutes. So we move the salute, publish again, and every phone affected is told its times have changed.",
    ['Start', 'Operations', 'Push']],
  ['What members and ICs see', 'ICs', 70, 'Hazel',
    ['The phone app as the Contingent 3 IC: Now, Map, Group, Info, More', 'Now: the route on a map, the stops, a countdown, LATE; tap We\'re here', 'Share my location → the set-up screens; lock the phone; the notification with Stop'],
    "So what does an IC see on their phone? Members get the same, just without location sharing. The Now tab shows where their group should be: the route on a map, each stop in order, and a countdown to the next one. Corners they only walk through stay out of the list. If a moment passes and nobody's marked the group, it turns late. When they get there, the IC taps We're here. Once the event's live, the IC taps Share my location. The first time, the app walks them through their phone settings, then it keeps sharing even with the screen off. And when the IC gets close enough, the group's marked arrived on its own.",
    ['Phone app', 'Schedule', 'Sharing']],
  ['Live location', 'Tracking', 35, 'rui',
    ['Live page, On the map: the IC\'s badge moving from the casing location to the Padang', 'Click the badge; the dashed plan line'],
    "Here's our Contingent 3 IC heading for the Padang, and their badge moves with them. For this video the location is simulated; on the day it's real GPS. Click the badge to see the group, the area they're in, and when the phone last checked in. The dashed line is where the plan says they should be, so drifting off is easy to spot. Only ICs share, and only while the event's live.",
    ['GPS', 'Live map']],
  ['Messages and SOS', 'SOS', 45, 'Ern',
    ['Live page → Message everyone: Running late, To: Everyone, Send', 'The phone\'s banner, Got it; who has read it', 'A member presses SOS: the red banner with who and where; I\'m on my way; Mark handled'],
    "Messages go out from the Live page. There are quick ones for running late, wet weather or lightning, and you choose who gets it: everyone, the ICs and admins, the planners, or one sector. It arrives as a banner that stays until they tap Got it, and planners can see who's read it. In an emergency, anyone can press SOS. Everyone gets a red banner with who and where, and responders tap I'm on my way.",
    ['Broadcasts', 'SOS']],
  ['End and playback', 'Playback', 55, 'rui',
    ['End event → type END; the phones stop sharing; a minute later the live map clears', 'Playback: open the run, drag to any moment, play faster, trails, follow one IC', 'Rename the recording; Download CSV'],
    "When it's over, End event asks you to type END, and every phone stops sharing. A minute later the live map clears, ready for the next run. Every run is saved on the Playback page. We can drag to any moment, speed it up, show each group's trail, or follow one person. Give the recording a proper name, like NE4 full dress, and it's kept for seven days. We can also download it as a CSV and load it back anytime for the debrief.",
    ['End', 'Playback', 'CSV export']],
  ['The planner\'s phone', 'Phone', 20, 'Kenneth',
    ['The real phone, now a planner\'s: Ops, Map, Timeline (undo and redo by the zoom), People, More, tapped through over USB'],
    "And planners don't need a laptop on the day. The phone app runs the whole event, with Ops, Map, Timeline and People, undo included.",
    ['Phone app']],
  ['How we tested it', 'Tests', 55, 'Kenneth',
    ['Slide: 114 unit tests, 71 end-to-end tests, 954 database checks, every page at 320 px, the 1,000-phone run', 'Terminal clip of the end-to-end run going green, sped up 4×'],
    "Everything you've seen is tested automatically, and on the real NE4 data. Seventy-one end-to-end tests sign in as every role, each in its own browser, and go from building the plan to the replay. They check the database, not just the screen, so a member really can't see another group. Under those sit a hundred and fourteen unit tests and over nine hundred and fifty database checks, which run every rule and permission against a real copy of our schema. Every page is also checked on a 320-pixel phone, and we ran a whole NE4 night with a thousand virtual phones. That found one slow query, which we fixed before the rehearsal.",
    ['Testing']],
  ['Close', 'End', 20, 'Komin',
    ['Back to the Overview; end slide with the site, the repo and the six names'],
    "So that's Planova: draw the venue, plan every group, run it live, and play it back afterwards. It's live at gpstesting.vercel.app. Thanks for watching!",
    []],
]

const clock = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
let t = 0
const rows = SEGMENTS.map(([title, short, secs, who, screen, say, tags], i) => {
  const r = { n: i + 1, title, short, secs, who, screen, say, tags, at: t, words: say.split(/\s+/).length }
  t += secs
  return r
})
const total = t
const spare = 720 - total
const words = rows.reduce((n, r) => n + r.words, 0)
const two = (n) => String(n).padStart(2, '0')
const per = Object.keys(WHO).map((name) => ({ name, segs: rows.filter((r) => r.who === name), secs: rows.filter((r) => r.who === name).reduce((n, r) => n + r.secs, 0) }))

const seg = (r) => `
    <article class="seg" id="s${r.n}">
      <div class="clock"><span class="t">${clock(r.at)}</span><span class="d">${r.secs} s</span><span class="who" style="background:var(--${WHO[r.who]})">${r.who}</span></div>
      <div class="body">
        <h3>${esc(r.title)}</h3>
        <div class="cols">
          <div><div class="label">On screen</div><ul class="do">${r.screen.map((s) => `<li>${esc(s)}</li>`).join('')}</ul></div>
          <div class="say"><div class="label">Say</div>
            <p>${esc(r.say)}</p></div>
        </div>${r.tags.length ? `\n        <div class="shows">${r.tags.map((x) => `<span class="tag">${esc(x)}</span>`).join('')}</div>` : ''}
      </div>
    </article>`

const at = (name) => rows.filter((r) => r.title.startsWith(name)).map((r) => clock(r.at)).join(' · ')

const body = `<main>
  <header>
    <div class="eyebrow">IS216 G11 · Final presentation video</div>
    <h1>Planova demo run sheet</h1>
    <p class="lede">The team's narrated walkthrough, fitted to the 12-minute limit and run on the real NDP 2025 NE4 data. It covers every feature in the app as of 4 Nov, after the last UI update: the event wizard, the venue map, the timeline with its Problems panel, groups, rehearsals, attendance, the live run, the phone app, messages and SOS, playback and testing. Six speakers share it, each voicing the parts closest to what they built.</p>
    <div class="facts">
      <span class="fact">Limit <b>12:00</b></span>
      <span class="fact">Planned <b>${clock(total)}</b></span>
      <span class="fact">${rows.length} segments</span>
      <span class="fact">6 speakers</span>
      <span class="fact">Export <b>1080p</b>, YouTube unlisted</span>
    </div>
  </header>

  <section aria-labelledby="h-strip">
    <h2 id="h-strip">The twelve minutes, to scale</h2>
    <div class="strip" role="list">
${rows.map((r) => `      <a role="listitem" href="#s${r.n}" style="flex:${r.secs};background:var(--${WHO[r.who]})" title="${clock(r.at)} ${esc(r.title)} (${r.who})">${esc(r.short)}</a>`).join('\n')}
      <span class="strip buf" style="flex:${spare}" title="Spare ${spare} s"></span>
    </div>
    <div class="ticks"><span>0:00</span><span>3:00</span><span>6:00</span><span>9:00</span><span>12:00</span></div>
    <div class="legend">
${per.map((p) => `      <span><i class="dot" style="background:var(--${WHO[p.name]})"></i>${p.name} · ${p.segs.map((r) => two(r.n)).join(', ')} · ${p.secs} s</span>`).join('\n')}
    </div>
  </section>

  <section aria-labelledby="h-scen">
    <h2 id="h-scen">The night we demo</h2>
    <p class="lede">Segment 2 creates a small event live: NDP Rehearsal 4, with groups Navy and Air Force. From segment 3 on, we cut to the prepared event "NDP 2025 NE4 Rehearsal", made fresh for the take by <code>node tools/demo/seed-ndp-demo.mjs</code> (dated a week ahead, so a rehearsal can go before it). Its plan is a 95-minute slice of the real NE4 show matrix (17 Jul) on the NDP 25 map, with 13 groups. Start it with T+0 = Now, and the contingents are already marching.</p>
    <p class="lede">The venue is the real one too, 43 areas in all. The Padang is laid out as it is built for the parade: a <b>Performance Floor</b> (a Stage) with the big <b>East Stand</b> along Connaught Drive, a <b>North Stand</b> and a <b>South Stand</b> at the ends, and the St Andrew's Road side open. On the floor are the formation rows, from the front: the <b>State Colours</b>, the <b>Guard of Honour</b>, the <b>Regimental Colours Party</b>, the uniformed <b>Contingents</b>, the <b>Youth Uniform Groups</b>, the <b>Social and Economic Groups</b>, the <b>Combined Band</b> and the <b>Centre Stage</b>. Around the field are the casing location and 29 areas from the NDP 25 Main map (KML), each on its own coordinates. The 22 named posts are drawn as small squares: control stations (PCS, VCS, DCS), access control points ACP 1–6 as Entrances, Medical Posts 1–3 and the VVIP Medical Post, and QRT 1–2. The KML's seven small unnamed outlines are drawn as they are, and named by us: the War Memorial Holding Area, Casing Pens A–C, a Marshalling Point, a Water Point, and the Fullerton Assembly Area. <code>tools/demo/ndp-kml-areas.mjs</code> turns the KML into <code>docs/demo/ndp25-areas.json</code>.</p>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Plan time</th><th>Show time</th><th>Show matrix cue</th><th>What moves on the map</th></tr></thead>
        <tbody>
          <tr><td class="t">T+0:00</td><td class="t">17:54:50</td><td>Parade &amp; Ceremony</td><td>Contingents 1 and 2 marching from the casing location to the Padang</td></tr>
          <tr><td class="t">T+0:30</td><td class="t">17:55:20</td><td>Parade &amp; Ceremony</td><td>Contingent 3 (the IC's phone) steps off; 4 follows a minute later</td></tr>
          <tr><td class="t">T+2:55</td><td class="t">17:57:45</td><td>Combined Salute</td><td>Red Lions to the salute line</td></tr>
          <tr><td class="t">T+7:40</td><td class="t">18:02:30</td><td>Combined School Marching Bands</td><td>Bands in, out at T+17:40</td></tr>
          <tr><td class="t">T+58:30</td><td class="t">18:53:20</td><td>Mobile Column</td><td>Mobile Column drives its route</td></tr>
          <tr><td class="t">T+79:30</td><td class="t">19:14:20</td><td>Contingents march off</td><td>Back to the casing location</td></tr>
        </tbody>
      </table>
    </div>
    <p class="note">Between the NE2 (3 Jul) and NE4 (17 Jul) rehearsals the show slipped by up to six minutes (End of Broadcast 20:29 → 20:35). That's the slip segment 9 uses to show Publish again. File: <code>docs/demo/ndp-ne4-demo.csv</code>. There's no distance or speed rule any more (migration 091): the one check is that no walk crosses a No-Go area or an obstacle.</p>
  </section>

  <section aria-labelledby="h-run">
    <h2 id="h-run">Run of show</h2>
${rows.map(seg).join('\n')}
  </section>

  <section aria-labelledby="h-fit">
    <h2 id="h-fit">Will it fit in 12 minutes?</h2>
    <p class="lede">Yes, with ${clock(spare)} to spare. The narration is ${words.toLocaleString('en-SG')} words, about ${clock(Math.round((words / 145) * 60))} at a relaxed 145 words a minute. The rest of each slot is for clicks, so the clicking happens while you talk. Every segment's lines fit inside its slot.</p>
    <div class="grid2">
      <div class="card">
        <h3>Keep it inside the slot</h3>
        <ul>
          <li>Talk over your clip while it plays, and keep to your lines. Cut, don't re-explain.</li>
          <li>Still moments over 1.5 s are cut out of the recording already, so the clips have no waiting in them.</li>
          <li>A voice-over longer than its clip is fine: the last frame holds. Far over the slot isn't.</li>
        </ul>
      </div>
      <div class="card">
        <h3>If the cut runs long, trim in this order</h3>
        <ol>
          <li>The planner's phone (20 s): drop it; it's in the phone shots of segment 10 too.</li>
          <li>Playback (55 s → 40 s): skip the trails and Follow.</li>
          <li>Groups and people (30 s → 15 s): one group, no People page.</li>
          <li>Members and ICs (70 s → 55 s): skip the set-up screens.</li>
        </ol>
        <p class="note">Never cut the intro, the timeline, the live run, SOS or testing. The intro and testing segments carry what the brief marks.</p>
      </div>
    </div>
  </section>

  <section aria-labelledby="h-rec">
    <h2 id="h-rec">Before you hit record</h2>
    <div class="card" data-note="realistic">
      <h3>Make it look real</h3>
      <p class="note">On the website and on the phone, the recording should look like a person using Planova on a real rehearsal night, not a script clicking through it.</p>
      <ul>
        <li><b>Move like a person.</b> The cursor travels in a gentle curve and slows as it arrives, lands inside the button rather than dead centre, and pauses a beat before clicking. Typing has a natural, uneven rhythm. The recording script does this for you; when recording by hand, don't jump straight to buttons.</li>
        <li><b>No long pauses.</b> Every still moment longer than 1.5 s is cut from the video. While a page loads or the plan plays, talk over it rather than waiting.</li>
        <li><b>Real situations, accurately.</b> Use the real NE4 show matrix and its real times: Contingents 1 and 2 already marching at 17:55, Contingent 3 stepping off at T+0:30, the salute slipping a minute. Real names (P&amp;C Contingent 3, Red Lions), real places (the casing location, the Padang), and messages a planner would actually send ("Red Lions running 1 min late. Hold salute positions.").</li>
        <li><b>Show results, not just clicks.</b> After each action, let the result be seen: the badge moving, the "Your times changed" alert on the phone, the SOS banner, the problem clearing. Only then move on.</li>
        <li><b>One flow, in order.</b> Each segment carries on from the last on the same event: the plan built in segments 4–5 is the one that goes live in segment 9 and is played back in segment 13.</li>
        <li><b>The phone too.</b> Do Not Disturb on with Planova allowed, so no other app's banner appears; taps shown as dots; the phone stays on the event, as an IC would hold it.</li>
      </ul>
    </div>
    <div class="grid2">
      <div class="card">
        <h3>Accounts and devices</h3>
        <ul>
          <li>Root on the laptop; a planner in a second window, for segment 5's two-planner edit. The recording script signs both in.</li>
          <li>The phone with the APK built on 4 Nov, joined to the demo event and added to P&amp;C Contingent 3; location on, notifications allowed.</li>
          <li>No one walks: the IC's location is simulated by <code>tools/demo/director.mjs</code>, moving from the casing location to the Padang.</li>
          <li>The QA accounts show as "QA Root" and so on. Rename them on the Profile page, or say they're test accounts.</li>
        </ul>
      </div>
      <div class="card">
        <h3>Data</h3>
        <ul>
          <li>A fresh demo event for each take: <code>node tools/demo/seed-ndp-demo.mjs</code> prints its join code. Don't reuse 5F6QRS: it's dated 3 Nov, so no rehearsal can go before it.</li>
          <li>The show matrix CSV, <code>docs/demo/ndp-ne4-demo.csv</code>, and the venue's areas from the NDP 25 KML, <code>docs/demo/ndp25-areas.json</code> (the seed draws them).</li>
          <li>Playback needs a run with real movement: segment 13 plays back the run the take itself just made.</li>
        </ul>
      </div>
      <div class="card">
        <h3>Recording</h3>
        <ul>
          <li><code>node tools/demo/director.mjs --event &lt;id&gt; --phone --phone-user &lt;user id&gt;</code> records the laptop at 1920 × 1080 and the phone over USB, and writes the cue sheet.</li>
          <li>Phone: Do Not Disturb on with Planova allowed through, the notification shade cleared, screen timeout 10 minutes.</li>
          <li>The merge puts the phone inset bottom-right and cuts every still moment over 1.5 s.</li>
        </ul>
      </div>
    </div>
  </section>

  <section aria-labelledby="h-make">
    <h2 id="h-make">Recording and compiling</h2>
    <p class="lede">The whole video is made by scripts in this repo, so any Claude Code session (or a person) can redo it. The full steps are in <code>docs/demo/RECORDING.md</code>; tell Claude: <i>"follow docs/demo/RECORDING.md and record the demo"</i>.</p>
    <div class="grid2">
      <div class="card">
        <h3>1 · Set up</h3>
        <ol>
          <li><code>npm install</code>, then <code>cd tools/demo/video &amp;&amp; npm install</code>. The QA sign-ins in <code>.tmp/qa-accounts.json</code> must be on the laptop.</li>
          <li>The phone: USB debugging on, the latest APK, Do Not Disturb on with Planova allowed.</li>
          <li>Delete the old demo events (after a look at the list).</li>
          <li><code>node tools/demo/seed-ndp-demo.mjs</code> makes the event: the real NDP 25 venue, 13 contingents.</li>
          <li><code>node tools/demo/take-setup.mjs add-phone &lt;event&gt; &lt;username&gt;</code>, then open the event on the phone.</li>
          <li><code>node tools/demo/take-setup.mjs names on</code> for realistic names on screen.</li>
        </ol>
      </div>
      <div class="card">
        <h3>2 · Record</h3>
        <ol>
          <li><code>node tools/demo/director.mjs --event &lt;event&gt; --phone --phone-user &lt;id&gt; --shots</code>: about 10 minutes. Don't touch the phone or the two Chrome windows.</li>
          <li><code>node tools/demo/take-setup.mjs names off</code>, always; the tests need the QA names.</li>
          <li>Check: no segment "stopped early", every end-of-segment screenshot matches its "On screen" above.</li>
        </ol>
      </div>
      <div class="card">
        <h3>3 · Cut and hand out</h3>
        <ol>
          <li>From <code>tools/demo/video</code>: <code>merge.mjs</code>, <code>split.mjs</code>, <code>prompter.mjs</code>.</li>
          <li>Share <code>segments-prompter/</code>: each clip has a teleprompter, and each word lights up as it should be said, on the moment its action happens.</li>
          <li>Each speaker records one file per segment, <code>NN Name.m4a</code>, into one folder.</li>
        </ol>
      </div>
      <div class="card">
        <h3>4 · Compile</h3>
        <ol>
          <li><code>transcribe.py</code> (faster-whisper, local): a time for every spoken word.</li>
          <li><code>voiceover.mjs</code>: cleans each voice and lines the clip up word by word, so every action lands on its word.</li>
          <li><code>compile.mjs</code>: a title card, the speaker's name and topic in the lower third, an animated testing slide, an end card and crossfades, giving <b>Planova - IS216 G11.mp4</b>. No teleprompter text.</li>
        </ol>
      </div>
    </div>
  </section>

  <section aria-labelledby="h-vo">
    <h2 id="h-vo">Voice-over</h2>
    <p class="lede">The screens are recorded for you. Each speaker gets their segments as video clips, named with their name, and records their lines over them. The clips are then joined into one video.</p>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Video clip</th><th>Speaker</th><th>Name your audio</th><th>Slot</th><th>Words</th></tr></thead>
        <tbody>
${rows.map((r) => `          <tr><td>${two(r.n)} ${r.who} - ${esc(r.title)}</td><td>${r.who}</td><td><code>${two(r.n)} ${r.who}.m4a</code></td><td class="t">${r.secs} s</td><td class="t">${r.words}</td></tr>`).join('\n')}
        </tbody>
      </table>
    </div>
    <p class="note">The clips are cut from the final take, which is still to be recorded; until then there are no clip lengths here. The file names stay as above.</p>
    <div class="grid2">
      <div class="card">
        <h3>Recording your lines</h3>
        <ul>
          <li>Play your clip and talk over it with your lines from the run sheet. A phone voice memo is fine; record somewhere quiet.</li>
          <li>One audio file per segment, named as in the table: the two-digit segment number, a space, then your name, such as <code>07 Ern.m4a</code>. MP3, M4A and WAV all work; only the extension changes.</li>
${per.map((p) => `          <li>${p.name}: ${p.segs.map((r) => two(r.n)).join(', ')} (${p.secs} s).</li>`).join('\n')}
          <li>Start talking within a second of pressing record; the start of your file lines up with the start of the clip.</li>
        </ul>
      </div>
      <div class="card">
        <h3>How it's put together</h3>
        <ul>
          <li>The laptop screen is full size, with the real phone's screen inset bottom-right, recorded and kept in sync by <code>tools/demo/director.mjs</code>.</li>
          <li>Segment 14 comes from the same take: the script makes the phone's account a planner and taps through its tabs over USB.</li>
          <li>Each voice file goes on its clip. A clip shorter than its voice-over holds its last frame. The ${rows.length} clips are then joined into one 1080p MP4.</li>
        </ul>
      </div>
    </div>
  </section>

  <section aria-labelledby="h-rub">
    <h2 id="h-rub">Does it cover the brief?</h2>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Brief asks for</th><th>Where</th><th>Covered by</th></tr></thead>
        <tbody>
          <tr><td>What problem, and why it matters</td><td class="t">${at('Intro')}</td><td>Big outdoor events like an NDP rehearsal</td></tr>
          <tr><td>Design of the solution</td><td class="t">${at('Intro')}</td><td>Roles, and one line on how it's built</td></tr>
          <tr><td>How JavaScript and Vue make it dynamic</td><td class="t">${at('Problems')} · ${at('Live location')}</td><td>The Problems panel flagging a No-Go crossing as you edit, two planners live, the moving badge (shown, not explained)</td></tr>
          <tr><td>CSS and Bootstrap, responsive, clean</td><td class="t">—</td><td>Left out on purpose; laptop and phone shown throughout</td></tr>
          <tr><td>Type of data store</td><td class="t">${at('Intro')}</td><td>Supabase database, which also enforces the roles</td></tr>
          <tr><td>External API and how it's integrated</td><td class="t">${at('Intro')} · ${at('Draw')}</td><td>OneMap maps and addresses</td></tr>
          <tr><td>How the features are tested</td><td class="t">${at('How we tested')}</td><td>71 end-to-end tests by role, 114 unit tests, 954 database checks, the 1,000-phone run</td></tr>
          <tr><td>720p minimum, 12 minutes maximum</td><td class="t">—</td><td>1080p export; planned ${clock(total)}</td></tr>
        </tbody>
      </table>
    </div>
  </section>
</main>
`
fs.writeFileSync(file, (head + body).replace(/\n/g, '\r\n'))
console.log(`${rows.length} segments, ${clock(total)} planned, ${spare} s spare, ${words} words (${clock(Math.round((words / 145) * 60))} at 145 wpm)`)
for (const r of rows) {
  const talk = Math.round((r.words / 145) * 60)
  console.log(`${two(r.n)} ${clock(r.at).padStart(5)} ${String(r.secs).padStart(3)} s  ${r.who.padEnd(8)} ${String(r.words).padStart(3)} w ≈ ${String(talk).padStart(2)} s ${talk > r.secs ? 'OVER' : ''} ${r.title}`)
}
for (const p of per) console.log(`${p.name}: ${p.segs.map((r) => two(r.n)).join(', ')} = ${p.secs} s`)
