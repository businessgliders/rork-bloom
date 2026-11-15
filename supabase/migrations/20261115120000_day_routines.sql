-- "Just today" routine changes: one person's own wake, bed and meal times for one day.
-- Dose times for that day stay in planned_doses (source = 'override'); this table holds the
-- rest of the day so both phones show the same routine.
create table if not exists public.day_routines (
  id uuid primary key default gen_random_uuid(),
  pregnancy_id uuid not null references public.pregnancies(id) on delete cascade,
  taker_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  template_id uuid references public.schedule_templates(id) on delete set null,
  wake_time time,
  bed_time time,
  -- [{"id": uuid, "name": text, "time": "HH:MM", "duration_min": int}]
  meals jsonb check (meals is null or jsonb_typeof(meals) = 'array'),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pregnancy_id, taker_id, local_date)
);

create index if not exists day_routines_pregnancy_date_idx on public.day_routines (pregnancy_id, local_date);

alter table public.day_routines enable row level security;

drop policy if exists "members all day routines" on public.day_routines;
create policy "members all day routines" on public.day_routines
  for all
  using (private.is_member(pregnancy_id))
  with check (private.is_member(pregnancy_id));

drop trigger if exists check_taker on public.day_routines;
create trigger check_taker before insert or update of taker_id, pregnancy_id on public.day_routines
  for each row execute function private.check_taker_member();

drop trigger if exists set_updated_at on public.day_routines;
create trigger set_updated_at before update on public.day_routines
  for each row execute function private.set_updated_at();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'day_routines'
  ) then
    alter publication supabase_realtime add table public.day_routines;
  end if;
end $$;
