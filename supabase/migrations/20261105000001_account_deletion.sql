-- Audit finding F7B: permanent deletion of a user account.
--
-- Model. A deleted user keeps a non-login "tombstone" profile: the same
-- user_id (needed by every financial row and balance, so two deleted users
-- never collapse into one identity), but no auth.users row, no name, no
-- avatar, no device tokens and no F13 request keys. This is pseudonymisation,
-- not anonymisation: the stable id stays on other members' history.
--
-- State machine on profiles.account_state:
--   active   -> deleting  (begin_account_deletion: atomic database cleanup)
--   deleting -> deleted   (finalize_account_deletion, only after the Auth user
--                          is really gone; service_role only)
-- begin_account_deletion is idempotent, so an interrupted run is simply
-- repeated. The Auth user is removed by a trusted Edge Function after the
-- database step; Auth and PostgreSQL are separate services, so the two steps
-- are NOT one transaction, and the state column is what makes it recoverable.
--
-- Access. Deleting households memberships (left) removes access through every
-- RLS policy and RPC that goes through is_active_household_member(). As a
-- second layer that helper now also requires an active account, creating or
-- joining a household requires an active account, and a client can no longer
-- change its own account_state (column-level UPDATE grant). A JWT that is
-- still valid after the Auth user is deleted therefore reaches nothing.
--
-- Scrubbing live rows and F4 archive snapshots needs two narrowly scoped
-- exceptions (expenses_guard_immutable, financial_archive_immutable). Both
-- require the transaction-local setting app.scrub_user AND that the current
-- role is the owner of begin_account_deletion(), which clients cannot assume;
-- the setting alone is never sufficient. Only names and the 'Deleted member'
-- value may change; amounts, currencies and directions stay immutable.

alter table profiles
  add column account_state text not null default 'active',
  add column deletion_requested_at timestamptz,
  add column deleted_at timestamptz;

alter table profiles
  add constraint profiles_account_state_check
  check (account_state in ('active', 'deleting', 'deleted'));

-- Tombstone profiles outlive their auth.users row, so the cascading FK must go.
alter table profiles drop constraint profiles_user_id_fkey;

-- Clients may edit only their own name and avatar; never account_state.
revoke update on profiles from authenticated;
grant update (display_name, avatar_url) on profiles to authenticated;

create or replace function _account_is_active(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles where user_id = p_user_id and account_state = 'active'
  );
$$;

revoke all on function _account_is_active(uuid) from public, anon;
grant execute on function _account_is_active(uuid) to authenticated;

-- True only inside begin_account_deletion() for exactly this user. Invoker
-- rights on purpose: current_user must be the caller's role, not the owner.
create or replace function _scrubbing_user(p_user_id uuid)
returns boolean
language plpgsql
stable
as $$
begin
  return current_setting('app.scrub_user', true) = p_user_id::text
     and current_user = (
       select pg_get_userbyid(p.proowner)
       from pg_proc p
       where p.oid = 'public.begin_account_deletion()'::regprocedure
     );
end;
$$;

create or replace function is_active_household_member(p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from household_members hm
    join profiles p on p.user_id = hm.user_id
    where hm.household_id = p_household_id
      and hm.user_id      = auth.uid()
      and hm.status       = 'active'
      and p.account_state = 'active'
  );
$$;

drop policy "profiles_update_own" on profiles;
create policy "profiles_update_own"
  on profiles for update
  to authenticated
  using (auth.uid() = user_id and account_state = 'active')
  with check (auth.uid() = user_id and account_state = 'active');

drop policy "device_push_tokens_insert_own" on device_push_tokens;
create policy "device_push_tokens_insert_own"
  on device_push_tokens for insert
  to authenticated
  with check (auth.uid() = user_id and _account_is_active(auth.uid()));

drop policy "device_push_tokens_update_own" on device_push_tokens;
create policy "device_push_tokens_update_own"
  on device_push_tokens for update
  to authenticated
  using (auth.uid() = user_id and _account_is_active(auth.uid()))
  with check (auth.uid() = user_id and _account_is_active(auth.uid()));

-- Archive snapshots stay append-only, except (a) F7A whole-household erasure
-- (DELETE, unchanged) and (b) the name scrub of one deleted user (UPDATE of
-- snapshot / canceled_by_name only, amounts and identities unchanged).
create or replace function financial_archive_immutable()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE'
     and pg_trigger_depth() = 1
     and current_setting('app.erase_household', true) = old.household_id::text
     and current_user = (
       select pg_get_userbyid(p.proowner)
       from pg_proc p
       where p.oid = 'public.delete_household(uuid)'::regprocedure
     ) then
    return old;
  end if;
  if tg_op = 'UPDATE'
     and pg_trigger_depth() = 1
     and current_setting('app.scrub_user', true) <> ''
     and _scrubbing_user(nullif(current_setting('app.scrub_user', true), '')::uuid)
     and new.id           = old.id
     and new.kind         = old.kind
     and new.record_id    = old.record_id
     and new.household_id = old.household_id
     and new.canceled_by  is not distinct from old.canceled_by
     and new.canceled_at  = old.canceled_at
     and new.reason       is not distinct from old.reason
     and (new.snapshot->'amount_cents') is not distinct from (old.snapshot->'amount_cents')
     and (new.snapshot->'currency')     is not distinct from (old.snapshot->'currency')
     and (new.snapshot->'paid_by')      is not distinct from (old.snapshot->'paid_by')
     and (new.snapshot->'from_user_id') is not distinct from (old.snapshot->'from_user_id')
     and (new.snapshot->'to_user_id')   is not distinct from (old.snapshot->'to_user_id') then
    return new;
  end if;
  raise exception 'financial_archive is append-only' using errcode = 'HC003';
end;
$$;

create or replace function create_household(p_name text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name      text := trim(p_name);
  v_user_id   uuid := auth.uid();
  v_household households;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  -- A deleting or deleted account may not create or join households. The
  -- share lock serializes against begin_account_deletion().
  perform 1 from profiles where user_id = v_user_id and account_state = 'active' for share;
  if not found then
    raise exception 'Account is not active' using errcode = 'AD003';
  end if;

  if v_name = '' then
    raise exception 'Household name must not be blank' using errcode = 'HO001';
  end if;

  insert into households (name, created_by)
  values (v_name, v_user_id)
  returning * into v_household;

  -- Upsert so the function is safe if called more than once for the same pair.
  insert into household_members (household_id, user_id, role, status)
  values (v_household.id, v_user_id, 'owner', 'active')
  on conflict (household_id, user_id) do update
    set role = 'owner', status = 'active', left_at = null;

  insert into household_membership_periods (household_id, user_id)
  values (v_household.id, v_user_id);

  return v_household;
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

  -- A deleting or deleted account may not create or join households. The
  -- share lock serializes against begin_account_deletion().
  perform 1 from profiles where user_id = v_user_id and account_state = 'active' for share;
  if not found then
    raise exception 'Account is not active' using errcode = 'AD003';
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

create or replace function expenses_guard_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.household_id <> old.household_id then
    raise exception 'expenses.household_id is immutable'
      using errcode = 'HO024';
  end if;
  if new.amount_cents <> old.amount_cents then
    raise exception 'expenses.amount_cents is immutable'
      using errcode = 'HO025';
  end if;
  if new.currency <> old.currency then
    raise exception 'expenses.currency is immutable'
      using errcode = 'HO026';
  end if;
  if new.paid_by <> old.paid_by then
    raise exception 'expenses.paid_by is immutable'
      using errcode = 'HO027';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'expenses.created_by is immutable'
      using errcode = 'HO028';
  end if;
  if new.paid_by_display_name is distinct from old.paid_by_display_name
     and not (_scrubbing_user(old.paid_by) and new.paid_by_display_name = 'Deleted member') then
    raise exception 'expenses.paid_by_display_name is immutable'
      using errcode = 'HO029';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'expenses.created_at is immutable'
      using errcode = 'HO030';
  end if;
  return new;
end;
$$;

-- Households the caller owns: they must be transferred or deleted (F7A) first.
create or replace function account_deletion_blockers()
returns table (household_id uuid, name text, active_member_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select h.id, h.name,
         (select count(*) from household_members m
          where m.household_id = h.id and m.status = 'active')
  from household_members me
  join households h on h.id = me.household_id
  where me.user_id = auth.uid()
    and me.role    = 'owner'
    and me.status  = 'active'
  order by h.name;
$$;

-- Removes the personal data of one account. Repeatable; called by
-- begin_account_deletion() and again by finalize_account_deletion(), which
-- also catches a write that was already in flight when the first pass ran.
create or replace function _scrub_account_data(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gone constant text := 'Deleted member';
begin
  perform set_config('app.scrub_user', p_user_id::text, true);

  update expenses set paid_by_display_name = v_gone
  where paid_by = p_user_id and paid_by_display_name <> v_gone;
  update expense_participants set display_name = v_gone
  where user_id = p_user_id and display_name <> v_gone;
  update expense_settlements set from_name = v_gone
  where from_user_id = p_user_id and from_name <> v_gone;
  update expense_settlements set to_name = v_gone
  where to_user_id = p_user_id and to_name <> v_gone;
  update household_events set actor_display_name = v_gone
  where actor_user_id = p_user_id and actor_display_name <> v_gone;
  update household_events set title_snapshot = v_gone
  where entity_type = 'member' and entity_id = p_user_id
    and event_type in ('member_removed', 'ownership_transferred')
    and title_snapshot is distinct from v_gone;

  -- F4 archive: replace only this user's names, field by field.
  update financial_archive a
  set canceled_by_name = case when a.canceled_by = p_user_id then v_gone else a.canceled_by_name end,
      snapshot = case a.kind
        when 'expense' then
          jsonb_set(
            case when a.snapshot->>'paid_by' = p_user_id::text
                 then jsonb_set(a.snapshot, '{paid_by_display_name}', to_jsonb(v_gone))
                 else a.snapshot end,
            '{participants}',
            coalesce((
              select jsonb_agg(
                       case when p.value->>'user_id' = p_user_id::text
                            then jsonb_set(p.value, '{display_name}', to_jsonb(v_gone))
                            else p.value end
                       order by p.ordinality)
              from jsonb_array_elements(a.snapshot->'participants')
                   with ordinality as p(value, ordinality)
            ), '[]'::jsonb))
        else
          case when a.snapshot->>'to_user_id' = p_user_id::text
               then jsonb_set(
                      case when a.snapshot->>'from_user_id' = p_user_id::text
                           then jsonb_set(a.snapshot, '{from_name}', to_jsonb(v_gone))
                           else a.snapshot end,
                      '{to_name}', to_jsonb(v_gone))
               when a.snapshot->>'from_user_id' = p_user_id::text
               then jsonb_set(a.snapshot, '{from_name}', to_jsonb(v_gone))
               else a.snapshot end
        end
  where a.canceled_by = p_user_id
     or (a.kind = 'expense'
         and (a.snapshot->>'paid_by' = p_user_id::text
              or a.snapshot->'participants' @> jsonb_build_array(
                   jsonb_build_object('user_id', p_user_id::text))))
     or (a.kind = 'settlement'
         and (a.snapshot->>'from_user_id' = p_user_id::text
              or a.snapshot->>'to_user_id' = p_user_id::text));

  perform set_config('app.scrub_user', '', true);

  delete from financial_operations where actor_id = p_user_id;
  delete from device_push_tokens   where user_id  = p_user_id;
  delete from notification_outbox  where recipient_user_id = p_user_id;

  update profiles
  set display_name = v_gone,
      avatar_url   = null,
      public_id    = 'DELETED-' || replace(p_user_id::text, '-', '')
  where user_id = p_user_id;

end;
$$;

-- Database half of account deletion. Atomic and idempotent; the Edge Function
-- calls it with the user's own JWT, so auth.uid() is the only identity used.
create or replace function begin_account_deletion()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_state text;
  v_home  uuid;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = 'AD000';
  end if;

  select account_state into v_state from profiles where user_id = v_uid for update;
  if not found then
    raise exception 'Profile not found' using errcode = 'AD001';
  end if;
  if v_state = 'deleted' then
    return v_state;
  end if;

  if v_state = 'active' then
    -- Lock every active membership (serializes against transfer / remove /
    -- join), then refuse while the user still owns a household.
    perform 1 from household_members
    where user_id = v_uid and status = 'active'
    order by household_id
    for update;

    if exists (
      select 1 from household_members
      where user_id = v_uid and role = 'owner' and status = 'active'
    ) then
      raise exception 'Transfer ownership or delete your homes before deleting the account'
        using errcode = 'AD002';
    end if;

    -- Leave every household the ordinary way (task reassignment, events).
    for v_home in
      select household_id from household_members
      where user_id = v_uid and status = 'active'
      order by household_id
    loop
      perform leave_household(v_home);
    end loop;

    update profiles
    set account_state = 'deleting', deletion_requested_at = now()
    where user_id = v_uid;
  end if;

  perform _scrub_account_data(v_uid);

  return 'deleting';
end;
$$;

-- Called by the trusted backend only after the Auth user is really gone.
create or replace function finalize_account_deletion(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
begin
  select account_state into v_state from profiles where user_id = p_user_id for update;
  if not found then
    raise exception 'Profile not found' using errcode = 'AD001';
  end if;
  if v_state = 'deleted' then
    return v_state;
  end if;
  if v_state <> 'deleting' then
    raise exception 'Account deletion was not started' using errcode = 'AD004';
  end if;
  if exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'The Auth user still exists' using errcode = 'AD005';
  end if;
  perform _scrub_account_data(p_user_id);
  update profiles set account_state = 'deleted', deleted_at = now()
  where user_id = p_user_id;
  return 'deleted';
end;
$$;

-- Safety net for a crash between the Auth deletion and finalize.
create or replace function reconcile_account_deletions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update profiles p
  set account_state = 'deleted', deleted_at = now()
  where p.account_state = 'deleting'
    and not exists (select 1 from auth.users u where u.id = p.user_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function _scrub_account_data(uuid) from public, anon, authenticated;
revoke all on function account_deletion_blockers() from public, anon;
grant execute on function account_deletion_blockers() to authenticated;
revoke all on function begin_account_deletion() from public, anon;
grant execute on function begin_account_deletion() to authenticated;
revoke all on function finalize_account_deletion(uuid) from public, anon, authenticated;
grant execute on function finalize_account_deletion(uuid) to service_role;
revoke all on function reconcile_account_deletions() from public, anon, authenticated;
grant execute on function reconcile_account_deletions() to service_role;
