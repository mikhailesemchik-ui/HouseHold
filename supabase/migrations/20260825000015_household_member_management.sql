-- Household member management RPCs.
-- Historical membership, task events, expenses, and completed occurrences are preserved.

-- ---------------------------------------------------------------------------
-- remove_household_member
--
-- Active household owners may remove another active regular member. Removal is
-- treated the same as leaving: the membership row is retained, the current
-- membership period is closed, and future incomplete task assignments are
-- cleared without touching completed history.
-- ---------------------------------------------------------------------------
create or replace function remove_household_member(
  p_household_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid        := auth.uid();
  v_left_at     timestamptz := now();
  v_target_role text;
begin
  if v_caller_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if v_caller_id = p_user_id then
    raise exception 'Owners cannot remove themselves with this action'
      using errcode = 'HO007';
  end if;

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = v_caller_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only active household owners may remove members'
      using errcode = 'HO002';
  end if;

  select role into v_target_role
  from household_members
  where household_id = p_household_id
    and user_id      = p_user_id
    and status       = 'active';

  if not found then
    raise exception 'Target member is not active in this household'
      using errcode = 'HO005';
  end if;

  if v_target_role = 'owner' then
    raise exception 'Removing another owner is not supported'
      using errcode = 'HO008';
  end if;

  update household_members
  set status  = 'left',
      left_at = v_left_at
  where household_id = p_household_id
    and user_id      = p_user_id
    and status       = 'active';

  update household_membership_periods
  set left_at = v_left_at
  where household_id = p_household_id
    and user_id      = p_user_id
    and left_at      is null;

  update tasks
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = p_user_id
    and completed_at is null;

  update task_occurrences
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = p_user_id
    and completed_at is null
    and scheduled_at > v_left_at;
end;
$$;

revoke execute on function remove_household_member(uuid, uuid) from public;
grant  execute on function remove_household_member(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- transfer_household_ownership
--
-- Active owners may hand ownership to one other active regular member. The
-- caller becomes a regular member in the same atomic operation.
-- ---------------------------------------------------------------------------
create or replace function transfer_household_ownership(
  p_household_id uuid,
  p_new_owner_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_new_role  text;
begin
  if v_caller_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if v_caller_id = p_new_owner_id then
    raise exception 'Choose another active member as the new owner'
      using errcode = 'HO009';
  end if;

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = v_caller_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only active household owners may transfer ownership'
      using errcode = 'HO002';
  end if;

  select role into v_new_role
  from household_members
  where household_id = p_household_id
    and user_id      = p_new_owner_id
    and status       = 'active';

  if not found then
    raise exception 'New owner must be an active member of this household'
      using errcode = 'HO005';
  end if;

  if v_new_role <> 'member' then
    raise exception 'New owner must currently be a regular member'
      using errcode = 'HO010';
  end if;

  update household_members
  set role = case
    when user_id = v_caller_id then 'member'
    when user_id = p_new_owner_id then 'owner'
    else role
  end
  where household_id = p_household_id
    and user_id in (v_caller_id, p_new_owner_id)
    and status = 'active';

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Household must retain an active owner'
      using errcode = 'HO006';
  end if;
end;
$$;

revoke execute on function transfer_household_ownership(uuid, uuid) from public;
grant  execute on function transfer_household_ownership(uuid, uuid) to authenticated;
