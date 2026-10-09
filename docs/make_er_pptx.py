"""Build the gpstesting ER diagram as an editable PowerPoint deck.

Slide 1: the diagram (6 table cards + routed relationship lines + legend panel)
Slide 2: the relationship table and key rules

Run with the bundled Python:  <python> docs/make_er_pptx.py
Output: docs/er-diagram.pptx
"""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE, MSO_CONNECTOR
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.oxml.ns import qn

OUT = "docs/er-diagram.pptx"

BG       = "f6f8fa"
INK      = "1f2328"
MUTED    = "59636e"
FAINT    = "8a9199"
BORDER   = "d0d7de"
SEP      = "d8dee4"
TYPE_COL = "8250df"
BLUE     = "0969da"
GREY     = "8c959f"
PURPLE   = "8250df"
AMBER    = "7d4e00"

HEAD_COLOUR = {
    "identity": "1a7f37",
    "event":    "0969da",
    "group":    "8250df",
    "track":    "bc4c00",
}

HEAD_H = 0.34
ROW_H  = 0.26
FOOT_H = 0.44
PAD_T  = 0.04

prs = Presentation()
prs.slide_width  = Inches(16)
prs.slide_height = Inches(10.5)
slide = prs.slides.add_slide(prs.slide_layouts[6])
shapes = slide.shapes

for _s in prs.slides:
    _f = _s.background.fill
    _f.solid()
    _f.fore_color.rgb = RGBColor.from_string(BG)


# ----------------------------------------------------------------- primitives
def rect(x, y, w, h, fill, line=None, radius=None,
         shape=MSO_SHAPE.ROUNDED_RECTANGLE, onto=None):
    host = shapes if onto is None else onto
    s = host.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    if radius is not None:
        try:
            s.adjustments[0] = radius
        except (IndexError, ValueError):
            pass
    if fill:
        s.fill.solid()
        s.fill.fore_color.rgb = RGBColor.from_string(fill)
    else:
        s.fill.background()
    if line:
        s.line.color.rgb = RGBColor.from_string(line)
        s.line.width = Pt(1.0)
    else:
        s.line.fill.background()
    s.shadow.inherit = False
    s.text_frame.word_wrap = False
    return s


def seg(x1, y1, x2, y2, colour, width=1.6, dash=None, arrow=False):
    c = shapes.add_connector(MSO_CONNECTOR.STRAIGHT,
                             Inches(x1), Inches(y1), Inches(x2), Inches(y2))
    c.line.color.rgb = RGBColor.from_string(colour)
    c.line.width = Pt(width)
    if dash:
        from pptx.enum.dml import MSO_LINE_DASH_STYLE
        c.line.dash_style = {"dash": MSO_LINE_DASH_STYLE.DASH,
                             "dot":  MSO_LINE_DASH_STYLE.ROUND_DOT}[dash]
    ln = c.line._get_or_add_ln()
    ln.set("cap", "sq")
    if arrow:
        tail = ln.makeelement(qn("a:tailEnd"),
                              {"type": "triangle", "w": "med", "len": "med"})
        ln.append(tail)
    c.shadow.inherit = False
    return c


def route(points, colour=BLUE, width=1.6, dash=None):
    """Polyline; arrowhead only on the last segment."""
    n = len(points)
    for i in range(n - 1):
        (x1, y1), (x2, y2) = points[i], points[i + 1]
        seg(x1, y1, x2, y2, colour, width, dash, arrow=(i == n - 2))


def tb(x, y, w, h, runs, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, wrap=False):
    """runs = [(text, size, bold, colour, fontname, italic)]"""
    box = shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.word_wrap = wrap
    tf.margin_left = tf.margin_right = 0
    tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    p = tf.paragraphs[0]
    p.alignment = align
    for text, size, bold, colour, fname, italic in runs:
        r = p.add_run()
        r.text = text
        r.font.size = Pt(size)
        r.font.bold = bold
        r.font.italic = italic
        r.font.name = fname
        r.font.color.rgb = RGBColor.from_string(colour)
    return box


SEG = "Segoe UI"
MONO = "Consolas"


def simple(x, y, w, h, text, size=9, bold=False, colour=INK, font=SEG,
           align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, wrap=False, italic=False):
    return tb(x, y, w, h, [(text, size, bold, colour, font, italic)],
              align=align, anchor=anchor, wrap=wrap)


# --------------------------------------------------------------- geometry
# name, x, y, w, kind, header-note, rows[(badges, column, type, comment)],
# constraint footer
E = [
    ("profiles", 0.45, 1.25, 3.55, "identity", "one row per account", [
        ("PK", "id",           "uuid",        "= auth.users.id"),
        ("",   "username",     "text",        "unique, 3-20 chars"),
        ("",   "display_name", "text",        "1-50 chars"),
        ("",   "created_at",   "timestamptz", "default now()"),
    ], "Written by the trigger handle_new_user() at signup - the app never inserts it."),

    ("events", 4.55, 1.25, 3.55, "event", "one row per event", [
        ("PK", "id",         "uuid",        "gen_random_uuid()"),
        ("",   "name",       "text",        "1-80 chars"),
        ("",   "join_code",  "text",        "unique, 6 chars"),
        ("FK", "created_by", "uuid",        "-> profiles.id"),
        ("",   "created_at", "timestamptz", "default now()"),
    ], "join_code avoids I L O 0 1 so it is safe to read aloud."),

    ("event_roles", 11.70, 1.25, 3.85, "event", "per event", [
        ("PK FK", "event_id",   "uuid",        "-> events.id"),
        ("PK FK", "user_id",    "uuid",        "-> profiles.id"),
        ("PK",    "role",       "text",        "root/planner/marshal"),
        ("",      "created_at", "timestamptz", "default now()"),
    ], "PK spans all 3 columns, so roles are additive - plus one root per event."),

    ("groups", 4.55, 3.80, 3.55, "group", "teams in an event", [
        ("PK", "id",         "uuid",        "gen_random_uuid()"),
        ("FK", "event_id",   "uuid",        "-> events.id"),
        ("",   "name",       "text",        "unique per event"),
        ("",   "colour",     "text",        "#rrggbb map colour"),
        ("",   "created_at", "timestamptz", "default now()"),
    ], "unique (id, event_id) exists only so group_members can point at the pair."),

    ("group_members", 11.70, 4.00, 3.85, "group", "person -> group", [
        ("PK FK", "group_id",   "uuid",        "-> groups.id"),
        ("FK",    "event_id",   "uuid",        "-> groups(id,event_id)"),
        ("PK FK", "user_id",    "uuid",        "-> profiles.id"),
        ("",      "is_admin",   "boolean",     "group admin"),
        ("",      "is_ic",      "boolean",     "shares GPS"),
        ("",      "created_at", "timestamptz", "default now()"),
    ], "unique (event_id, user_id): one group per person per event."),

    ("locations", 0.80, 6.80, 8.65, "track", "append-only GPS log", [
        ("PK", "id",          "bigint identity",  "incrementing, not a uuid"),
        ("FK", "event_id",    "uuid",             "-> events.id, NOT VALID"),
        ("FK", "group_id",    "uuid",             "-> groups.id, NOT VALID"),
        ("FK", "user_id",     "uuid",             "default auth.uid()"),
        ("",   "lat",         "double precision", "required"),
        ("",   "lng",         "double precision", "required"),
        ("",   "accuracy",    "real",             "nullable"),
        ("",   "source",      "text",             "gps | marshal | stop"),
        ("",   "recorded_at", "timestamptz",      "default now()"),
    ], "Never updated, never deleted on a schedule - one new row per reading."),
]

BOX = {}
for name, x, y, w, kind, note, rows, foot in E:
    BOX[name] = (x, y, w, HEAD_H + PAD_T + len(rows) * ROW_H + FOOT_H)


# ------------------------------------------------------- connectors (behind)
# Every route is listed in the legend on slide 2, so no inline labels are used.
route([(4.00, 1.76), (4.28, 1.76), (4.28, 2.54), (4.55, 2.54)])          # 1
route([(2.20, 1.25), (2.20, 1.10), (10.80, 1.10), (10.80, 2.02), (11.70, 2.02)])   # 2
route([(5.60, 1.25), (5.60, 0.95), (13.20, 0.95), (13.20, 1.25)])        # 3
route([(2.80, 3.11), (2.80, 3.55), (10.90, 3.55), (10.90, 5.03), (11.70, 5.03)])   # 4
route([(6.20, 3.37), (6.20, 3.80)])                                       # 5
route([(8.10, 4.25), (10.40, 4.25), (10.40, 4.51), (11.70, 4.51)])       # 6
route([(8.10, 4.37), (9.10, 4.37), (9.10, 6.80)])                        # 7
route([(4.90, 3.37), (4.90, 3.68), (0.55, 3.68), (0.55, 7.57), (0.80, 7.57)])      # 8
route([(6.60, 5.92), (6.60, 6.55), (11.30, 6.55), (11.30, 6.38)],
      colour=PURPLE, dash="dot")                                          # 9 composite
route([(7.40, 3.37), (7.40, 3.68), (11.50, 3.68), (11.50, 4.77), (11.70, 4.77)],
      colour=GREY, dash="dash")                                           # 10 not-a-FK
route([(0.45, 1.50), (0.30, 1.50), (0.30, 8.09), (0.80, 8.09)],
      colour=GREY, dash="dash")                                           # 11 logical only


# -------------------------------------------------------------- table cards
def card(name, x, y, w, kind, note, rows, foot):
    h = HEAD_H + PAD_T + len(rows) * ROW_H + FOOT_H
    rect(x, y, w, h, "ffffff", BORDER, radius=0.045)

    # header (rounded top two corners only)
    head = shapes.add_shape(getattr(MSO_SHAPE, "ROUND_2_SAME_RECTANGLE",
                                    MSO_SHAPE.ROUNDED_RECTANGLE),
                            Inches(x + 0.015), Inches(y + 0.015),
                            Inches(w - 0.03), Inches(HEAD_H))
    head.adjustments[0] = 0.16
    head.fill.solid()
    head.fill.fore_color.rgb = RGBColor.from_string(HEAD_COLOUR[kind])
    head.line.fill.background()
    head.shadow.inherit = False
    head.text_frame.word_wrap = False

    simple(x + 0.16, y + 0.055, w * 0.42, 0.24, name, 12, True, "ffffff", SEG,
           anchor=MSO_ANCHOR.MIDDLE)
    simple(x + 0.16 + w * 0.44, y + 0.055, w * 0.56 - 0.32, 0.24, note, 7.5,
           False, "dbe4ec", SEG, align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)

    ry = y + HEAD_H + PAD_T
    for badges, col, typ, cmt in rows:
        badge_col = AMBER if "PK" in badges else (BLUE if badges else FAINT)
        tb(x + 0.10, ry + 0.015, w - 0.18, ROW_H,
           [("%-6s" % badges, 8, True, badge_col, MONO, False),
            ("%-13s" % col, 8, False, INK, MONO, False),
            ("%-14s" % typ, 8, False, TYPE_COL, MONO, False),
            ("  " + cmt, 7, False, FAINT, SEG, False)],
           anchor=MSO_ANCHOR.MIDDLE)
        ry += ROW_H

    seg(x + 0.10, ry + 0.10, x + w - 0.10, ry + 0.10, SEP, width=0.75)
    simple(x + 0.16, ry + 0.16, w - 0.30, FOOT_H - 0.18, foot, 7.5, False, MUTED,
           SEG, wrap=True)


for name, x, y, w, kind, note, rows, foot in E:
    card(name, x, y, w, kind, note, rows, foot)


# ------------------------------------------------------------ legend panel
LX, LY, LW, LH = 9.75, 6.80, 5.80, 3.16
rect(LX, LY, LW, LH, "ffffff", BORDER, radius=0.035)
simple(LX + 0.20, LY + 0.13, LW - 0.4, 0.26, "How to read this", 12, True, INK)
seg(LX + 0.20, LY + 0.46, LX + LW - 0.20, LY + 0.46, SEP, width=0.75)

yy = LY + 0.58
for style, colour, text in [
    ("solid", BLUE,   "foreign key - arrow points at the referencing column"),
    ("dash",  GREY,   "stored, but NOT a foreign key (kept in step by code)"),
    ("dot",   PURPLE, "composite key target: groups (id, event_id)"),
]:
    if style == "solid":
        seg(LX + 0.22, yy + 0.09, LX + 0.72, yy + 0.09, colour, width=1.6)
    elif style == "dash":
        seg(LX + 0.22, yy + 0.09, LX + 0.66, yy + 0.09, colour, width=1.6, dash="dash")
    else:
        seg(LX + 0.22, yy + 0.09, LX + 0.66, yy + 0.09, colour, width=1.6, dash="dot")
    simple(LX + 0.82, yy, LW - 1.0, 0.20, text, 8.5, False, INK)
    yy += 0.245

yy += 0.06
tb(LX + 0.22, yy, 2.6, 0.20,
   [("PK", 8, True, AMBER, MONO, False), ("  primary key in this table", 8.5, False, INK, SEG, False)])
yy += 0.22
tb(LX + 0.22, yy, 2.6, 0.20,
   [("FK", 8, True, BLUE, MONO, False), ("  points at another table", 8.5, False, INK, SEG, False)])

yy += 0.32
seg(LX + 0.20, yy, LX + LW - 0.20, yy, SEP, width=0.75)
for i, line in enumerate([
    "Row Level Security is on for every table: a row is invisible unless a policy",
    "lets you see it. Grants come first, then constraints, then RLS.",
    "Cascade: deleting an event or group removes its dependants - but",
    "events.created_by does NOT cascade, so an event owner cannot be deleted.",
]):
    simple(LX + 0.22, yy + 0.10 + i * 0.215, LW - 0.44, 0.20, line, 7.5, False, MUTED,
           wrap=False)

# ------------------------------------------------------------------- title
simple(0.45, 0.16, 15.0, 0.40,
       "gpstesting - Entity Relationship Diagram", 22, True, INK)
simple(0.47, 0.58, 15.2, 0.22,
       "Supabase / PostgreSQL  \u00b7  rebuilt from supabase/migrations/001-004  \u00b7  "
       "6 tables  \u00b7  lines point from the referenced table to the referencing column",
       9, False, MUTED)


# =========================================================== slide 2 =======
s2 = prs.slides.add_slide(prs.slide_layouts[6])
b2 = s2.shapes
_f2 = s2.background.fill
_f2.solid()
_f2.fore_color.rgb = RGBColor.from_string(BG)
tfb = b2.add_textbox(Inches(0.45), Inches(0.34), Inches(15.0), Inches(0.44))
p = tfb.text_frame.paragraphs[0]
r = p.add_run()
r.text = "gpstesting - relationships, keys and rules"
r.font.size = Pt(22); r.font.bold = True; r.font.name = SEG
r.font.color.rgb = RGBColor.from_string(INK)
tfb.text_frame.word_wrap = False
tfb.text_frame.margin_left = 0

def s2text(x, y, w, h, text, size=9, bold=False, colour=INK, font=SEG, wrap=True):
    box = b2.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.word_wrap = wrap
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    pr = tf.paragraphs[0]
    run = pr.add_run(); run.text = text
    run.font.size = Pt(size); run.font.bold = bold
    run.font.name = font; run.font.color.rgb = RGBColor.from_string(colour)
    return box

s2text(0.47, 0.82, 15.2, 0.24,
       "Every arrow on slide 1 appears here with the rule that actually enforces it.",
       9, False, MUTED, wrap=False)

RELS = [
    ("1",  "profiles.id",  "events.created_by",   "FK, no cascade",
     "an event can never lose its owner, so a busy account cannot be deleted"),
    ("2",  "profiles.id",  "event_roles.user_id", "FK, cascade",
     "delete the account and its event roles go with it"),
    ("3",  "profiles.id",  "group_members.user_id", "FK, cascade",
     "same for group membership"),
    ("4",  "profiles.id",  "locations.user_id",   "none - default auth.uid()",
     "logical only: the column records who uploaded, but is not constrained"),
    ("5",  "events.id",    "event_roles.event_id", "FK, cascade",
     "the role rows belong to the event"),
    ("6",  "events.id",    "groups.event_id",     "FK, cascade",
     "delete the event and its groups vanish"),
    ("7",  "events.id",    "group_members.event_id", "none - kept in step by code",
     "denormalised copy of groups.event_id, so the unique rule can be enforced"),
    ("8",  "events.id",    "locations.event_id",  "FK, NOT VALID, cascade",
     "NOT VALID means existing rows were never checked; new rows are"),
    ("9",  "groups.id",    "group_members.group_id", "FK, cascade",
     "a membership points at exactly one group"),
    ("10", "groups.id",    "locations.group_id",  "FK, NOT VALID, cascade",
     "which team the reading was attributed to"),
    ("11", "groups (id, event_id)", "group_members (group_id, event_id)",
     "composite FK", "stops a member of event A being wired to a group in event B"),
]

cols = [0.55, 2.35, 3.10, 2.55, 6.30]
rows_n = len(RELS) + 1
tbl_shape = b2.add_table(rows_n, 5, Inches(0.45), Inches(1.20), Inches(15.1), Inches(0.3))
tbl = tbl_shape.table
tbl.first_row = True
tbl.horz_banding = False

headers = ["#", "referenced (parent)", "referencing (child)", "enforced by", "what it means"]
for c, (w, head) in enumerate(zip(cols, headers)):
    tbl.columns[c].width = Inches(w)
    cell = tbl.cell(0, c)
    cell.text = head
    pr = cell.text_frame.paragraphs[0]
    pr.runs[0].font.size = Pt(9)
    pr.runs[0].font.bold = True

for i, row in enumerate(RELS, start=1):
    tbl.rows[i].height = Inches(0.34)
    for c, val in enumerate(row):
        cell = tbl.cell(i, c)
        cell.text = val
        cell.margin_left = Inches(0.06)
        cell.margin_right = Inches(0.06)
        cell.margin_top = Inches(0.01)
        cell.margin_bottom = Inches(0.01)
        pr = cell.text_frame.paragraphs[0]
        run = pr.runs[0]
        run.font.size = Pt(8)
        run.font.name = MONO if c in (1, 2) else SEG
        run.font.color.rgb = RGBColor.from_string(INK if c != 3 else TYPE_COL)

tbl.rows[0].height = Inches(0.32)

# --- notes band
NY = 5.90
rect(0.45, NY, 15.10, 4.20, "ffffff", BORDER, radius=0.02, onto=b2)
s2text(0.72, NY + 0.20, 14.6, 0.30, "The rules that are not arrows", 13, True, INK)

notes = [
    ("Primary keys",
     "profiles / events / groups use a uuid primary key. event_roles uses a 3-column primary key "
     "(event_id, user_id, role) - that is what makes roles additive: one person can hold several. "
     "A separate partial unique index, event_roles_one_root, allows only one root per event. "
     "locations is the odd one out: a bigint identity, because it is a high-volume log."),
    ("Unique constraints",
     "profiles.username is unique. events.join_code is unique. groups is unique on (event_id, name), "
     "so two different events may both have a \"Bus A\". groups is also unique on (id, event_id) purely "
     "so group_members can point at that pair. group_members is unique on (event_id, user_id): one group "
     "per person per event."),
    ("Three gates, in order",
     "A request must clear grants first (a missing grant fails with 42501 before anything else), then "
     "constraints, then Row Level Security. RLS is easiest to picture as a WHERE clause that the database "
     "quietly adds to every query - it filters rows, it does not reject requests."),
    ("Why the log is append-only",
     "locations rows are only ever inserted. No update, no delete on a schedule. That is why the map "
     "subscribes to INSERT events only, and why a phone that was offline can upload late readings without "
     "conflicting with anything."),
    ("Open items for the team",
     "docs/gps-checklist.md notes that anonymous sign-ins may still be enabled; the \"edit own display name\" "
     "policy as written also permits changing username; username uniqueness is case-sensitive in the database "
     "and only lower-cased by the app; nothing enforces a single IC per group; and README.md still points at "
     "a deleted .env.example."),
]
yy = NY + 0.62
for head, body in notes:
    s2text(0.72, yy, 3.40, 0.24, head, 10, True, HEAD_COLOUR["event"], wrap=False)
    s2text(4.20, yy - 0.01, 11.10, 0.64, body, 8.5, False, MUTED, wrap=True)
    yy += 0.68

prs.save(OUT)
print("wrote", OUT)
