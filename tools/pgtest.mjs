// tools/pgtest.mjs - apply the bench's migrations to a real Postgres, and run the bench's SQL tests.
//
// WHY THIS EXISTS. The bench's rules are decided in SQL -- what a shape may be, who may write one, how
// big the bench may get -- and every round of it has shipped a migration. Until this file the only way
// to find out whether a migration was even VALID was to paste it into the Supabase SQL Editor against
// the real project, which is a database with a real canvas in it. This runs the same files, in the
// same order, on a database that starts empty and is thrown away:
//
//     node tools/pgtest.mjs
//
// PGlite is Postgres compiled to WebAssembly: the same parser, the same plpgsql, the same RLS and the
// same constraints, in this process, with no server to start. What it is not is Supabase -- the roles,
// the `auth` schema and the Realtime publication are stubbed by supabase/tests/stub_supabase.sql -- so
// this checks the schema and the rules, and not GoTrue, PostgREST or the Realtime socket. Those are
// what tools/bench_harness.mjs covers instead, from the other end, through two real browsers.
//
// It runs six phases, each on a database of its own, and reports every one of them:
//
//   empty    a database with no bench at all: the migrations must apply in order, 001–005 then 014–019
//   split    a bench that already holds a canvas, migrated from 016 to 017: the split is checked
//            shape by shape, the old document is checked to be untouched, and re-running 017 must
//            change nothing
//   guard    a bench whose canvas holds a shape with no id: 017 must REFUSE it rather than lose it
//   objects  the new behaviour, from supabase/tests/objects_rls.sql
//   legacy   supabase/tests/layouts_rls.sql, the suite for the schema 001-005 and 014-016 built
//   roles    supabase/tests/roles_test.sql: profiles and the role hierarchy (001, 002, 030 and 031)
//   search   supabase/tests/people_search_test.sql: find people by name, add them by id (032)
//   details  supabase/tests/event_details_test.sql: the root edits the event's details (033)
//   planners supabase/tests/planners_test.sql: planners are never in a group (034)
//   groups   supabase/tests/edit_group_test.sql: rename a group, change its colour (035)
//   headcount supabase/tests/auto_headcount_test.sql: a group's headcount is the number of people in it (036)
//   attendance supabase/tests/attendance_test.sql: roll calls, by hand or by scanning a QR (037)
//   sos      supabase/tests/sos_test.sql: anyone in an event can call for help (038)
//
// Exit code 0 only when every phase passes.
import { PGlite } from '@electric-sql/pglite'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')

const read = (path) => readFileSync(join(root, path), 'utf8')

const STUB = read('supabase/tests/stub_supabase.sql')

// In order, which is the order the Supabase SQL Editor wants them in (README, "Supabase").
const MIGRATION_FILES = [
  '001_locations.sql',
  '002_users_events_groups.sql',
  '003_stop_sharing.sql',
  '004_tracking_passes.sql',
  '005_layouts.sql',
  '014_floor_plan_bounds.sql',
  '015_presence_and_views.sql',
  '016_object_locks.sql',
  '017_object_rows.sql',
  '018_drop_frozen_canvas.sql',
  '019_bench_head.sql',
]
const MIGRATIONS = MIGRATION_FILES.map((name) => ({ name, sql: read('supabase/migrations/' + name) }))
const named = (name) => MIGRATIONS.find((m) => m.name === name)
// The schema the suite in phase `legacy` was written for: everything before the canvas became rows.
// (001-005, then the bench's 014-016: 006-013 are the event app's and the bench never needed them)
const UP_TO_016 = MIGRATIONS.filter((m) => {
  const n = Number(m.name.slice(0, 3))
  return n <= 5 || (n >= 14 && n <= 16)
})

const USER_A = '11111111-1111-1111-1111-111111111111'
const USER_B = '22222222-2222-2222-2222-222222222222'

// Two users, so that "somebody else has this" is a real second person rather than a second session of
// the same one -- and so that a refusal can name them.
const SEED_USERS = `
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('${USER_A}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'bench-a@example.test', '', now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"username":"bench_test_a","display_name":"Bench Test A"}'::jsonb, now(), now()),
  ('${USER_B}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'bench-b@example.test', '', now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"username":"bench_test_b","display_name":"Bench Test B"}'::jsonb, now(), now());
`

// A canvas as 005-008 would have stored it: three floor plans and two areas. Two of the plans share a
// picture -- which is what a copy, or a second upload of the same level, looks like -- and that is the
// case the split makes the bench SMALLER for, because the picture is stored once instead of twice.
const PICTURE_A = 'data:image/png;base64,' + 'A'.repeat(400000)
const PICTURE_B = 'data:image/jpeg;base64,' + 'B'.repeat(100000)

function seedCanvas({ broken = false } = {}) {
  const plans = [
    plan('plan-1', 'Level 1', 1.3, 103.8, PICTURE_A),
    plan('plan-2', 'Level 2', 1.301, 103.801, PICTURE_A),
    plan('plan-3', 'Level 3', 1.302, 103.802, PICTURE_B),
  ]
  const areas = [
    area('area-1', 'Stage', 'stage', 1.3, 103.8),
    area('area-2', 'No go', 'no_go', 1.301, 103.801),
  ]

  // A shape with no id is what the split cannot represent: it has no row to go to. It is refused by
  // save_bench() today, so it can only arrive by hand -- which is exactly what this seed is.
  if (broken) areas.push({ name: 'Nameless', kind: 'zone', points: ring(1.305, 103.805) })

  // The dollar-quoted tag needs its spaces: `$doc${...}` in a JS template literal loses the closing
  // `$` to the interpolation, and `$doc{` is not a quote at all.
  const doc = JSON.stringify({ view: { lat: 1.3, lng: 103.8, zoom: 17 }, floorPlans: plans, polygons: areas })

  return `
insert into public.layouts (created_by, data) values ('${USER_A}', $doc$ ${doc} $doc$::jsonb);
`
}

function plan(id, name, lat, lng, image) {
  return {
    id,
    name,
    centre: [lat, lng],
    angleDeg: 0,
    widthM: 100,
    heightM: 50,
    opacity: 0.6,
    visible: true,
    image,
  }
}

function area(id, name, kind, lat, lng) {
  return { id, name, kind, points: ring(lat, lng) }
}

function ring(lat, lng) {
  return [
    [lat, lng],
    [lat + 0.0002, lng + 0.0002],
    [lat + 0.0001, lng + 0.0004],
  ]
}

// ---------- the runner ----------
let failures = 0
let checks = 0
// `node tools/pgtest.mjs split` runs one phase, which is how a failure is worked on.
const only = process.argv[2] || ''

// One phase: a database of its own, the files it is given, and a body that either returns some numbers
// to print or throws. `setup` may be null when a phase only needs the migrations.
async function phase(name, { migrations, setup, body }) {
  if (only && only !== name) return
  const db = new PGlite()
  try {
    await db.exec(STUB)
    for (const migration of migrations) {
      try {
        await db.exec(migration.sql)
      } catch (error) {
        throw new Error(`applying ${migration.name}: ${describe(error, migration.sql)}`)
      }
    }
    if (setup) await runSql(db, setup, 'the seed')
    const notes = await body(db)
    console.log(`PASS  ${name}`)
    for (const note of notes || []) console.log(`      ${note}`)
  } catch (error) {
    failures += 1
    console.log(`FAIL  ${name}`)
    console.log(`      ${error.pgDetail || error.message}`)
  } finally {
    await db.close()
  }
}

// Run a SQL file (or any script) and, when it fails, say as much about where as Postgres will. The
// file's own checks are counted as well, so the summary is the number of things actually asserted
// rather than the number of phases.
async function runSql(db, sql, label) {
  try {
    await db.exec(sql)
  } catch (error) {
    const wrapped = new Error(`${label}: ${describe(error, sql)}`)
    wrapped.pgDetail = `${label}: ${describe(error, sql)}`
    throw wrapped
  }
  checks += (sql.match(/raise exception 'FAIL/g) || []).length
}

// One assertion, with the count kept so the report can say how much was actually checked.
function check(what, condition, detail = '') {
  checks += 1
  if (!condition) throw new Error(`check failed: ${what}${detail ? ' -- ' + detail : ''}`)
}

// A single value out of a query, which is what most of these assertions are about.
async function one(db, sql) {
  try {
    const result = await db.query(sql)
    const row = result.rows[0]
    return row ? Object.values(row)[0] : undefined
  } catch (error) {
    const detail = describe(error, sql)
    const wrapped = new Error(detail)
    wrapped.pgDetail = detail
    throw wrapped
  }
}

// Everything Postgres is willing to say about a failure. The file and the position matter here: these
// errors come out of a thousand-line SQL suite, and "column reference rev is ambiguous" on its own
// says nothing about where.
function describe(error, sql) {
  const parts = [error.message]
  for (const field of ['detail', 'hint', 'where']) {
    if (error[field]) parts.push(`${field}: ${error[field]}`)
  }
  const at = Number(error.position)
  if (sql && at > 0) parts.push(`near: ...${sql.slice(Math.max(0, at - 90), at + 90)}...`)
  return parts.join('\n      ')
}

// A refused statement, as the message it was refused with -- so a check can be about the REFUSAL and
// not about the fact that something went wrong.
async function refused(db, sql) {
  try {
    await db.exec(sql)
  } catch (error) {
    return error.message
  }
  return ''
}

// ---------- phase 1: an empty database ----------
await phase('empty', {
  migrations: MIGRATIONS,
  body: async (db) => {
    const tables = await one(
      db,
      `select count(*)::int from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname in ('layouts', 'layout_locks', 'layout_objects', 'layout_images',
                           'layout_presence', 'layout_views')`,
    )
    check('the bench tables exist', Number(tables) === 6, `found ${tables}`)

    const functions = await one(
      db,
      `select count(*)::int from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('open_bench', 'save_object', 'delete_object', 'save_bench')`,
    )
    check('the four doors exist', Number(functions) === 4, `found ${functions}`)

    // Nothing was written to a database that has no bench: open_bench() is what makes one.
    const rows = await one(db, 'select count(*)::int from public.layouts')
    check('no bench row was invented by the migrations', Number(rows) === 0, `found ${rows}`)

    const images = await one(db, 'select count(*)::int from public.layout_images')
    check('no pictures either', Number(images) === 0, `found ${images}`)

    return ['001–005 and 014–019 applied in order and left an empty, working schema']
  },
})

// ---------- phase 2: the split, and the frozen canvas going ----------
await phase('split', {
  migrations: UP_TO_016,
  setup: SEED_USERS + seedCanvas(),
  body: async (db) => {
    const before = await one(db, 'select octet_length(data::text)::int from public.layouts')
    check('the old canvas is there to split', before > 0)

    await runSql(db, named('017_object_rows.sql').sql, '017_object_rows.sql')

    const plans = await one(db, `select count(*)::int from public.layout_objects where kind = 'plan'`)
    const areas = await one(db, `select count(*)::int from public.layout_objects where kind = 'area'`)
    const images = await one(db, 'select count(*)::int from public.layout_images')
    check('three floor plans became three rows', Number(plans) === 3, `found ${plans}`)
    check('two areas became two rows', Number(areas) === 2, `found ${areas}`)
    // Three plans, two pictures: the level that was uploaded twice is stored once.
    check('two distinct pictures became two rows', Number(images) === 2, `found ${images}`)

    const withImage = await one(
      db,
      `select count(*)::int from public.layout_objects where jsonb_exists(data, 'image')`,
    )
    check('no shape row carries its picture', Number(withImage) === 0, `${withImage} do`)

    const pointers = await one(
      db,
      `select count(*)::int from public.layout_objects o
       join public.layout_images i on i.layout_id = o.layout_id and i.image_id = o.image_id
       where md5(i.data) = i.image_id`,
    )
    check('every plan points at its own picture', Number(pointers) === 3, `${pointers} do`)

    const frozen = await one(db, `select data -> 'floorPlans' -> 0 ->> 'image' from public.layouts`)
    check('the old document is untouched', frozen === PICTURE_A, String(frozen).slice(0, 40))

    const rev = await one(db, 'select rev from public.layouts')
    check('the bench starts at revision 1', Number(rev) === 1, `found ${rev}`)

    // The size the ring shows. It comes DOWN, and by about one copy of the shared picture: the old
    // document carried that picture twice, once inside each plan that used it.
    const after = await one(db, 'select public.layout_bytes(id)::int from public.layouts')
    const drop = before - after
    check(
      'the second copy of a shared picture is gone',
      drop > PICTURE_A.length * 0.9 && drop < PICTURE_A.length * 1.2,
      `${before} bytes before, ${after} after: ${drop} bytes less, and one copy is ${PICTURE_A.length}`,
    )

    // Re-running the file, which is what happens when somebody edits it and pastes it again, must
    // change nothing at all -- and must not wind the revision counter back, which every open page
    // compares against.
    await runSql(db, named('017_object_rows.sql').sql, '017_object_rows.sql a second time')
    const twice = await db.query(
      `select (select count(*)::int from public.layout_objects) as objects,
              (select count(*)::int from public.layout_images) as images,
              (select rev from public.layouts) as rev`,
    )
    check(
      'a second run changes nothing',
      twice.rows[0].objects === 5 && twice.rows[0].images === 2 && Number(twice.rows[0].rev) === 1,
      JSON.stringify(twice.rows[0]),
    )

    // And a write after the split moves it: revision 2, and the shape's row with it. `set` rather than
    // `set local`, because each of these calls is its own transaction and the claims have to outlive it.
    await runSql(
      db,
      `set role authenticated;
       set request.jwt.claims = '{"sub":"${USER_A}","role":"authenticated"}';`,
      'signing in',
    )
    const row = await db.query('select * from public.open_bench()')
    check('open_bench() hands back the whole canvas', row.rows[0].shapes.length === 5)
    check('...and the pictures', Object.keys(row.rows[0].images).length === 2)
    check('...and the home view, out of the frozen document', row.rows[0].home && row.rows[0].home.zoom === 17, JSON.stringify(row.rows[0].home))
    await runSql(db, 'reset role; reset request.jwt.claims;', 'signing out')

    // ---- and now the frozen canvas goes ---------------------------------
    const frozenBytes = await one(db, 'select octet_length(data::text)::int from public.layouts')
    await runSql(db, named('018_drop_frozen_canvas.sql').sql, '018_drop_frozen_canvas.sql')

    const stillThere = await one(
      db,
      `select count(*)::int from information_schema.columns
       where table_schema = 'public' and table_name = 'layouts' and column_name = 'data'`,
    )
    check('the frozen canvas is gone', Number(stillThere) === 0, `${stillThere} column(s) named data`)

    const oldFunctions = await one(
      db,
      `select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('layout_data_ok', 'layout_list', 'layout_problem', 'floor_plan_ok')`,
    )
    check('and the functions that described it', Number(oldFunctions) === 0, `${oldFunctions} left`)

    const home = await one(db, 'select home -> \'zoom\' from public.layouts')
    check('the home view survived the drop', Number(home) === 17, String(home))

    const kept = await one(
      db,
      `select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('area_ok', 'floor_plan_fields_ok', 'shape_problem')`,
    )
    check('and the rules a shape still has to meet are still there', Number(kept) === 3, `${kept} left`)

    // A second run finds nothing left to do, and cannot fail on the column it just dropped.
    await runSql(db, named('018_drop_frozen_canvas.sql').sql, '018_drop_frozen_canvas.sql a second time')

    return [
      `split: 3 plans + 2 areas into 2 pictures, ${before} bytes before and ${after} after`,
      'a second run of 017 changed nothing, and the old document was still there for it',
      `then 018 dropped the ${frozenBytes} bytes of frozen canvas, leaving the home view and every row`,
    ]
  },
})

// ---------- phase 3: the two guards ----------
await phase('guard', {
  migrations: UP_TO_016,
  setup: SEED_USERS + seedCanvas({ broken: true }),
  body: async (db) => {
    const message = await refused(db, named('017_object_rows.sql').sql)
    check('017 refuses a canvas it cannot split', /no id/.test(message), message || 'it did not refuse')

    // Refused means refused: the tables it had begun to build must not be left half-made.
    const objects = await one(db, `select to_regclass('public.layout_objects')::text`)
    check('nothing was left half-applied', objects === null, String(objects))

    return ['a shape with no id stops the migration instead of being lost']
  },
})

// The other guard, and the more important one: the drop of the frozen canvas must refuse to happen if
// the rows are not the whole bench. A shape with no row would be lost for good -- there is no copy of it
// anywhere else -- so this puts the bench in exactly that state (by taking a row away as the owner, which
// is a state no page can reach) and checks that 018 will not have it.
await phase('frozen', {
  migrations: UP_TO_016,
  setup: SEED_USERS + seedCanvas(),
  body: async (db) => {
    await runSql(db, named('017_object_rows.sql').sql, '017_object_rows.sql')
    await runSql(db, `delete from public.layout_objects where object_id = 'area-2'`, 'losing a row')

    const message = await refused(db, named('018_drop_frozen_canvas.sql').sql)
    check('018 refuses to drop a canvas the rows do not account for', /no row/.test(message), message || 'it dropped it anyway')

    const stillThere = await one(
      db,
      `select count(*)::int from information_schema.columns
       where table_schema = 'public' and table_name = 'layouts' and column_name = 'data'`,
    )
    check('and the frozen canvas is still there to recover from', Number(stillThere) === 1, `${stillThere} column(s)`)

    return ['a shape with no row stops the drop rather than being lost with the document']
  },
})

// ---------- phase 4: the new behaviour ----------
await phase('objects', {
  migrations: MIGRATIONS,
  body: async (db) => {
    await runSql(db, read('supabase/tests/objects_rls.sql'), 'objects_rls.sql')
    return ['supabase/tests/objects_rls.sql passed']
  },
})

// ---------- phase 5: the suite for 001-005 and 014-016 ----------
await phase('legacy', {
  migrations: UP_TO_016,
  body: async (db) => {
    await runSql(db, read('supabase/tests/layouts_rls.sql'), 'layouts_rls.sql')
    return ['supabase/tests/layouts_rls.sql passed against the schema it was written for']
  },
})

// ---------- phase 6: the "Create an event" wizard (030; 023 on its branch) ----------
// 020-029 need PostGIS / pg_cron, which PGlite doesn't have, so this applies 001-002, the two columns of 022 that
// 030 reads, and then 030 itself.
await phase('wizard', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/event_wizard.sql'), 'event_wizard.sql')
    // 030 must be safe to paste into the SQL Editor a second time
    await runSql(db, read('supabase/migrations/030_event_wizard.sql'), '030_event_wizard.sql a second time')
    return ['supabase/tests/event_wizard.sql passed, and 030 re-applies cleanly']
  },
})

// ---------- phase 7: profiles and the role hierarchy (031, on top of the wizard's 030) ----------
await phase('roles', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/roles_test.sql'), 'roles_test.sql')
    return ['supabase/tests/roles_test.sql passed']
  },
})

// ---------- phase 8: find people by name, add them by id (032, on top of 031) ----------
await phase('search', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '032_people_search_by_name.sql', sql: read('supabase/migrations/032_people_search_by_name.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/people_search_test.sql'), 'people_search_test.sql')
    await runSql(db, read('supabase/migrations/032_people_search_by_name.sql'), '032 a second time')
    return ['supabase/tests/people_search_test.sql passed, and 032 re-applies cleanly']
  },
})

// ---------- phase 9: the root edits the event's details (033, on top of 030's columns) ----------
await phase('details', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '033_event_details.sql', sql: read('supabase/migrations/033_event_details.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/event_details_test.sql'), 'event_details_test.sql')
    await runSql(db, read('supabase/migrations/033_event_details.sql'), '033 a second time')
    return ['supabase/tests/event_details_test.sql passed, and 033 re-applies cleanly']
  },
})

// ---------- phase 10: planners are never in a group (034, on top of 031); 031's suite must still pass ----------
await phase('planners', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '034_planners_not_in_groups.sql', sql: read('supabase/migrations/034_planners_not_in_groups.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/planners_test.sql'), 'planners_test.sql')
    await runSql(db, read('supabase/tests/roles_test.sql'), 'roles_test.sql with 034')
    await runSql(db, read('supabase/migrations/034_planners_not_in_groups.sql'), '034 a second time')
    return ['supabase/tests/planners_test.sql and roles_test.sql passed, and 034 re-applies cleanly']
  },
})

// ---------- phase 11: the root or a planner renames / recolours a group (035) ----------
await phase('groups', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '034_planners_not_in_groups.sql', sql: read('supabase/migrations/034_planners_not_in_groups.sql') },
    { name: '035_edit_group.sql', sql: read('supabase/migrations/035_edit_group.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/edit_group_test.sql'), 'edit_group_test.sql')
    await runSql(db, read('supabase/migrations/035_edit_group.sql'), '035 a second time')
    return ['supabase/tests/edit_group_test.sql passed, and 035 re-applies cleanly']
  },
})

// ---------- phase 12: a group's headcount is the number of people in it (036) ----------
await phase('headcount', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    { name: '020 (headcount column only)', sql: 'alter table public.groups add column if not exists headcount integer check (headcount is null or headcount >= 0);' },
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '034_planners_not_in_groups.sql', sql: read('supabase/migrations/034_planners_not_in_groups.sql') },
    { name: '036_auto_headcount.sql', sql: read('supabase/migrations/036_auto_headcount.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/auto_headcount_test.sql'), 'auto_headcount_test.sql')
    await runSql(db, read('supabase/tests/planners_test.sql'), 'planners_test.sql with 036')
    await runSql(db, read('supabase/migrations/036_auto_headcount.sql'), '036 a second time')
    return ['supabase/tests/auto_headcount_test.sql and planners_test.sql passed, and 036 re-applies cleanly']
  },
})

// ---------- phase 13: attendance with a code that changes every 30 s (037) ----------
await phase('attendance', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    { name: '034_planners_not_in_groups.sql', sql: read('supabase/migrations/034_planners_not_in_groups.sql') },
    { name: '037_attendance.sql', sql: read('supabase/migrations/037_attendance.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/attendance_test.sql'), 'attendance_test.sql')
    await runSql(db, read('supabase/migrations/037_attendance.sql'), '037 a second time')
    return ['supabase/tests/attendance_test.sql passed, and 037 re-applies cleanly']
  },
})

// ---------- phase 14: 037 over its first version (the 6-digit spoken code), with a check-in by code in it ----------
await phase('attendance-upgrade', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '037 first version (its tables and one function)',
      sql: `create table public.attendance_rollcalls (
              id uuid primary key default gen_random_uuid(),
              event_id uuid not null references public.events (id) on delete cascade,
              group_id uuid not null references public.groups (id) on delete cascade,
              title text not null, opened_by uuid, opened_at timestamptz not null default now(),
              closes_at timestamptz not null, closed_at timestamptz);
            create table public.attendance_secrets (rollcall_id uuid primary key references public.attendance_rollcalls (id) on delete cascade, secret text not null);
            create table public.attendance_checkins (
              rollcall_id uuid not null references public.attendance_rollcalls (id) on delete cascade,
              event_id uuid not null, group_id uuid not null, user_id uuid not null,
              status text not null check (status in ('present', 'excused')),
              method text not null check (method in ('code', 'manual')),
              marked_by uuid, at timestamptz not null default now(), primary key (rollcall_id, user_id));
            create table public.attendance_tries (rollcall_id uuid, user_id uuid, wrong integer, last_wrong_at timestamptz);
            create function public.check_in(p_event uuid, p_code text) returns jsonb language sql as 'select null::jsonb';
            insert into auth.users (id, email, raw_user_meta_data)
              values ('37100000-0000-0000-0000-000000000001', 'up@example.test', '{"username":"up_r","display_name":"Up Root"}');
            insert into public.events (id, name, created_by) values ('37100000-0000-0000-0000-0000000000e1', 'Up', '37100000-0000-0000-0000-000000000001');
            insert into public.groups (id, event_id, name) values ('37100000-0000-0000-0000-0000000000a1', '37100000-0000-0000-0000-0000000000e1', 'G');
            insert into public.attendance_rollcalls (id, event_id, group_id, title, closes_at)
              values ('37100000-0000-0000-0000-0000000000c1', '37100000-0000-0000-0000-0000000000e1', '37100000-0000-0000-0000-0000000000a1', 'Old', now());
            insert into public.attendance_checkins values ('37100000-0000-0000-0000-0000000000c1', '37100000-0000-0000-0000-0000000000e1',
              '37100000-0000-0000-0000-0000000000a1', '37100000-0000-0000-0000-000000000001', 'present', 'code', null, now());`,
    },
    { name: '037_attendance.sql', sql: read('supabase/migrations/037_attendance.sql') },
  ],
  body: async (db) => {
    const r = await db.query(
      `select (select method from public.attendance_checkins) as method,
              (select mode from public.attendance_rollcalls) as mode,
              to_regclass('public.attendance_tries') as tries,
              to_regprocedure('public.check_in(uuid, text)') as old_fn`,
    )
    const row = r.rows[0]
    if (row.method !== 'scan' || row.mode !== 'manual' || row.tries !== null || row.old_fn !== null) {
      throw new Error('037 over its first version: ' + JSON.stringify(row))
    }
    return ["037 upgrades its first version: 'code' check-ins become 'scan', the spoken code's table and function are gone"]
  },
})

// ---------- phase 15: SOS (038) ----------
await phase('sos', {
  migrations: [
    named('001_locations.sql'),
    named('002_users_events_groups.sql'),
    {
      name: '022 (columns only)',
      sql: `alter table public.events add column if not exists is_simulation boolean not null default false;
            alter table public.profiles add column if not exists is_simulated boolean not null default false;`,
    },
    { name: '030_event_wizard.sql', sql: read('supabase/migrations/030_event_wizard.sql') },
    { name: '031_people_and_roles.sql', sql: read('supabase/migrations/031_people_and_roles.sql') },
    {
      name: '028 (the push queue only)',
      sql: `create table public.push_queue (
              id bigserial primary key,
              user_id uuid not null references public.profiles (id) on delete cascade,
              event_id uuid not null references public.events (id) on delete cascade,
              session_id uuid,
              kind text not null,
              dedup text not null unique,
              title text not null, body text not null, data jsonb not null default '{}',
              created_at timestamptz not null default now(), sent_at timestamptz);`,
    },
    { name: '038_sos.sql', sql: read('supabase/migrations/038_sos.sql') },
  ],
  body: async (db) => {
    await runSql(db, read('supabase/tests/sos_test.sql'), 'sos_test.sql')
    await runSql(db, read('supabase/migrations/038_sos.sql'), '038 a second time')
    return ['supabase/tests/sos_test.sql passed, and 038 re-applies cleanly']
  },
})

console.log('')
console.log(failures === 0 ? `all phases passed (${checks} assertions)` : `${failures} phase(s) failed`)
process.exit(failures === 0 ? 0 : 1)
