-- TE-001: editing a past-due non-recurring task to a new due_at left the old
-- incomplete occurrence behind, because stale occurrences were only removed
-- when scheduled_at > now(). A non-recurring task has exactly one current
-- occurrence, so any incomplete occurrence not at the new due_at is stale,
-- past or future. Completed occurrences are history and are never touched.
-- The recurring branch is unchanged.

create or replace function _generate_occurrences_for_task(task_row tasks)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_interval interval;
  v_count    int;
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
    if task_row.recurrence_type = 'daily' then
      v_interval := interval '1 day';
      v_count    := 30;
    else
      v_interval := interval '1 week';
      v_count    := 12;
    end if;

    -- Remove future incomplete occurrences that fall outside the new window.
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at > now()
      and scheduled_at not in (
        select task_row.due_at + (v_interval * g)
        from generate_series(0, v_count - 1) g
      );

    -- Insert or refresh all scheduled slots.
    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    select
      task_row.id,
      task_row.household_id,
      task_row.due_at + (v_interval * g),
      task_row.assigned_to
    from generate_series(0, v_count - 1) g
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null;
  end if;
end;
$$;

-- due_at cleared: the task is no longer scheduled, so no incomplete
-- occurrence may remain, including one that is already past.
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
        perform _generate_occurrences_for_task(new);
      end if;
    end if;
  end if;

  return null;
end;
$$;
