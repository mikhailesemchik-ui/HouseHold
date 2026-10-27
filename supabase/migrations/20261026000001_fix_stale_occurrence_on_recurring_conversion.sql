-- TE-002: converting a one-off task to a recurring one left the one-off's
-- incomplete occurrence behind whenever it was already past, because the
-- recurring branch of _generate_occurrences_for_task only removes FUTURE
-- incomplete occurrences outside the new window. A past incomplete occurrence
-- of the old one-off schedule is not a missed instance of the new recurring
-- schedule, so it must go.
--
-- The fix lives in the task UPDATE trigger, not in the generator: only the
-- trigger knows the old row, so only it can tell a genuine none -> recurring
-- schedule edit from a routine refresh (refresh_my_recurring_occurrences
-- calls the generator directly and never reaches this branch). Overdue
-- occurrences of an existing recurring schedule are therefore untouched, and
-- editing a recurring task's own start date keeps its current semantics.
--
-- Scope of the new delete, all of which must hold:
--   * the task was non-recurring and is now daily/weekly with a new due_at;
--   * the row is the old one-off's incomplete occurrence (scheduled_at =
--     old.due_at) and is not itself a slot of the new generated window, so a
--     row the generator will keep (and its identity) is never deleted and
--     recreated. This holds whether the new start is earlier or later than
--     the old date: an old occurrence that is not one of the window's slots
--     is stale, past or future, and one that falls beyond the window (more
--     than 30 days / 12 weeks after an earlier new start) is stale too;
--   * completed occurrences are never touched.
-- _generate_occurrences_for_task is unchanged.

create or replace function generate_task_occurrences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_step  interval;
  v_count int;
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
          -- Must mirror the window in _generate_occurrences_for_task
          -- (daily: 30 x 1 day, weekly: 12 x 1 week).
          if new.recurrence_type = 'daily' then
            v_step  := interval '1 day';
            v_count := 30;
          else
            v_step  := interval '1 week';
            v_count := 12;
          end if;

          delete from task_occurrences
          where task_id      = new.id
            and completed_at is null
            and scheduled_at = old.due_at
            and scheduled_at not in (
              select new.due_at + (v_step * g)
              from generate_series(0, v_count - 1) g
            );
        end if;

        perform _generate_occurrences_for_task(new);
      end if;
    end if;
  end if;

  return null;
end;
$$;
