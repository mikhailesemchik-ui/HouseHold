-- Reusable trigger function to stamp updated_at on every row modification.
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create table tasks (
  id           uuid        primary key default gen_random_uuid(),
  household_id uuid        not null references households(id) on delete cascade,
  title        text        not null,
  description  text        null,
  assigned_to  uuid        null references profiles(user_id),
  created_by   uuid        not null references profiles(user_id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  completed_at timestamptz null,
  completed_by uuid        null references profiles(user_id),

  -- Title may not be blank after trimming whitespace.
  constraint tasks_title_not_empty
    check (trim(title) <> ''),

  -- completed_at and completed_by must both be null or both be non-null.
  constraint tasks_completion_consistency
    check ((completed_at is null) = (completed_by is null))
);

-- Listing tasks for a household ordered by creation time.
create index tasks_household_created on tasks (household_id, created_at);

-- Assignee lookups (sparse index since most tasks may be unassigned).
create index tasks_assigned on tasks (assigned_to) where assigned_to is not null;

-- Fast filter for incomplete tasks per household.
create index tasks_incomplete on tasks (household_id) where completed_at is null;

-- Stamp updated_at automatically.
create trigger tasks_updated_at
  before update on tasks
  for each row execute function set_updated_at();

-- When a task transitions from incomplete to complete, the completing user must
-- set themselves as completed_by. This cannot be expressed cleanly in RLS WITH
-- CHECK without OLD row access, so a BEFORE UPDATE trigger enforces it instead.
create or replace function enforce_task_completion_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.completed_at is null and new.completed_at is not null then
    if new.completed_by is distinct from auth.uid() then
      raise exception 'completed_by must be the authenticated user when completing a task'
        using errcode = 'TK001';
    end if;
  end if;
  return new;
end;
$$;

create trigger tasks_enforce_completion_identity
  before update on tasks
  for each row execute function enforce_task_completion_identity();

alter table tasks enable row level security;

-- Active household members may read tasks.
create policy "tasks_select_active_member"
  on tasks for select
  to authenticated
  using (is_active_household_member(household_id));

-- Active members may insert tasks for their household.
-- created_by must be the authenticated user.
-- assigned_to, when supplied, must be an active member of the same household.
create policy "tasks_insert_active_member"
  on tasks for insert
  to authenticated
  with check (
    is_active_household_member(household_id)
    and created_by = auth.uid()
    and (
      assigned_to is null
      or exists (
        select 1 from household_members hm
        where hm.household_id = tasks.household_id
          and hm.user_id      = tasks.assigned_to
          and hm.status       = 'active'
      )
    )
  );

-- Active members may update tasks in their household.
-- assigned_to, when supplied, must remain an active member.
-- The completion identity constraint is enforced by the trigger above.
create policy "tasks_update_active_member"
  on tasks for update
  to authenticated
  using (is_active_household_member(household_id))
  with check (
    is_active_household_member(household_id)
    and (
      assigned_to is null
      or exists (
        select 1 from household_members hm
        where hm.household_id = tasks.household_id
          and hm.user_id      = tasks.assigned_to
          and hm.status       = 'active'
      )
    )
  );

-- Active members may delete tasks in their household.
create policy "tasks_delete_active_member"
  on tasks for delete
  to authenticated
  using (is_active_household_member(household_id));

-- Include in Supabase Realtime so clients receive INSERT/UPDATE/DELETE events.
alter publication supabase_realtime add table tasks;
