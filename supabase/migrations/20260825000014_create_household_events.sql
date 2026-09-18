-- ============================================================
-- household_events: unified cross-feature activity log
-- Written exclusively by server-side triggers.
-- Clients have no INSERT / UPDATE / DELETE access.
-- ============================================================

create table household_events (
  id                   uuid        primary key default gen_random_uuid(),
  household_id         uuid        not null references households(id) on delete cascade,
  actor_user_id        uuid        null references profiles(user_id) on delete set null,
  actor_display_name   text        not null,       -- snapshotted at event time
  event_type           text        not null,
  entity_type          text        not null,
  entity_id            uuid        null,            -- no FK; entity may be deleted later
  title_snapshot       text        null,
  amount_cents         bigint      null,
  currency             text        null,
  occurred_at          timestamptz not null default now(),

  constraint household_events_event_type_check check (
    event_type in (
      'task_created', 'task_completed', 'task_reopened', 'task_deleted',
      'shopping_item_added', 'shopping_item_completed',
      'expense_created', 'expense_deleted'
    )
  ),
  constraint household_events_entity_type_check check (
    entity_type in ('task', 'shopping_item', 'expense')
  )
);

create index household_events_household_occurred
  on household_events (household_id, occurred_at desc);

alter table household_events enable row level security;

-- Active household members may read events for their household.
create policy "household_events_select_active_member"
  on household_events for select
  to authenticated
  using (is_active_household_member(household_id));

-- No INSERT / UPDATE / DELETE policies for clients.

-- ============================================================
-- Helper: resolve actor display name at trigger time.
-- Falls back to 'Deleted member' when the profile is missing.
-- ============================================================

create or replace function _resolve_actor_name(p_actor_id uuid)
returns text
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select display_name from profiles where user_id = p_actor_id),
    'Deleted member'
  );
$$;

-- ============================================================
-- Trigger: tasks в†’ household_events
-- Fires alongside the existing record_task_events trigger.
-- Logs: task_created, task_completed, task_reopened, task_deleted.
-- task_updated is intentionally omitted (too noisy for the feed).
-- ============================================================

create or replace function record_household_event_from_task()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text := _resolve_actor_name(auth.uid());
  v_event_type text;
begin
  if tg_op = 'INSERT' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      'task_created', 'task', new.id, new.title
    );

  elsif tg_op = 'UPDATE' then
    if old.completed_at is null and new.completed_at is not null then
      v_event_type := 'task_completed';
    elsif old.completed_at is not null and new.completed_at is null then
      v_event_type := 'task_reopened';
    else
      return null; -- title/assignment updates not logged to the unified feed
    end if;
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      v_event_type, 'task', new.id, new.title
    );

  elsif tg_op = 'DELETE' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      old.household_id, v_actor, v_actor_name,
      'task_deleted', 'task', old.id, old.title
    );
  end if;

  return null;
end;
$$;

create trigger tasks_record_household_events
  after insert or update or delete on tasks
  for each row execute function record_household_event_from_task();

-- ============================================================
-- Trigger: shopping_items в†’ household_events
-- Logs: shopping_item_added, shopping_item_completed.
-- Deletions are not logged (clear-completed is a bulk operation).
-- ============================================================

create or replace function record_household_event_from_shopping()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text := _resolve_actor_name(auth.uid());
begin
  if tg_op = 'INSERT' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      'shopping_item_added', 'shopping_item', new.id, new.name
    );

  elsif tg_op = 'UPDATE' then
    if old.completed_at is null and new.completed_at is not null then
      insert into household_events (
        household_id, actor_user_id, actor_display_name,
        event_type, entity_type, entity_id, title_snapshot
      ) values (
        new.household_id, v_actor, v_actor_name,
        'shopping_item_completed', 'shopping_item', new.id, new.name
      );
    end if;
  end if;

  return null;
end;
$$;

create trigger shopping_items_record_household_events
  after insert or update on shopping_items
  for each row execute function record_household_event_from_shopping();

-- ============================================================
-- Trigger: expenses в†’ household_events
-- Logs: expense_created, expense_deleted.
-- Title updates are not logged.
-- ============================================================

create or replace function record_household_event_from_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text := _resolve_actor_name(auth.uid());
begin
  if tg_op = 'INSERT' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id,
      title_snapshot, amount_cents, currency
    ) values (
      new.household_id, v_actor, v_actor_name,
      'expense_created', 'expense', new.id,
      new.title, new.amount_cents, new.currency
    );

  elsif tg_op = 'DELETE' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id,
      title_snapshot, amount_cents, currency
    ) values (
      old.household_id, v_actor, v_actor_name,
      'expense_deleted', 'expense', old.id,
      old.title, old.amount_cents, old.currency
    );
  end if;

  return null;
end;
$$;

create trigger expenses_record_household_events
  after insert or delete on expenses
  for each row execute function record_household_event_from_expense();

-- ============================================================
-- Trigger: task_occurrences -> household_events
-- Logs due/recurring task completions and reopens as task activity.
-- Existing task_events behavior remains in complete_occurrence/reopen_occurrence.
-- ============================================================

create or replace function record_household_event_from_task_occurrence()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text := _resolve_actor_name(auth.uid());
  v_task_title text;
  v_event_type text;
begin
  if old.completed_at is null and new.completed_at is not null then
    v_event_type := 'task_completed';
  elsif old.completed_at is not null and new.completed_at is null then
    v_event_type := 'task_reopened';
  else
    return null;
  end if;

  select title into v_task_title
  from tasks
  where id = new.task_id;

  insert into household_events (
    household_id, actor_user_id, actor_display_name,
    event_type, entity_type, entity_id, title_snapshot
  ) values (
    new.household_id, v_actor, v_actor_name,
    v_event_type, 'task', new.task_id, coalesce(v_task_title, 'Deleted task')
  );

  return null;
end;
$$;

create trigger task_occurrences_record_household_events
  after update on task_occurrences
  for each row execute function record_household_event_from_task_occurrence();

revoke all on function _resolve_actor_name(uuid) from public;
revoke all on function record_household_event_from_task() from public;
revoke all on function record_household_event_from_task_occurrence() from public;
revoke all on function record_household_event_from_shopping() from public;
revoke all on function record_household_event_from_expense() from public;
-- ============================================================
-- Realtime
-- ============================================================

alter publication supabase_realtime add table household_events;
