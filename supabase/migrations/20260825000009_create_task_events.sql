-- Allow active household members to read each other's profiles.
-- Required for resolving actor display names in task activity history.
-- The previous profiles_select_own policy only allowed reading one's own profile,
-- which prevented JOIN-based display name resolution across household members.
create policy "profiles_select_household_peer"
  on profiles for select
  to authenticated
  using (
    auth.uid() = user_id
    or exists (
      select 1 from household_members hm
      where hm.user_id                   = profiles.user_id
        and is_active_household_member(hm.household_id)
    )
  );

-- Task event log. Rows are written exclusively by server-side triggers;
-- clients have no INSERT/UPDATE/DELETE access.
--
-- task_id: set null when the referenced task is deleted (preserve event history).
-- actor_user_id: set null when the referenced profile is deleted (preserve history).
-- assigned_to: set null when the referenced profile is deleted (preserve history).
-- household_id: cascades on household deletion (all activity belongs to the household).
--
-- task_title is snapshotted so history remains readable after renames and deletions.
create table task_events (
  id            uuid        primary key default gen_random_uuid(),
  task_id       uuid        null references tasks(id)    on delete set null,
  household_id  uuid        not null references households(id) on delete cascade,
  actor_user_id uuid        null references profiles(user_id) on delete set null,
  event_type    text        not null,
  task_title    text        not null,
  assigned_to   uuid        null references profiles(user_id) on delete set null,
  occurred_at   timestamptz not null default now(),

  constraint task_events_event_type_check
    check (event_type in ('created', 'updated', 'completed', 'reopened', 'deleted'))
);

-- Household activity feed: list recent events for a household in time order.
create index task_events_household_occurred
  on task_events (household_id, occurred_at desc);

-- Task-specific history: find all events for a particular task.
create index task_events_task_id
  on task_events (task_id)
  where task_id is not null;

-- Actor statistics: count/filter events by user and type.
create index task_events_actor
  on task_events (actor_user_id, event_type)
  where actor_user_id is not null;

alter table task_events enable row level security;

-- Active household members may read events for their household.
create policy "task_events_select_active_member"
  on task_events for select
  to authenticated
  using (is_active_household_member(household_id));

-- No INSERT/UPDATE/DELETE policies for clients.
-- All writes are performed by the trigger below (security definer context).

-- ---------------------------------------------------------------------------
-- record_task_events
--
-- Fires AFTER INSERT, UPDATE, or DELETE on tasks and writes an immutable event
-- row. Uses security definer so it can write to task_events regardless of the
-- client's RLS context, and reads auth.uid() for the authenticated actor.
--
-- INSERT  → 'created'
-- UPDATE  → 'completed', 'reopened', or 'updated' (never both completion and
--            updated for the same statement; ignores updated_at-only changes)
-- DELETE  → 'deleted'  (task_id is null because the task is already gone)
-- ---------------------------------------------------------------------------
create or replace function record_task_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    insert into task_events
      (task_id, household_id, actor_user_id, event_type, task_title, assigned_to)
    values
      (new.id, new.household_id, v_actor, 'created', new.title, new.assigned_to);

  elsif tg_op = 'UPDATE' then
    if old.completed_at is null and new.completed_at is not null then
      -- Task just completed.
      insert into task_events
        (task_id, household_id, actor_user_id, event_type, task_title, assigned_to)
      values
        (new.id, new.household_id, v_actor, 'completed', new.title, new.assigned_to);

    elsif old.completed_at is not null and new.completed_at is null then
      -- Task reopened.
      insert into task_events
        (task_id, household_id, actor_user_id, event_type, task_title, assigned_to)
      values
        (new.id, new.household_id, v_actor, 'reopened', new.title, new.assigned_to);

    elsif old.title       is distinct from new.title
       or old.description is distinct from new.description
       or old.assigned_to is distinct from new.assigned_to then
      -- Meaningful user edit — but not a completion toggle.
      -- Only one 'updated' event per UPDATE statement regardless of how many
      -- fields changed simultaneously.
      insert into task_events
        (task_id, household_id, actor_user_id, event_type, task_title, assigned_to)
      values
        (new.id, new.household_id, v_actor, 'updated', new.title, new.assigned_to);
    end if;
    -- No event when only updated_at changed (the set_updated_at trigger fires
    -- as BEFORE UPDATE, so by AFTER UPDATE time updated_at always differs from
    -- old.updated_at; we correctly ignore it by not checking that column).

  elsif tg_op = 'DELETE' then
    -- The task row is already deleted at AFTER DELETE time; task_id must be null
    -- because the referenced row no longer exists.
    insert into task_events
      (task_id, household_id, actor_user_id, event_type, task_title, assigned_to)
    values
      (null, old.household_id, v_actor, 'deleted', old.title, old.assigned_to);
  end if;

  return null; -- AFTER trigger return value is ignored.
end;
$$;

create trigger tasks_record_events
  after insert or update or delete on tasks
  for each row execute function record_task_events();
