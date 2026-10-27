-- Audit finding F8: invitations must stop working once they should no longer
-- be valid.
--
-- * remove_household_member now revokes every active invite of the household in
--   the same transaction, so a removed member cannot rejoin with a code that
--   was issued before the removal. The owner creates a fresh code afterwards.
--   Voluntary leave_household is deliberately unchanged.
-- * create_household_invite sets expires_at = now() + 7 days explicitly, and a
--   BEFORE INSERT trigger fills the same default for any other insert path, so
--   the database never stores a non-expiring invite. join_household_by_invite
--   already rejects expired and revoked codes; it now also takes a FOR SHARE
--   lock on the invite row so that it cannot race past a concurrent removal.
-- * Transition: active invites that have no expiry get now() + 7 days from
--   this migration. Already revoked or expired invites and invites with an
--   explicit expiry are not touched.
-- RPC signatures, return types, grants and SECURITY DEFINER are unchanged.
-- Not addressed here: rate limiting of failed code attempts (see the F8 report).

update household_invites
set expires_at = now() + interval '7 days'
where expires_at is null
  and revoked_at is null;

create or replace function household_invites_default_expiry()
returns trigger
language plpgsql
as $$
begin
  new.expires_at := coalesce(new.expires_at, now() + interval '7 days');
  return new;
end;
$$;

create trigger household_invites_default_expiry
  before insert on household_invites
  for each row execute function household_invites_default_expiry();

create or replace function create_household_invite(p_household_id uuid)
returns household_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_code    text;
  v_invite  household_invites;
  v_tries   int := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id      = v_user_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only household owners may create invites' using errcode = 'HO002';
  end if;

  loop
    v_code := generate_invite_code();
    begin
      insert into household_invites (household_id, code, created_by, expires_at)
      values (p_household_id, v_code, v_user_id, now() + interval '7 days')
      returning * into v_invite;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries >= 10 then
        raise exception 'Failed to generate a unique invite code after 10 attempts';
      end if;
    end;
  end loop;

  return v_invite;
end;
$$;

create or replace function join_household_by_invite(p_code text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid        := auth.uid();
  v_code        text        := upper(trim(p_code));
  v_invite      household_invites;
  v_household   households;
  v_joined_name text;
  v_recipient   uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  select * into v_invite
  from household_invites
  where code       = v_code
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  for share;

  if not found then
    raise exception 'Invite code is invalid, expired, or revoked'
      using errcode = 'HO004';
  end if;

  select * into v_household
  from households
  where id = v_invite.household_id;

  if exists (
    select 1 from household_members
    where household_id = v_household.id
      and user_id      = v_user_id
      and status       = 'active'
  ) then
    return v_household;
  end if;

  insert into household_members (household_id, user_id, role, status, joined_at, left_at)
  values (v_household.id, v_user_id, 'member', 'active', now(), null)
  on conflict (household_id, user_id) do update
    set role      = 'member',
        status    = 'active',
        joined_at = now(),
        left_at   = null;

  insert into household_membership_periods (household_id, user_id, joined_at)
  values (v_household.id, v_user_id, now())
  on conflict (household_id, user_id) where left_at is null do nothing;

  v_joined_name := coalesce(_push_profile_name(v_user_id), 'Someone');
  for v_recipient in
    select user_id
    from household_members
    where household_id = v_household.id
      and user_id     != v_user_id
      and status       = 'active'
  loop
    perform _enqueue_notification(
      v_recipient,
      v_household.id,
      'household_joined',
      v_joined_name || ' joined ' || v_household.name,
      v_joined_name || ' joined ' || v_household.name,
      jsonb_build_object(
        'type', 'household_joined',
        'householdId', v_household.id
      )
    );
  end loop;

  return v_household;
end;
$$;

create or replace function remove_household_member(p_household_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid        := auth.uid();
  v_left_at     timestamptz := now();
  v_target_role text;
  v_house_name  text;
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

  -- Revoke first: join_household_by_invite locks the invite row and then the
  -- membership row, so taking the invite lock first keeps the lock order
  -- identical and rules out a deadlock or a join racing past the removal.
  update household_invites
  set revoked_at = v_left_at
  where household_id = p_household_id
    and revoked_at is null
    and (expires_at is null or expires_at > v_left_at);

  select name into v_house_name
  from households
  where id = p_household_id;

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

  perform _enqueue_notification(
    p_user_id,
    p_household_id,
    'member_removed',
    'You were removed from ' || coalesce(v_house_name, 'a home'),
    'You were removed from ' || coalesce(v_house_name, 'a home'),
    jsonb_build_object(
      'type', 'member_removed',
      'householdId', p_household_id
    )
  );
end;
$$;

