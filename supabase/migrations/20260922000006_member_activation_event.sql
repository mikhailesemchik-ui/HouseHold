-- TWO-001 (iteration 2): rejoining a household is an UPDATE (left -> active)
-- via join_household_by_invite's upsert, not an INSERT, so
-- record_household_event_from_member emitted no household_events row for it.
-- Remote clients rely on that row (realtime) to refresh member-dependent
-- state, and the Activity feed lost the join entirely. Emit the existing
-- member_joined event for that transition. All other branches are unchanged.
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
    and old.status is distinct from 'active'
    and new.status = 'active'
  then
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
