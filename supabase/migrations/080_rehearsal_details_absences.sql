-- 080: a rehearsal gets an end time and notes, and anyone in the event can say they are not available for one.
-- Run AFTER 079_rehearsals.sql (Supabase -> SQL Editor). Can be re-run.
--
-- NOT AVAILABLE. A person gives a reason, and the request waits until the root or a planner approves or rejects it. They
-- can withdraw it, and ask again after a rejection, until the rehearsal starts. A person reads their own requests; the
-- root and planners read everyone's. All the writes are the three calls below, because a table grant could not stop a
-- person from writing their own request as already approved.

-- ============================================================
-- 1. A rehearsal's end time and notes (both optional)
-- ============================================================
alter table public.event_rehearsals add column if not exists ends_at timestamptz;
alter table public.event_rehearsals add column if not exists note text;

alter table public.event_rehearsals drop constraint if exists event_rehearsals_ends_after_start;
alter table public.event_rehearsals add constraint event_rehearsals_ends_after_start
  check (ends_at is null or ends_at > starts_at);
alter table public.event_rehearsals drop constraint if exists event_rehearsals_note_length;
alter table public.event_rehearsals add constraint event_rehearsals_note_length
  check (note is null or char_length(note) between 1 and 500);

-- ============================================================
-- 2. The requests
-- ============================================================
create table if not exists public.rehearsal_absences (
  id uuid primary key default gen_random_uuid(),
  rehearsal_id uuid not null references public.event_rehearsals (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 300),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (rehearsal_id, user_id)
);
create index if not exists rehearsal_absences_event on public.rehearsal_absences (event_id);

alter table public.rehearsal_absences enable row level security;

drop policy if exists "rehearsal absences: your own, or root and planners" on public.rehearsal_absences;
create policy "rehearsal absences: your own, or root and planners" on public.rehearsal_absences
  for select to authenticated
  using (user_id = auth.uid() or public.has_event_role(event_id, array['root', 'planner']));

revoke all on table public.rehearsal_absences from anon, authenticated, public;
grant select on table public.rehearsal_absences to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.rehearsal_absences;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- 3. The calls
-- ============================================================

-- "I am not available", or, after a rejection, asking again. It always goes back to waiting for a decision.
create or replace function public.rehearsal_absence_request(p_rehearsal uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rehearsal public.event_rehearsals;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_rehearsal from public.event_rehearsals where id = p_rehearsal;
  if not found or not public.is_event_member(v_rehearsal.event_id) then
    raise exception 'That rehearsal is not in one of your events.' using errcode = '42501';
  end if;
  if v_rehearsal.starts_at <= now() then
    raise exception 'That rehearsal has already started.';
  end if;
  if char_length(v_reason) not between 1 and 300 then
    raise exception 'Give a reason of up to 300 characters.';
  end if;

  insert into public.rehearsal_absences (rehearsal_id, event_id, user_id, reason)
  values (p_rehearsal, v_rehearsal.event_id, auth.uid(), v_reason)
  on conflict (rehearsal_id, user_id) do update
    set reason = excluded.reason, status = 'pending', decided_by = null, decided_at = null, created_at = now()
    where public.rehearsal_absences.status <> 'approved';
  if not found then
    raise exception 'Your request for this rehearsal is already approved.';
  end if;
end
$$;

-- Taking your own request back, whatever its answer, until the rehearsal starts.
create or replace function public.rehearsal_absence_withdraw(p_rehearsal uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.event_rehearsals where id = p_rehearsal and starts_at <= now()) then
    raise exception 'That rehearsal has already started.';
  end if;
  delete from public.rehearsal_absences where rehearsal_id = p_rehearsal and user_id = auth.uid();
end
$$;

-- The root's or a planner's answer. It can be changed later.
create or replace function public.rehearsal_absence_decide(p_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event uuid;
begin
  select event_id into v_event from public.rehearsal_absences where id = p_id;
  if not found or not public.has_event_role(v_event, array['root', 'planner']) then
    raise exception 'Only the root or a planner can decide this.' using errcode = '42501';
  end if;
  update public.rehearsal_absences
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(),
         decided_at = now()
   where id = p_id;
end
$$;

revoke execute on function public.rehearsal_absence_request(uuid, text) from public, anon;
revoke execute on function public.rehearsal_absence_withdraw(uuid) from public, anon;
revoke execute on function public.rehearsal_absence_decide(uuid, boolean) from public, anon;
grant execute on function public.rehearsal_absence_request(uuid, text) to authenticated;
grant execute on function public.rehearsal_absence_withdraw(uuid) to authenticated;
grant execute on function public.rehearsal_absence_decide(uuid, boolean) to authenticated;
