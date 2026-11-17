-- Same-day re-planning from actual meal times: a dose moved because a meal was eaten at
-- another time is stored as source = 'meal_adjust', with why it moved so the partner's
-- phone can say "Prenatal AM moved to 3:30 · after a late lunch".
alter table public.planned_doses drop constraint if exists planned_doses_source_check;
alter table public.planned_doses
  add constraint planned_doses_source_check check (source in ('template', 'override', 'meal_adjust'));

-- "follows:dinner", "with:lunch", "late:lunch"; null for every other source.
alter table public.planned_doses add column if not exists meal_reason text;
