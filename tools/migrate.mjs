#!/usr/bin/env node
// Apply the numbered migrations, and remember which ones have been applied.
//
// Until now the files in supabase/migrations/ were pasted into the Supabase SQL Editor by hand, one at a time,
// and nothing recorded which of them the database had actually seen. That is fine while there is one person and
// one draft app; it stops being fine at step 2 of the planning overhaul, when a migration has to be applied
// immediately before a screen is clicked.
//
//     node tools/migrate.mjs status            what the database has, what the folder has, what has drifted
//     node tools/migrate.mjs up                apply everything pending, in order, each in one transaction
//     node tools/migrate.mjs up --to 040       stop after 040
//     node tools/migrate.mjs up --dry          say what would happen, change nothing
//     node tools/migrate.mjs adopt --to 038    record files as applied WITHOUT running them (used once, for
//                                              the files that were pasted in by hand)
//
// The ledger is ops.schema_migrations: version, filename, checksum, applied_at. It is ours, not the Supabase
// CLI's (writing that one in a shape the CLI does not expect is worse than having none). It is not reachable
// from the app: the schema and the table are revoked from anon/authenticated and RLS is on with no policy, so
// the only way in is the Management API with a personal access token.
//
// Exits are set, never called: on Windows a process that calls process.exit() while a fetch is still winding
// down aborts with a libuv assertion, which prints after the real result and makes a clean run look broken.
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const REF = process.env.SUPABASE_REF || 'ikvzxmygjhpxrqiiyzqe'
const PAT = process.env.SUPABASE_PAT
const DIR = path.resolve('supabase/migrations')

if (!PAT) {
  console.error('Set SUPABASE_PAT (a personal access token from supabase.com/dashboard/account/tokens).')
  process.exit(2)
}

async function query(sql) {
  const res = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 800)}`)
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

const LEDGER = `
create schema if not exists ops;
create table if not exists ops.schema_migrations (
  version     text primary key,
  filename    text not null,
  checksum    text not null,
  applied_at  timestamptz not null default now()
);
revoke all on schema ops from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema ops from %I', r);
      execute format('revoke all on ops.schema_migrations from %I', r);
    end if;
  end loop;
end $$;
alter table ops.schema_migrations enable row level security;
`

const files = fs
  .readdirSync(DIR)
  .filter((name) => /^\d{3}_.*\.sql$/.test(name))
  .sort()
  .map((name) => {
    const body = fs.readFileSync(path.join(DIR, name), 'utf8')
    return {
      version: name.slice(0, 3),
      filename: name,
      checksum: crypto.createHash('sha256').update(body).digest('hex').slice(0, 16),
      body,
    }
  })

const argv = process.argv.slice(2)
const command = argv.find((a) => !a.startsWith('-')) || 'status'
const after = (flag) => {
  const index = argv.indexOf(flag)
  return index > -1 ? argv[index + 1] : null
}
const to = after('--to')
const from = after('--from')
const dry = argv.includes('--dry')

const selected = files.filter((file) => (!to || file.version <= to) && (!from || file.version >= from))

async function status() {
  let applied = []
  try {
    applied = await query('select version, filename, checksum, applied_at from ops.schema_migrations order by version')
    if (!Array.isArray(applied)) applied = []
  } catch {
    console.log('no ledger yet (ops.schema_migrations does not exist) — nothing is recorded as applied\n')
  }
  const byVersion = new Map(applied.map((row) => [row.version, row]))
  let pending = 0
  let drifted = 0
  for (const file of files) {
    const row = byVersion.get(file.version)
    if (!row) {
      pending += 1
      console.log(`  pending  ${file.version}  ${file.filename}`)
    } else if (row.checksum !== file.checksum) {
      drifted += 1
      console.log(`  DRIFT    ${file.version}  ${file.filename}  (applied ${row.checksum}, file ${file.checksum})`)
    } else {
      console.log(`  applied  ${file.version}  ${file.filename}  ${String(row.applied_at).slice(0, 19)}`)
    }
  }
  for (const row of applied.filter((r) => !files.some((f) => f.version === r.version))) {
    console.log(`  MISSING  ${row.version}  ${row.filename}  (recorded, no file)`)
  }
  console.log('')
  console.log(`${files.length} files, ${applied.length} applied, ${pending} pending, ${drifted} drifted`)
  process.exitCode = drifted ? 1 : 0
}

async function adopt() {
  await query(LEDGER)
  let count = 0
  for (const file of selected) {
    const rows = await query(
      `insert into ops.schema_migrations (version, filename, checksum)
       values ('${file.version}', '${file.filename}', '${file.checksum}')
       on conflict (version) do nothing
       returning version`,
    )
    if (Array.isArray(rows) && rows.length) {
      count += 1
      console.log(`  adopted  ${file.version}  ${file.filename}`)
    }
  }
  console.log(`\nadopted ${count} file(s) as already applied; nothing was run`)
}

async function up() {
  await query(LEDGER)
  const applied = await query('select version, checksum from ops.schema_migrations')
  const done = new Map((Array.isArray(applied) ? applied : []).map((row) => [row.version, row.checksum]))
  const pending = selected.filter((file) => !done.has(file.version))

  for (const [version, checksum] of done) {
    const file = files.find((f) => f.version === version)
    if (file && file.checksum !== checksum) {
      console.log(`  warning  ${version} changed since it was applied; this run will not touch it`)
    }
  }

  if (!pending.length) {
    console.log('nothing to apply')
    return
  }
  if (dry) {
    for (const file of pending) console.log(`  would apply  ${file.version}  ${file.filename}`)
    return
  }

  for (const file of pending) {
    const started = Date.now()
    // One transaction per file: a migration that half-applies is worse than one that does not apply at all.
    const script = [
      'begin;',
      file.body,
      `insert into ops.schema_migrations (version, filename, checksum)
       values ('${file.version}', '${file.filename}', '${file.checksum}')
       on conflict (version) do update set checksum = excluded.checksum, applied_at = now();`,
      'commit;',
    ].join('\n')
    try {
      await query(script)
    } catch (error) {
      // The transaction rolled back, so the ledger does not say this file applied. Say so, and stop here rather
      // than applying the next file on top of a schema that is missing the one before it.
      console.error(`\nFAILED ${file.filename} — the transaction was rolled back, nothing was recorded\n${error.message}`)
      process.exitCode = 1
      return
    }
    console.log(`  applied  ${file.version}  ${file.filename}  ${Date.now() - started} ms`)
  }
  console.log(`\napplied ${pending.length} file(s)`)
}

const commands = { status, adopt, up }
if (!commands[command]) {
  console.error(`unknown command ${command}; use status, up or adopt`)
  process.exit(2)
}
await commands[command]()
