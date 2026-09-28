-- MU-003: shopping item reopen (completed -> incomplete) never emitted a
-- household_events row, unlike tasks (task_completed/task_reopened both
-- exist). Nothing signals clients to refetch the dashboard summary after a
-- reopen, so it stays stale until an unrelated event happens to refresh it.
-- Add the missing event type and emit it, mirroring the task pattern exactly.

alter table household_events
  drop constraint household_events_event_type_check,
  add  constraint household_events_event_type_check check (
    event_type in (
      'task_created', 'task_completed', 'task_reopened', 'task_deleted',
      'shopping_item_added', 'shopping_item_completed',
      'shopping_item_reopened',
      'expense_created', 'expense_deleted',
      'member_joined', 'member_left', 'member_removed',
      'ownership_transferred'
    )
  );

create or replace function record_household_event_from_shopping()
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
      'shopping_item_added', 'shopping_item', new.id, new.name
    );

  elsif tg_op = 'UPDATE' then
    if old.completed_at is null and new.completed_at is not null then
      v_event_type := 'shopping_item_completed';
    elsif old.completed_at is not null and new.completed_at is null then
      v_event_type := 'shopping_item_reopened';
    else
      return null; -- name/other updates not logged to the unified feed
    end if;
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      v_event_type, 'shopping_item', new.id, new.name
    );
  end if;

  return null;
end;
$$;
