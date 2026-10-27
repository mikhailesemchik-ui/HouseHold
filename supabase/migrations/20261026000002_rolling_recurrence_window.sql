-- Rolling occurrence window for daily/weekly recurring tasks.
--
-- Before: _generate_occurrences_for_task generated 30 daily / 12 weekly slots
-- counted from tasks.due_at only, so a recurring task ran dry after its first
-- window and refresh_my_recurring_occurrences() (same generator, same due_at)
-- could never extend it.
--
-- Now the schedule lattice stays anchored to tasks.due_at (slot k = due_at +
-- k * step, so weekday and time of day are preserved) and the generated set is
-- the union of:
--   * the original window, slots 0 .. count-1 (unchanged creation/edit
--     behavior, including overdue slots of a task created with a past start);
--   * the rolling window, count slots starting at the first slot at or after
--     now(). A long gap between refreshes therefore skips the slots nobody
--     saw instead of backfilling them.
-- Both generator and the conversion cleanup in generate_task_occurrences use
-- the one helper below, so they cannot drift apart.
--
-- Existing rows are never deleted by a routine refresh: only future incomplete
-- rows outside the window are removed (as before). Completed rows and past
-- incomplete rows are untouched. Inserts are ON CONFLICT-safe, so concurrent
-- refreshes cannot create duplicates.
--
-- Slot arithmetic is timestamptz + interval in the session time zone, exactly
-- as before (Supabase sessions run in UTC).

create or replace function _recurring_slots(p_due_at timestamptz, p_type text)
returns setof timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  v_step  interval;
  v_count int;
  v_first int;
begin
  if p_type = 'daily' then
    v_step  := interval '1 day';
    v_count := 30;
  elsif p_type = 'weekly' then
    v_step  := interval '1 week';
    v_count := 12;
  else
    raise exception 'Unsupported recurrence_type: %', p_type;
  end if;

  -- Index of the first slot at or after now(). The epoch estimate is
  -- corrected against the real interval arithmetic so DST zones stay exact.
  v_first := greatest(
    0,
    floor(extract(epoch from now() - p_due_at) / extract(epoch from v_step))::int - 1
  );
  while v_first > 0 and p_due_at + v_step * (v_first - 1) >= now() loop
    v_first := v_first - 1;
  end loop;
  while p_due_at + v_step * v_first < now() loop
    v_first := v_first + 1;
  end loop;

  return query
    select p_due_at + v_step * g from generate_series(0, v_count - 1) g
    union
    select p_due_at + v_step * g from generate_series(v_first, v_first + v_count - 1) g;
end;
$$;

revoke all on function _recurring_slots(timestamptz, text) from public, anon, authenticated;
grant execute on function _recurring_slots(timestamptz, text) to service_role;

create or replace function _generate_occurrences_for_task(task_row tasks)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if task_row.recurrence_type = 'none' then
    -- Remove incomplete occurrences at any time other than the new due_at.
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at <> task_row.due_at;

    -- Insert or refresh the single occurrence.
    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    values (task_row.id, task_row.household_id, task_row.due_at, task_row.assigned_to)
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null;

  elsif task_row.recurrence_type in ('daily', 'weekly') then
    -- Remove future incomplete occurrences that fall outside the window.
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at > now()
      and scheduled_at not in (
        select _recurring_slots(task_row.due_at, task_row.recurrence_type)
      );

    -- Insert or refresh all scheduled slots.
    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    select task_row.id, task_row.household_id, s, task_row.assigned_to
    from _recurring_slots(task_row.due_at, task_row.recurrence_type) s
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null;
  end if;
end;
$$;

-- Same as 20261026000001, except the conversion cleanup now reads the window
-- from _recurring_slots instead of mirroring fixed 30/12 counts.
create or replace function generate_task_occurrences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.due_at is not null then
      perform _generate_occurrences_for_task(new);
    end if;

  elsif tg_op = 'UPDATE' then
    if new.due_at          is distinct from old.due_at
    or new.recurrence_type is distinct from old.recurrence_type
    or new.assigned_to     is distinct from old.assigned_to then
      if new.due_at is null then
        delete from task_occurrences
        where task_id      = new.id
          and completed_at is null;
      else
        if old.recurrence_type = 'none'
           and new.recurrence_type in ('daily', 'weekly')
           and old.due_at is not null
           and old.due_at is distinct from new.due_at then
          delete from task_occurrences
          where task_id      = new.id
            and completed_at is null
            and scheduled_at = old.due_at
            and scheduled_at not in (
              select _recurring_slots(new.due_at, new.recurrence_type)
            );
        end if;

        perform _generate_occurrences_for_task(new);
      end if;
    end if;
  end if;

  return null;
end;
$$;
