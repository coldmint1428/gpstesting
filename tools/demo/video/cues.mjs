// Each segment's cues: [action in the take's log, word in the narration that names it], in the order they happen.
// Shared by the teleprompter (prompter.mjs) and the voice alignment (voiceover.mjs).
export const CUES = {
  1: [[/^open \/events$/, /^(think|planova|planover)$/], [/^segment actions done$/, /^(role|roles)$/]],
  2: [[/type NDP Rehearsal 4/, /^details$/], [/press wiz-next/, /^(email|people)$/], [/type Navy/, /^(groups?|navy)$/], [/press wiz-confirm/, /^create$/]],
  3: [[/press Draw area/, /^(tap|corners?)$/], [/type Esplanade Park/, /^(name|esplanade)$/], [/press Save area/, /^(no-go|nogo|wanders?)$/], [/press area-lock-Padang/, /^(locked|lock)$/]],
  4: [[/sheet-import|plan-more/, /^(csv|run|sheets?)$/], [/press play$/, /^play$/], [/press zoom-in/, /^zoom$/], [/press frame-delete/, /^delete$/], [/press undo/, /^undo$/]],
  5: [[/press undo/, /^undo$/], [/press plan-publish/, /^publish$/]],
  6: [[/press create-group-btn/, /^add$/], [/press gd-radio/, /^radio$/], [/press group-delete-btn/, /^delete$/], [/open \/events\/EV\/people/, /^lists$/], [/press person-tolerance-up/, /^close$/]],
  7: [[/press rehearsal-edit/, /^(move|moved)$/], [/press rehearsal-tab-requests/, /^(request|requests)$/], [/press request-approve/, /^(approves?|approve)$/]],
  8: [[/QR code/, /^qr$/]],
  9: [[/press start-event-btn|Start now/, /^start$/], [/press start-confirm-btn/, /^(it's|its)$/], [/press remind-ics-btn/, /^remind$/], [/press live-tab-ops/, /^operations$/], [/press push-60/, /^salute$/], [/press plan-publish/, /^publish$/]],
  10: [],
  11: [[/press live-tab-people/, /^(badge|moves)$/], [/leaflet|^press ([A-Z]{2})?$/, /^click$/]],
  12: [[/press live-tab-message/, /^messages?$/], [/press broadcast-send/, /^(sector|choose)$/], [/press sos-show/, /^sos$/], [/press sos-help/, /^(way|responders)$/]],
  13: [[/press end-event-btn/, /^end$/], [/open \/events\/EV\/playback/, /^playback$/], [/press play-btn/, /^(drag|speed)$/], [/press trails-switch/, /^trails?$/], [/press follow-btn/, /^follow$/], [/press rename-recording-btn/, /^name$/]],
  14: [[/phone tab Ops/, /^ops$/], [/phone tab Map/, /^map$/], [/phone tab Timeline/, /^timeline$/], [/phone tab People/, /^people$/]],
  15: [],
  16: [],
}
