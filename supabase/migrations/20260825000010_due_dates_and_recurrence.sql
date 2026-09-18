-- 1. Extend tasks with scheduling fields.
alter table tasks
  add column due_at          timestamptz null,
  add column recurrence_type text        not null default 'none';

alter table tasks
  add constraint tasks_recurrence_type_check
    check (recurrence_type in ('none', 'daily', 'weekly')),
  add constraint tasks_recurring_requires_due_at
    check (recurrence_type = 'none' or due_at is not null);

-- 2. Task occurrence log.
--    Each row represents one scheduled instance of a task.
--    Clients may not INSERT/DELETE directly; rows are managed server-side.
--    Clients may UPDATE only via the complete_occurrence / reopen_occurrence RPCs.
create table task_occurrences (
  id           uuid        primary key default gen_random_uuid(),
  task_id      uuid        not null references tasks(id)       on delete cascade,
  household_id uuid        not null references households(id)  on delete cascade,
  scheduled_at timestamptz not null,
  assigned_to  uuid        null     references profiles(user_id) on delete set null,
  completed_at timestamptz null,
  completed_by uuid        null     references profiles(user_id) on delete set null,
  created_at   timestamptz not null default now(),

  constraint task_occurrences_completion_consistency
    check ((completed_at is null) = (completed_by is null)),

  -- One occurrence per task per point in time.
  constraint task_occurrences_unique_schedule
    unique (task_id, scheduled_at)
);

-- Household upcoming incomplete occurrences (feed / Today view).
create index task_occurrences_household_upcoming
  on task_occurrences (household_id, scheduled_at)
  where completed_at is null;

-- Assignee's upcoming incomplete occurrences (cross-household My Tasks).
create index task_occurrences_assigned_upcoming
  on task_occurrences (assigned_to, scheduled_at)
  where completed_at is null and assigned_to is not null;

-- Full occurrence history for a task.
create index task_occurrences_task_history
  on task_occurrences (task_id, scheduled_at);

alter table task_occurrences enable row level security;

create policy "task_occurrences_select_active_member"
  on task_occurrences for select
  to authenticated
  using (is_active_household_member(household_id));

-- No client INSERT/UPDATE/DELETE policies.
-- All writes go through security-definer functions below.

-- 3. Extend task_events so occurrence-level completions are traceable.
alter table task_events
  add column occurrence_id uuid null;

alter table task_events
  add constraint task_events_occurrence_fk
    foreign key (occurrence_id) references task_occurrences(id) on delete set null;

-- 4. Realtime
alter publication supabase_realtime add table task_occurrences;

-- ---------------------------------------------------------------------------
-- _generate_occurrences_for_task
--
-- Deterministic, idempotent, bounded generation.
--
-- none  : one occurrence at due_at.
-- daily : 30 occurrences starting at due_at, one per day.
-- weekly: 12 occurrences starting at due_at, one per week.
--
-- On regeneration (due_at / recurrence / assignee changed):
--   * Future incomplete occurrences outside the new schedule are removed.
--   * Past and completed occurrences are never touched.
--   * Assignee is updated on future incomplete occurrences in the new schedule.
--   * Duplicate-safe via ON CONFLICT (task_id, scheduled_at).
-- ---------------------------------------------------------------------------
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
    -- Remove future incomplete occurrences at any time other than the new due_at.
    delete from task_occurrences
    where task_id      = task_row.id
      and completed_at is null
      and scheduled_at > now()
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

-- ---------------------------------------------------------------------------
-- generate_task_occurrences  (AFTER INSERT OR UPDATE trigger on tasks)
-- ---------------------------------------------------------------------------
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
        -- due_at cleared: clean up future incomplete occurrences only.
        delete from task_occurrences
        where task_id      = new.id
          and completed_at is null
          and scheduled_at > now();
      else
        perform _generate_occurrences_for_task(new);
      end if;
    end if;
  end if;

  return null;
end;
$$;

create trigger tasks_generate_occurrences
  after insert or update on tasks
  for each row execute function generate_task_occurrences();

-- ---------------------------------------------------------------------------
-- complete_occurrence  (callable by authenticated clients via .rpc())
-- Enforces completed_by = auth.uid(). Idempotent.
-- ---------------------------------------------------------------------------
create or replace function complete_occurrence(p_occurrence_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_occ  record;
  v_task record;
  v_user uuid := auth.uid();
begin
  select * into v_occ from task_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'Occurrence not found' using errcode = 'TK010';
  end if;

  if not is_active_household_member(v_occ.household_id) then
    raise exception 'Permission denied' using errcode = 'TK011';
  end if;

  if v_occ.completed_at is not null then
    return; -- already completed
  end if;

  update task_occurrences
     set completed_at = now(),
         completed_by = v_user
   where id = p_occurrence_id;

  -- Record in history (task_title snapshot from parent task).
  select * into v_task from tasks where id = v_occ.task_id;
  if found then
    insert into task_events
      (task_id, household_id, actor_user_id, event_type, task_title, assigned_to, occurrence_id)
    values
      (v_occ.task_id, v_occ.household_id, v_user, 'completed',
       v_task.title, v_occ.assigned_to, p_occurrence_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- reopen_occurrence  (callable by authenticated clients via .rpc())
-- Clears completion fields. Idempotent.
-- ---------------------------------------------------------------------------
create or replace function reopen_occurrence(p_occurrence_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_occ  record;
  v_task record;
  v_user uuid := auth.uid();
begin
  select * into v_occ from task_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'Occurrence not found' using errcode = 'TK010';
  end if;

  if not is_active_household_member(v_occ.household_id) then
    raise exception 'Permission denied' using errcode = 'TK011';
  end if;

  if v_occ.completed_at is null then
    return; -- already open
  end if;

  update task_occurrences
     set completed_at = null,
         completed_by = null
   where id = p_occurrence_id;

  select * into v_task from tasks where id = v_occ.task_id;
  if found then
    insert into task_events
      (task_id, household_id, actor_user_id, event_type, task_title, assigned_to, occurrence_id)
    values
      (v_occ.task_id, v_occ.household_id, v_user, 'reopened',
       v_task.title, v_occ.assigned_to, p_occurrence_id);
  end if;
end;
$$;
