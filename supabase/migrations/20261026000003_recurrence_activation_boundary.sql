-- No artificial overdue backfill when a recurring schedule is activated.
--
-- Before: generating a recurring task always created slots 0..count-1 counted
-- from due_at, so a task created with a start date in the past (or converted
-- from a one-off with one) got up to 30 instantly overdue rows, and any later
-- refresh would have recreated slots skipped at creation.
--
-- tasks.recurrence_started_at is the durable activation instant: the server
-- clock when a recurring schedule begins. Slots earlier than it are never
-- generated, on creation or on any later refresh, so the exclusion is stable.
-- It is set only by the BEFORE trigger below (client values are overwritten):
--   * INSERT of a recurring task;
--   * a one-off becoming daily/weekly;
--   * a recurring task whose due_at or recurrence_type changes (a replacement
--     schedule with a new slot lattice).
-- It is kept on every other update (reassignment, title edit, ...) and on
-- refresh, which never touches the tasks row, and cleared for one-off tasks.
--
-- Existing rows keep NULL = no boundary, i.e. the previous behavior. Nothing
-- is deleted or rewritten: completed and overdue occurrences that already
-- exist are never touched by this migration or by refresh.
--
-- Slot arithmetic and time zone semantics are unchanged (session time zone,
-- UTC on Supabase).

alter table tasks add column recurrence_started_at timestamptz null;

create or replace function set_recurrence_started_at()
returns trigger
language plpgsql
as $$
begin
  if new.recurrence_type = 'none' then
    new.recurrence_started_at := null;
  elsif tg_op = 'INSERT' then
    new.recurrence_started_at := now();
  elsif old.recurrence_type = 'none'
     or new.recurrence_type is distinct from old.recurrence_type
     or new.due_at          is distinct from old.due_at then
    new.recurrence_started_at := now();
  else
    new.recurrence_started_at := old.recurrence_started_at;
  end if;
  return new;
end;
$$;

create trigger tasks_set_recurrence_started_at
  before insert or update on tasks
  for each row execute function set_recurrence_started_at();

-- Slots of the schedule, never earlier than p_from (NULL = no boundary).
drop function _recurring_slots(timestamptz, text);

create or replace function _recurring_slots(
  p_due_at timestamptz,
  p_type   text,
  p_from   timestamptz
)
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
    select s
    from (
      select p_due_at + v_step * g as s from generate_series(0, v_count - 1) g
      union
      select p_due_at + v_step * g from generate_series(v_first, v_first + v_count - 1) g
    ) slots
    where p_from is null or s >= p_from;
end;
$$;

revoke all on function _recurring_slots(timestamptz, text, timestamptz)
  from public, anon, authenticated;
grant execute on function _recurring_slots(timestamptz, text, timestamptz) to service_role;

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
        select _recurring_slots(
          task_row.due_at, task_row.recurrence_type, task_row.recurrence_started_at
        )
      );

    -- Insert or refresh all eligible slots.
    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    select task_row.id, task_row.household_id, s, task_row.assigned_to
    from _recurring_slots(
      task_row.due_at, task_row.recurrence_type, task_row.recurrence_started_at
    ) s
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null;
  end if;
end;
$$;

-- Same as 20261026000002 except the conversion cleanup honors the activation
-- boundary: the old one-off occurrence is stale unless it is an eligible slot
-- of the new schedule.
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
              select _recurring_slots(
                new.due_at, new.recurrence_type, new.recurrence_started_at
              )
            );
        end if;

        perform _generate_occurrences_for_task(new);
      end if;
    end if;
  end if;

  return null;
end;
$$;
