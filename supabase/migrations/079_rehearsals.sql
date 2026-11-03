-- 079: rehearsals -- the dates and times an event's people are due to practise.
--
-- WHO. Everyone in the event reads them (a calendar, and the "Next rehearsal" line on the schedule). Only the root and
-- planners add or remove one: a group admin, an IC or a member reads. The rule lives here, in the policies; the
-- pages only hide what these would refuse.
--
-- WHAT IS NOT HERE. A rehearsal is a time, and it does not start a session or run a plan. To change one, remove it and add
-- another, so there is no update grant. A new one must be in the future; a past one stays on the calendar until removed.

create table if not exists public.event_rehearsals (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  starts_at timestamptz not null,
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (event_id, starts_at)
);

alter table public.event_rehearsals enable row level security;

drop policy if exists "rehearsals: everyone in the event reads" on public.event_rehearsals;
create policy "rehearsals: everyone in the event reads" on public.event_rehearsals
  for select to authenticated
  using (public.is_event_member(event_id));

drop policy if exists "rehearsals: root and planners add" on public.event_rehearsals;
create policy "rehearsals: root and planners add" on public.event_rehearsals
  for insert to authenticated
  with check (
    public.has_event_role(event_id, array['root', 'planner'])
    and created_by = auth.uid()
    and starts_at > now()
  );

drop policy if exists "rehearsals: root and planners remove" on public.event_rehearsals;
create policy "rehearsals: root and planners remove" on public.event_rehearsals
  for delete to authenticated
  using (public.has_event_role(event_id, array['root', 'planner']));

revoke all on table public.event_rehearsals from anon, authenticated, public;
grant select, insert, delete on table public.event_rehearsals to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.event_rehearsals;
exception when duplicate_object then null;
end $$;
