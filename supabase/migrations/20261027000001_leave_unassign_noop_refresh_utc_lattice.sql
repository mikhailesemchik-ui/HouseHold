-- Audit remediation F2, F5, F6.
--
-- F2: leave_household did not unassign the leaver's tasks, unlike
--     remove_household_member. Other members then could not rename or complete
--     those tasks (the tasks UPDATE policy requires an active assignee) and
--     refresh kept generating occurrences for the departed member. leave now
--     applies the same policy as removal: incomplete tasks are unassigned and
--     future incomplete occurrences are unassigned. Completed tasks and
--     occurrences, and already-overdue occurrences, are left untouched. The
--     generator additionally never assigns an occurrence to someone who is not
--     an active member of the household, which also heals tasks stranded
--     before this migration the next time they are regenerated.
--
-- F5: the recurrence upsert rewrote every incomplete occurrence in the window
--     on every refresh (new row versions, WAL and Realtime UPDATE events with
--     identical data). The update now runs only when the assignee changes.
--
-- F6: slot arithmetic was timestamptz + interval in the caller's session time
--     zone, so a PostgREST "Prefer: timezone=" header could move the slot
--     lattice (and duplicate completed slots). The recurrence functions now
--     pin timezone to UTC, which is what Supabase sessions use, so existing
--     schedules are unchanged. Local-time scheduling is a separate product
--     decision.

create or replace function leave_household(p_household_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid        := auth.uid();
  v_left_at timestamptz := now();
  v_role    text;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  select role into v_role
  from household_members
  where household_id = p_household_id
    and user_id      = v_user_id
    and status       = 'active';

  if not found then
    raise exception 'No active membership in this household'
      using errcode = 'HO005';
  end if;

  if v_role = 'owner' and not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id     != v_user_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Cannot leave: you are the only active owner. Transfer ownership first.'
      using errcode = 'HO006';
  end if;

  update household_members
  set status  = 'left',
      left_at = v_left_at
  where household_id = p_household_id
    and user_id      = v_user_id;

  update household_membership_periods
  set left_at = v_left_at
  where household_id = p_household_id
    and user_id      = v_user_id
    and left_at      is null;

  -- Same policy as remove_household_member.
  update tasks
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = v_user_id
    and completed_at is null;

  update task_occurrences
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = v_user_id
    and completed_at is null
    and scheduled_at > v_left_at;
end;
$$;

create or replace function _recurring_slots(
  p_due_at timestamptz,
  p_type   text,
  p_from   timestamptz
)
returns setof timestamptz
language plpgsql
stable
set search_path = public
set timezone = 'UTC'
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

create or replace function _generate_occurrences_for_task(task_row tasks)
returns void
language plpgsql
security definer
set search_path = public
set timezone = 'UTC'
as $$
declare
  v_assignee uuid;
begin
  -- Never assign an occurrence to someone who is no longer an active member.
  select hm.user_id into v_assignee
  from household_members hm
  where hm.household_id = task_row.household_id
    and hm.user_id      = task_row.assigned_to
    and hm.status       = 'active';

  if task_row.recurrence_type = 'none' then
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at <> task_row.due_at;

    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    values (task_row.id, task_row.household_id, task_row.due_at, v_assignee)
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null
        and task_occurrences.assigned_to is distinct from excluded.assigned_to;

  elsif task_row.recurrence_type in ('daily', 'weekly') then
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at > now()
      and scheduled_at not in (
        select _recurring_slots(
          task_row.due_at, task_row.recurrence_type, task_row.recurrence_started_at
        )
      );

    insert into task_occurrences (task_id, household_id, scheduled_at, assigned_to)
    select task_row.id, task_row.household_id, s, v_assignee
    from _recurring_slots(
      task_row.due_at, task_row.recurrence_type, task_row.recurrence_started_at
    ) s
    on conflict (task_id, scheduled_at) do update
      set assigned_to = excluded.assigned_to
      where task_occurrences.completed_at is null
        and task_occurrences.assigned_to is distinct from excluded.assigned_to;
  end if;
end;
$$;

create or replace function generate_task_occurrences()
returns trigger
language plpgsql
security definer
set search_path = public
set timezone = 'UTC'
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

create or replace function refresh_my_recurring_occurrences()
returns void
language plpgsql
security definer
set search_path = public
set timezone = 'UTC'
as $$
declare
  task_row tasks%rowtype;
begin
  for task_row in
    select t.*
    from   tasks t
    inner join household_members hm
           on hm.household_id = t.household_id
    where  hm.user_id         = auth.uid()
      and  hm.status          = 'active'
      and  t.recurrence_type <> 'none'
      and  t.completed_at     is null
  loop
    perform _generate_occurrences_for_task(task_row);
  end loop;
end;
$$;
