import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pylib'))
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.comments import Comment

out = sys.argv[1]
wb = Workbook()

HEAD = PatternFill('solid', fgColor='0F1B2D')
REQ = PatternFill('solid', fgColor='FDE68A')  # required column header marker row
OPT = PatternFill('solid', fgColor='E2E8F0')
EX = PatternFill('solid', fgColor='F8FAFC')
WHITE = Font(bold=True, color='FFFFFF')
BOLD = Font(bold=True)
thin = Side(style='thin', color='CBD5E1')
BOX = Border(left=thin, right=thin, top=thin, bottom=thin)


def sheet(ws, columns, rows, widths=None):
    """columns: [(header, required, help)]; rows: example data"""
    for i, (head, required, helptext) in enumerate(columns, start=1):
        c = ws.cell(row=1, column=i, value=head)
        c.font = WHITE
        c.fill = HEAD
        c.alignment = Alignment(wrap_text=True, vertical='center')
        c.border = BOX
        c.comment = Comment(helptext, 'Run sheet template')
        r = ws.cell(row=2, column=i, value='REQUIRED' if required else 'optional')
        r.fill = REQ if required else OPT
        r.font = Font(bold=required, size=9, color='334155')
        r.border = BOX
        h = ws.cell(row=3, column=i, value=helptext)
        h.font = Font(italic=True, size=9, color='475569')
        h.alignment = Alignment(wrap_text=True, vertical='top')
        h.border = BOX
    for ri, row in enumerate(rows, start=4):
        for ci, value in enumerate(row, start=1):
            c = ws.cell(row=ri, column=ci, value=value)
            c.border = BOX
            c.fill = EX
            c.number_format = '@'  # keep times as text so Excel never rounds them
    for i in range(1, len(columns) + 1):
        ws.column_dimensions[ws.cell(row=1, column=i).column_letter].width = (widths or {}).get(i, 18)
    ws.row_dimensions[3].height = 60
    ws.freeze_panes = 'B4'
    # text format for the whole data area (planners paste times like 18:04:12)
    for row in ws.iter_rows(min_row=4, max_row=400, max_col=len(columns)):
        for c in row:
            c.number_format = '@'


def dropdown(ws, col_letter, options, rows='4:400'):
    a, b = rows.split(':')
    dv = DataValidation(type='list', formula1='"' + ','.join(options) + '"', allow_blank=True)
    dv.add(f'{col_letter}{a}:{col_letter}{b}')
    ws.add_data_validation(dv)


# ---------------- README ----------------
ws = wb.active
ws.title = 'README'
lines = [
    ('Run sheet template · Event Tracker (IS216 G11)', True),
    ('One workbook = one version of one event\'s run sheet. Upload it in Timeline builder → Import.', False),
    ('', False),
    ('Tabs', True),
    ('Event – name, date and the default numbers used when a row leaves them empty.', False),
    ('Cues – the show matrix: one row per cue, start time to the second. This is what the live screen counts down.', False),
    ('Groups – who moves (bands, choirs, contingents), how many people, and which app users are their ICs.', False),
    ('Zones – the places groups must reach (polygon from the bench, or a circle for now) and no-go areas.', False),
    ('Movements – the link between the three: GROUP must be inside ZONE by CUE (start/end) or a fixed time, and how they travel.', False),
    ('Big events (100+ groups): give every group a Category (and Sector), then write one Movements row per category (CAT:Bands); add a row for a single group only where it differs.', False),
    ('Checkpoints – for Fixed route movements (mobile column): the route\'s checkpoints with planned times.', False),
    ('', False),
    ('Rules that keep the import exact', True),
    ('1. Times are text in 24-hour form HH:MM:SS (18:04:12). Lengths are MM:SS or HH:MM:SS (01:26, 51:40, 01:05:00).', False),
    ('2. IDs (Cue ID, Group code, Zone code) link the tabs – spell them the same everywhere. Letters, digits, _ and - only.', False),
    ('3. Pick values from the dropdowns (Type, Must be inside by, Zone type). Free text is only for names and notes.', False),
    ('4. Rows 2–3 under each header say what the column means and whether it is required. Example rows start at row 4 – overwrite them.', False),
    ('5. Every number is a number: seconds, metres, ICs, people. No words like "most" or "soon".', False),
    ('', False),
    ('How the live screen uses each number', True),
    ('Deadline = cue start (as delayed) − "Arrive early by". It moves when the show runs late, unless "Must be inside by" is a fixed time.', False),
    ('Arrived = all of the group\'s sharing ICs (or "Min ICs inside" if filled in) have been inside the zone for "Stay inside for (s)" seconds, before the deadline.', False),
    ('Green = arrived, or ETA before the deadline with at least "Amber when spare below (s)" to spare. Amber = less spare than that. Red = ETA after the deadline.', False),
    ('Travel mode: On foot = OneMap walking route; speed = Planned pace until they move, then their real progress towards the zone. Vehicle = OneMap driving route, then the phone\'s GPS speed. Fixed route = ahead/behind the planned checkpoint times (closed roads, choreographed pace).', False),
    ('ETA = now + distance still to go / speed + "Stay inside for (s)". Status = deadline - ETA: green >= amber threshold, amber 0 to threshold, red after the deadline.', False),
    ('Leave by = deadline - walking time (distance / their recent speed) - "Arrive early by". ICs get a "Leave now" notification then.', False),
    ('Start mode: Auto runs by the clock. Auto when ready starts only if its Movements have arrived (else holds and asks planners). Manual waits for GO.', False),
    ('Anchor cues never move. Flexible cues can shrink by up to "Can shorten by" to absorb delays before the next anchor.', False),
]
for i, (text, bold) in enumerate(lines, start=1):
    c = ws.cell(row=i, column=1, value=text)
    c.font = Font(bold=bold, size=14 if i == 1 else 11)
ws.column_dimensions['A'].width = 140

# ---------------- Event ----------------
ws = wb.create_sheet('Event')
sheet(ws, [
    ('Setting', True, 'Name of the setting (do not change these words).'),
    ('Value', True, 'Your value.'),
    ('Unit / format', False, 'How to write the value.'),
], [
    ('Event name', 'NDP Rehearsal 1', 'text'),
    ('Date', '2026-08-01', 'YYYY-MM-DD'),
    ('Version label', 'v03 Jul', 'text – shown in the builder and on the live screen'),
    ('Default arrive early by', '00:30', 'MM:SS – used when a Movement row leaves it empty'),
    ('Default stay inside for (s)', '20', 'seconds – GPS must show them inside this long to count'),
    ('Default amber when spare below (s)', '30', 'seconds'),
    ('Default min ICs inside', 'all sharing', '"all sharing" = every IC that has signal (no-signal ICs are shown but do not block), or a number like 2'),
    ('Default notify ICs to leave', 'yes', 'yes / no – push "Leave now" to the group ICs at their leave-by time'),
], {1: 34, 2: 22, 3: 70})

# ---------------- Cues ----------------
ws = wb.create_sheet('Cues')
cols = [
    ('Cue ID', True, 'Unique, e.g. C034. Movements refer to it.'),
    ('Section', False, 'Pre-Parade, Parade & Ceremony, Act 1 …'),
    ('Start time', True, 'HH:MM:SS planned start (REAL TIME column of the show matrix).'),
    ('Length', True, 'MM:SS or HH:MM:SS (DURATION (PER SEGMENT)).'),
    ('Cue name', True, 'PROGRAMME column.'),
    ('Type', True, 'Normal = starts on GO. Flexible = can shrink. Anchor = fixed clock time, never moves.'),
    ('Can shorten by', False, 'Flexible only: MM:SS it may lose to absorb delays.'),
    ('Start mode', True, 'Auto = starts by itself at its (projected) time. Auto when ready = starts by itself if its groups have arrived, else holds and asks planners. Manual = waits for a planner to press GO. Anchors are always Auto.'),
    ('Area', False, 'Where it happens: Padang, Bay, Broadcast, All.'),
    ('Department', False, 'Who runs it: Show Mgmt, Fireworks, Sound …'),
    ('Notes', False, 'Free text (Padang / Bay / Broadcast notes). Not used by the logic.'),
]
sheet(ws, cols, [
    ('C010', 'Pre-Parade', '17:30:00', '00:00', 'Broadcast start time', 'Anchor', '', 'Auto', 'Broadcast', 'Broadcast', 'Live on TV'),
    ('C018', 'Pre-Parade', '17:35:30', '02:30', 'Padang Wave (buffer to meet go-live)', 'Flexible', '01:00', 'Auto', 'Padang', 'Show Mgmt', ''),
    ('C033', 'Pre-Parade', '18:01:35', '02:37', 'Our Singapore Wish', 'Normal', '', 'Auto', 'Padang', 'Show Mgmt', 'Bands enter and preset in Formation 1'),
    ('C034', 'Pre-Parade', '18:04:12', '01:26', 'Combined School Marching Bands Feature', 'Normal', '', 'Auto when ready', 'Padang', 'Show Mgmt', ''),
    ('C038', 'Pre-Parade', '18:08:57', '00:45', 'Audience Placard + Choir Feature', 'Normal', '', 'Auto when ready', 'Padang', 'Show Mgmt', 'Choir @ S1, S2, S3, S7, S8'),
    ('C040', 'Parade & Ceremony', '18:11:00', '51:40', 'Parade & Ceremony', 'Flexible', '01:10', 'Manual', 'Padang', 'Parade', ''),
    ('C045', 'Mobile Column', '19:02:40', '17:45', 'Mobile Column', 'Normal', '', 'Auto', 'All', 'Mobile Column', 'Vehicles follow MC_ROUTE (Checkpoints tab)'),
    ('C052', 'Mobile Column', '19:12:00', '01:05', 'Flypast', 'Anchor', '', 'Auto', 'All', 'RSAF', 'Anchor Timing 19:12:00'),
], {1: 10, 2: 18, 3: 12, 4: 10, 5: 40, 6: 12, 7: 14, 8: 16, 9: 12, 10: 14, 11: 40})
dropdown(ws, 'F', ['Normal', 'Flexible', 'Anchor'])
dropdown(ws, 'H', ['Auto', 'Auto when ready', 'Manual'])

# ---------------- Groups ----------------
ws = wb.create_sheet('Groups')
sheet(ws, [
    ('Group code', True, 'Unique, e.g. WSSS_BAND. Movements refer to it.'),
    ('Group name', True, 'Shown on the map and run sheet.'),
    ('Category', True, 'Bands, Choirs, Contingents, VIP, Mobile Column … Movements can target a whole category (CAT:Bands). Also a filter in the ops view.'),
    ('Sector', False, 'Area or sector this group belongs to (S3, Bay, Padang). Marshals see their own sector.'),
    ('Headcount', True, 'Number of people in the group (Entrance & Exit sheet).'),
    ('IC usernames', False, 'App usernames of the ICs who share GPS for this group, separated by ; (each IC leads part of the group).'),
    ('Group admin username', False, 'Who gets the "you are late" message.'),
    ('Colour', False, '#RRGGBB for the map.'),
], [
    ('TKSS_BAND', 'TKSS Band', 'Bands', 'Padang', '36', 'tkss_ic1; tkss_ic2; tkss_ic3', 'tkss_admin', '#0D6EFD'),
    ('WSSS_BAND', 'WSSS Band', 'Bands', 'Padang', '32', 'wsss_ic1; wsss_ic2', 'wsss_admin', '#DC3545'),
    ('YHSS_BAND', 'YHSS Band', 'Bands', 'Padang', '32', 'yhss_ic1; yhss_ic2; yhss_ic3', 'yhss_admin', '#198754'),
    ('MOE_CHOIR_S3', 'MOE Choir (S3)', 'Choirs', 'S3', '40', 'choir_ic1; choir_ic2', 'choir_admin', '#6F42C1'),
    ('MOBILE_COLUMN', 'Mobile Column (lead vehicles)', 'Mobile Column', 'Route', '24', 'mc_lead; mc_mid; mc_tail', 'mc_admin', '#FD7E14'),
], {1: 16, 2: 26, 3: 14, 4: 10, 5: 11, 6: 34, 7: 20, 8: 10})

# ---------------- Zones ----------------
ws = wb.create_sheet('Zones')
sheet(ws, [
    ('Zone code', True, 'Unique, e.g. FORMATION_1. Movements refer to it.'),
    ('Zone name', True, 'Shown on the map.'),
    ('Zone kind', True, 'Same kinds as the polygon tool. Zone = an area groups move to or wait in. Stage = performance area. Entrance = door / gate (can be an Arrival point). No-go = alert if anyone enters. Obstacle = shown on the map only.'),
    ('Source', True, 'Polygon = drawn in the polygon tool with this Zone code. Circle = centre + radius below.'),
    ('Centre lat', False, 'Circle only: decimal degrees, 6 decimals.'),
    ('Centre lng', False, 'Circle only.'),
    ('Radius (m)', False, 'Circle only: metres. Keep at least 15 m (GPS accuracy).'),
    ('Capacity (people)', False, 'Most people allowed inside at once (uses group headcounts). Empty = no check.'),
], [
    ('FORMATION_1', 'Formation 1', 'Zone', 'Polygon', '', '', '', '120'),
    ('HOLD_D4', 'Holding area D4', 'Zone', 'Circle', '1.290410', '103.852150', '25', '150'),
    ('D4', 'Door D4', 'Entrance', 'Circle', '1.290900', '103.851700', '15', ''),
    ('SECTOR_S3', 'Sector S3', 'Zone', 'Polygon', '', '', '', '60'),
    ('PYRO_ZONE', 'Pyro zone', 'No-go', 'Polygon', '', '', '', ''),
    ('SALUTE_DAIS', 'Saluting dais', 'Stage', 'Polygon', '', '', '', ''),
], {1: 16, 2: 20, 3: 12, 4: 12, 5: 12, 6: 12, 7: 11, 8: 12})
dropdown(ws, 'C', ['Zone', 'Stage', 'Entrance', 'No-go', 'Obstacle'])
dropdown(ws, 'D', ['Polygon', 'Circle'])

# ---------------- Movements ----------------
ws = wb.create_sheet('Movements')
sheet(ws, [
    ('Move ID', True, 'Unique, e.g. M012.'),
    ('Group code', True, 'A Group code from the Groups tab, or CAT:<category> for every group in that category (CAT:Bands). A row for one group overrides its category row for the same cue.'),
    ('Zone code', True, 'From the Zones tab (kind Zone or Stage).'),
    ('Must be inside by', True, 'Cue start / Cue end (moves with delays) or Fixed time (never moves).'),
    ('Cue ID', False, 'Needed for Cue start / Cue end.'),
    ('Fixed time', False, 'HH:MM:SS – only for Fixed time.'),
    ('Arrive early by', False, 'MM:SS before that moment. Empty = Event default (00:30).'),
    ('Min ICs inside', False, 'How many of the group\'s ICs must be inside. Empty = all ICs that are sharing (no-signal ICs shown, not blocking).'),
    ('Stay inside for (s)', False, 'Seconds inside before it counts. Empty = 20.'),
    ('Amber when spare below (s)', False, 'Seconds. Empty = 30.'),
    ('Must leave by', False, 'Optional: Cue ID end or HH:MM:SS by which they must have left the zone.'),
    ('Travel mode', True, 'On foot = walking or marching (OneMap walking route). Vehicle = public roads (OneMap driving route + live GPS speed). Fixed route = closed roads / parade (follows the Route\'s checkpoints, not OneMap).'),
    ('Planned pace (m/s)', False, 'On foot only: speed before they start moving (for "Leave now" and the first ETA). Empty = 1.2 (walking). Marching band ~0.8.'),
    ('Arrival point', False, 'Zone code of the door they enter by (D4). Empty = nearest edge of the zone.'),
    ('Route', False, 'Fixed route: the route name in the Checkpoints tab (required). Others: optional KML path name to show as the planned route.'),
], [
    ('M010', 'TKSS_BAND', 'HOLD_D4', 'Cue start', 'C033', '', '01:00', '', '', '', '', 'On foot', '0.8', 'D4', ''),
    ('M011', 'CAT:Bands', 'FORMATION_1', 'Cue start', 'C034', '', '00:30', '', '20', '30', 'C034 end', 'On foot', '0.8', 'D4', ''),
    ('M012', 'YHSS_BAND', 'FORMATION_1', 'Cue start', 'C034', '', '00:30', '2', '20', '30', 'C034 end', 'On foot', '0.8', 'D4', ''),
    ('M020', 'MOE_CHOIR_S3', 'SECTOR_S3', 'Fixed time', '', '18:05:00', '', '1', '20', '60', '', 'On foot', '1.2', '', ''),
    ('M030', 'MOBILE_COLUMN', 'SALUTE_DAIS', 'Cue start', 'C052', '', '00:00', '1', '0', '20', '', 'Fixed route', '', '', 'MC_ROUTE'),
], {1: 9, 2: 16, 3: 16, 4: 16, 5: 9, 6: 11, 7: 12, 8: 12, 9: 12, 10: 14, 11: 13, 12: 13, 13: 12, 14: 12, 15: 14})
dropdown(ws, 'D', ['Cue start', 'Cue end', 'Fixed time'])
dropdown(ws, 'L', ['On foot', 'Vehicle', 'Fixed route'])

# ---------------- Checkpoints (fixed routes: mobile column, parade vehicles) ----------------
ws = wb.create_sheet('Checkpoints')
sheet(ws, [
    ('Route', True, 'Route name used in Movements (MC_ROUTE). One route = the rows with the same name, in Order.'),
    ('Order', True, '1, 2, 3 … along the route.'),
    ('Checkpoint name', True, 'Shown on the timeline: "C2 St Andrew\'s Rd".'),
    ('KML point', False, 'Name of a point in the event KML. Or fill in lat / lng.'),
    ('Lat', False, 'Decimal degrees, 6 decimals (if no KML point).'),
    ('Lng', False, ''),
    ('Pass radius (m)', False, 'Counts as passed within this distance. Empty = 30 m (vehicles move ~110 m per reading).'),
    ('Planned time', False, 'HH:MM:SS when the lead vehicle should pass – OR use the next column.'),
    ('Offset from start', False, 'MM:SS after the route\'s cue starts (moves with delays).'),
    ('Start cue', False, 'Cue ID the offsets count from (first row of the route).'),
], [
    ('MC_ROUTE', '1', 'C1 Start – Nicoll Hwy', '', '1.297100', '103.861900', '30', '', '00:00', 'C045'),
    ('MC_ROUTE', '2', 'C2 Esplanade Dr', '', '1.291300', '103.855900', '30', '', '02:10', ''),
    ('MC_ROUTE', '3', 'C3 St Andrew\'s Rd', '', '1.290600', '103.852300', '30', '', '04:40', ''),
    ('MC_ROUTE', '4', 'C4 Saluting dais', '', '1.290300', '103.851200', '20', '', '06:40', ''),
    ('MC_ROUTE', '5', 'C5 Exit – Coleman St', '', '1.292300', '103.849900', '30', '', '08:20', ''),
], {1: 12, 2: 7, 3: 26, 4: 16, 5: 11, 6: 11, 7: 12, 8: 12, 9: 14, 10: 10})

wb.save(out)
print('saved', out)
