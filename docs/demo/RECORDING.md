# Recording the Planova demo video

Step-by-step instructions for recording and compiling the IS216 G11 demo video, written so a Claude Code session
(or a person) can do the whole thing from this repository. The script being recorded is the run sheet,
`docs/demo/planova-demo-script.html`: 16 segments, six speakers, 11:35 planned, under the 12:00 limit.

Ask the user before anything outward-facing: deleting events, pushing to `main`, changing someone's role.

## What you need

- This repo on `main`, with `npm install` done at the root.
- The video tools: `cd tools/demo/video && npm install` (ffmpeg and ffprobe; this folder is not part of the app's install).
- `.tmp/qa-accounts.json`: the QA accounts' sign-ins. It is not in git; it is on the laptop that ran the tests. Never
  print its values.
- The Android SDK's `adb` at `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`, and the user's phone:
  - plugged in with USB debugging on (`adb devices` lists it)
  - the latest Planova APK installed
  - Do Not Disturb on, with Planova allowed through
  - signed in to the user's own Planova account (ask the user for its username)
- For the voice-overs only: Python 3.13 and about 300 MB of space for the speech-to-text model.

Privacy on the phone: before every screenshot or tap over `adb`, check that Planova is the app in front
(`adb shell dumpsys window | grep mCurrentFocus` must show `sg.edu.smu.is216.g11`). Never screenshot another app.

## 1. A clean start

Old demo events clutter the root's Events list, which segment 1 shows. List them, show the user, and delete them
by id once the user agrees (as `qa_root`, with the `delete_event` RPC):

```sql
select id, join_code, name, created_at from events where name in ('NDP 2025 NE4 Rehearsal', 'NDP Rehearsal 4');
```

## 2. The event for the take

```bash
node tools/demo/seed-ndp-demo.mjs
```

It prints the event id and its join code. The event has the real NDP 25 venue (43 areas: the Padang as built for the
parade, and the NDP 25 Main map's posts from `docs/demo/ndp25-areas.json`), 13 contingents, and an empty plan. It is
dated a week ahead, so a rehearsal can go before it.

Put the user's phone account in P&C Contingent 3:

```bash
node tools/demo/take-setup.mjs add-phone <event id> <the user's username or user id>
```

It prints the account's user id. You need it for the recorder. The root can only look a profile up by username once
it shares an event with it, so on a fresh event pass the user id (a uuid) instead.

On the phone, open Planova, pull down to refresh the Events list, and open "NDP 2025 NE4 Rehearsal". It should say
"Member · P&C Contingent 3" and "Not started yet". Leave it there.

## 3. Realistic names on screen

```bash
node tools/demo/take-setup.mjs names on
```

The QA accounts show as Komin Chow, Lt Marcus Lee, Sgt Daniel Tan and Cadet Aisha Rahman. **Always run `names off`
after the take, even if it failed**: the end-to-end tests look for the QA names.

## 4. Record

```bash
node tools/demo/director.mjs --event <event id> --phone --phone-user <user id> --shots
```

It takes about 10 minutes, in two Chrome windows: the laptop (1920 × 1080) and the IC's phone-sized window. Your
phone is recorded over USB. Don't touch either. It plays the 16 segments, and each one lasts about as long as its
narration (`TALK` in the script). It writes everything to `.tmp/demo-run/<time>/`:

- the two `.webm` videos and the phone's `phone-*.mp4` clips
- `cues.txt`: when each segment starts
- `actions.json`: every click, typed text and page, timed and placed
- `timing.json`: when each video started
- `seg-NN.png`: the screen at the end of each segment

Then:

```bash
node tools/demo/take-setup.mjs names off
```

Check the take:

- The log has no line saying "stopped early".
- Look at every `seg-NN.png` against that segment's "On screen" in the run sheet.
- In the database, the event should have:
  - 44 areas, including Esplanade Park as No-Go
  - the plan published, with no problems
  - one rehearsal, with an approved absence
  - one roll call and one broadcast
  - a session that ran on the plan and ended
  - a recording named "NE4 full dress"
  - location readings

If a segment is wrong, fix the script and re-record. To try just a few segments, use `--only 4,5`.

### Retaking a few segments on the same event

A retake goes into its own run folder. Cut it like a full take (step 5), then copy its clips over the same-numbered ones.

- Segments 10–13 need the event live. If it has already been ended, add `--go-live`: it starts the event on the
  published plan off camera, has the IC share and walk, and waits until the Live page is fully drawn. End it again by
  including 13 (for example `--only 11,13 --go-live`), and drop 13's clip if you don't need it.
- Segments 14–16 come after the event ends. Add `--open overview` so the Overview is loaded before the first frame.
  A retake of 14 puts the phone's account back to member first, so the switch to planner still happens on camera.
- Each clip starts exactly at its segment (only segment 1 keeps the seconds before it). If a clip still opens on a
  loading screen, move that segment's `segment start` time later in the run folder's `actions-merged.json`, then run
  `split.mjs` and `prompter.mjs` again (not `merge.mjs`, which rewrites that file).
- The laptop video's timing comes from the 12 px grey square in its top-left corner: it changes shade at every action,
  and `merge.mjs` reads it frame by frame ("corner clock: N of M actions seen"), then paints it over.
- Check that the phone clip plays (`phone-planova-demo-01.mp4`). If it says "moov atom not found", the take must be
  redone: the phone's copy is deleted after it is pulled.

## 5. Cut the clips

From `tools/demo/video`:

```bash
node merge.mjs ../../../.tmp/demo-run/<time>
```

```bash
node split.mjs ../../../.tmp/demo-run/<time>
```

```bash
node prompter.mjs ../../../.tmp/demo-run/<time> ../../../docs/demo/planova-demo-script.html
```

- `merge.mjs` joins the laptop video with the phone. The phone inset appears only where the phone matters: the IC's
  window in segments 8 and 10, and your phone in 9 and 11–14. The screen zooms in on each narrated click, and every
  still moment over 1.5 s is cut. It writes `planova-demo-merged.mp4`, `cues-merged.txt` and `actions-merged.json`.
- `split.mjs` makes `segments/NN Speaker - Title.mp4`: 16 clean clips, named by who voices them.
- `prompter.mjs` makes `segments-prompter/`: the same clips with a teleprompter. The lines run along the bottom, and
  each word fills with colour when it should be said. A cued word ("start", "publish", "undo", "QR", "SOS"…) lights up
  the moment its action happens on screen.

Share `segments-prompter/` with the team. Each speaker plays their clips and reads along, one audio file per segment,
named with the two-digit number and their name (`07 Ern.m4a`), all into one folder.

Who voices what:

| Speaker | Segments |
|---|---|
| Komin | 01, 09, 16 |
| rui | 02, 11, 13 |
| Hazel | 03, 10 |
| Linus | 04, 05 |
| Ern | 07, 08, 12 |
| Kenneth | 06, 14, 15 |

## 6. The voices, word by word

Install the speech-to-text tool once, in its own folder outside the repo (ask the user first: about 300 MB from PyPI
and Hugging Face):

```bash
py -3.13 -m venv <somewhere>/whisper-env
```

```bash
<somewhere>/whisper-env/Scripts/python.exe -m pip install faster-whisper==1.1.1 requests
```

Then, from `tools/demo/video`:

```bash
<somewhere>/whisper-env/Scripts/python.exe -I transcribe.py node_modules/ffmpeg-static/ffmpeg.exe "<audio folder>" words.json
```

```bash
node voiceover.mjs ../../../.tmp/demo-run/<time> "<audio folder>" words.json
```

```bash
node compile.mjs ../../../.tmp/demo-run/<time> words.json
```

- `transcribe.py` gives every word in every audio file a time. Names may be misheard; only the timings are used.
- `voiceover.mjs` cleans each voice (removes rumble and hiss, evens out levels, -16 LUFS). It lines the clip up with
  the voice word by word: the clip is cut at each cued action and each piece is played faster or slower, so the
  action lands on its word (`cues.mjs` lists the pairs). `voiced/alignment.txt` records which word met which action.
- `compile.mjs` makes the finished video, `Planova - IS216 G11.mp4`:
  - a title card
  - each speaker's name and topic in the lower third as their segment starts
  - segment 15 as an animated slide of the test numbers, timed to the words
  - an end card
  - a soft crossfade between every piece

  It warns if the video runs over 12:00.

Segments without a voice-over yet stay silent; run `voiceover.mjs` and `compile.mjs` again as audio comes in.

## Notes

- The recorder plays every role except the user's phone. The IC's location is simulated, walking from the casing
  location to the Padang.
- Times on screen follow the real NE4 show matrix (`docs/demo/ndp-ne4-demo.csv`), starting at T+0 = now.
- After the take, keep the event: segment 13's playback uses its recording. Delete it before the next take.
