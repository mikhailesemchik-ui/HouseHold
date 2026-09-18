-- ============================================================
-- Extend household_events with membership event types.
-- Logs: member_joined, member_left, member_removed,
--       ownership_transferred.
-- ============================================================

alter table household_events
  drop constraint household_events_event_type_check,
  add  constraint household_events_event_type_check check (
    event_type in (
      'task_created', 'task_completed', 'task_reopened', 'task_deleted',
      'shopping_item_added', 'shopping_item_completed',
      'expense_created', 'expense_deleted',
      'member_joined', 'member_left', 'member_removed',
      'ownership_transferred'
    )
  );

alter table household_events
  drop constraint household_events_entity_type_check,
  add  constraint household_events_entity_type_check check (
    entity_type in ('task', 'shopping_item', 'expense', 'member')
  );

-- ============================================================
-- Trigger: household_members → household_events
--
-- INSERT with status='active'  → member_joined
-- UPDATE active→left by self   → member_left
-- UPDATE active→left by owner  → member_removed  (title = removed member name)
-- UPDATE member→owner role     → ownership_transferred (title = new owner name)
-- ============================================================
create or replace function record_household_event_from_member()
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
  if tg_op = 'INSERT' and new.status = 'active' then
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id
    ) values (
      new.household_id, v_actor, v_actor_name,
      'member_joined', 'member', new.user_id
    );

  elsif tg_op = 'UPDATE'
    and old.status = 'active'
    and new.status = 'left'
  then
    v_event_type := case
      when v_actor = new.user_id then 'member_left'
      else 'member_removed'
    end;
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      v_event_type, 'member', new.user_id,
      _resolve_actor_name(new.user_id)
    );

  elsif tg_op = 'UPDATE'
    and old.role = 'member'
    and new.role = 'owner'
    and new.status = 'active'
  then
    -- Only log on the row being promoted (avoids double-logging the transfer).
    insert into household_events (
      household_id, actor_user_id, actor_display_name,
      event_type, entity_type, entity_id, title_snapshot
    ) values (
      new.household_id, v_actor, v_actor_name,
      'ownership_transferred', 'member', new.user_id,
      _resolve_actor_name(new.user_id)
    );
  end if;

  return null;
end;
$$;

create trigger household_members_record_household_events
  after insert or update on household_members
  for each row execute function record_household_event_from_member();
