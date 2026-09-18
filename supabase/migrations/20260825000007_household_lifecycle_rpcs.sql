-- Prevent more than one open membership period per user/household.
-- Only partial (left_at IS NULL) rows are constrained; closed periods are unlimited.
create unique index household_membership_periods_one_open
  on household_membership_periods (household_id, user_id)
  where left_at is null;

-- ---------------------------------------------------------------------------
-- join_household_by_invite
--
-- Atomically validates an invite code, upserts household_members, and opens a
-- new membership period. Returns the joined household.
-- The caller supplies only the raw invite code; all other state derives from
-- auth.uid() and the database.
-- ---------------------------------------------------------------------------
create or replace function join_household_by_invite(p_code text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id   uuid        := auth.uid();
  v_code      text        := upper(trim(p_code));
  v_invite    household_invites;
  v_household households;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  -- Validate the invite: must exist, not revoked, not expired.
  select * into v_invite
  from household_invites
  where code       = v_code
    and revoked_at is null
    and (expires_at is null or expires_at > now());

  if not found then
    raise exception 'Invite code is invalid, expired, or revoked'
      using errcode = 'HO004';
  end if;

  -- Fetch the household the invite belongs to.
  select * into v_household
  from households
  where id = v_invite.household_id;

  -- Idempotent: if the caller is already an active member, return without changes.
  if exists (
    select 1 from household_members
    where household_id = v_household.id
      and user_id      = v_user_id
      and status       = 'active'
  ) then
    return v_household;
  end if;

  -- Upsert membership (covers first join and rejoin after leaving).
  insert into household_members (household_id, user_id, role, status, joined_at, left_at)
  values (v_household.id, v_user_id, 'member', 'active', now(), null)
  on conflict (household_id, user_id) do update
    set role      = 'member',
        status    = 'active',
        joined_at = now(),
        left_at   = null;

  -- Open a new membership period.
  -- The partial unique index prevents duplicate open periods; DO NOTHING handles
  -- an unlikely concurrent race where a period was already opened.
  insert into household_membership_periods (household_id, user_id, joined_at)
  values (v_household.id, v_user_id, now())
  on conflict (household_id, user_id) where left_at is null do nothing;

  return v_household;
end;
$$;

revoke execute on function join_household_by_invite(text) from public;
grant  execute on function join_household_by_invite(text) to authenticated;

-- ---------------------------------------------------------------------------
-- leave_household
--
-- Marks the caller's membership as 'left' and closes the open membership
-- period. Prevents the only active owner from leaving.
-- ---------------------------------------------------------------------------
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

  -- Confirm the caller has an active membership and capture their role.
  select role into v_role
  from household_members
  where household_id = p_household_id
    and user_id      = v_user_id
    and status       = 'active';

  if not found then
    raise exception 'No active membership in this household'
      using errcode = 'HO005';
  end if;

  -- Owners may only leave when at least one other active owner remains.
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

  -- Mark membership as left.
  update household_members
  set status  = 'left',
      left_at = v_left_at
  where household_id = p_household_id
    and user_id      = v_user_id;

  -- Close the current open membership period with the same timestamp.
  update household_membership_periods
  set left_at = v_left_at
  where household_id = p_household_id
    and user_id      = v_user_id
    and left_at      is null;
end;
$$;

revoke execute on function leave_household(uuid) from public;
grant  execute on function leave_household(uuid) to authenticated;
