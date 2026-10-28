-- F7B hardening (follow-up to 20261105000001_account_deletion.sql).
--
-- 1. begin_account_deletion() was executable by every authenticated user, so a
--    client could skip the Edge Function (DELETE confirmation, and the future
--    F1 re-verification). It becomes begin_account_deletion(p_user_id uuid),
--    executable by service_role only; the Edge Function derives the id from the
--    verified Auth user. The zero-argument overload is dropped.
-- 2. Tombstone public ids were 'DELETED-' || user id, so anyone could register
--    that value as their own public_id and make the victim's deletion fail on
--    the unique index. Tombstone ids are now random, and an active profile can
--    no longer carry the DELETED- prefix (CHECK, enforced in the database).
-- 3. authenticated could INSERT every profiles column, including account_state
--    and the deletion timestamps. INSERT is limited to the three columns the
--    app supplies.
--
-- _scrubbing_user() identifies the privileged cleanup context by the OWNER of
-- begin_account_deletion; only the signature it looks up changes. The context
-- is still "current role is that owner" plus the app.scrub_user setting.

-- (3) Column-level INSERT. A table-level grant would override column grants,
-- so revoke it first.
revoke insert on profiles from authenticated;
grant insert (user_id, public_id, display_name) on profiles to authenticated;

-- (2) Reserve the tombstone namespace. NOT VALID: a pre-existing squatter row
-- would otherwise abort the migration; every new or changed row is checked.
alter table profiles
  add constraint profiles_public_id_not_tombstone
  check (public_id !~* '^DELETED-' or account_state <> 'active') not valid;

-- (1) Trusted entry point. Same state machine as before, target passed in.
create or replace function begin_account_deletion(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state       text;
  v_home        uuid;
  v_prev_sub    text;
  v_prev_claims text;
begin
  if p_user_id is null then
    raise exception 'User id required' using errcode = 'AD000';
  end if;

  select account_state into v_state from profiles where user_id = p_user_id for update;
  if not found then
    raise exception 'Profile not found' using errcode = 'AD001';
  end if;
  if v_state = 'deleted' then
    return v_state;
  end if;

  if v_state = 'active' then
    perform 1 from household_members
    where user_id = p_user_id and status = 'active'
    order by household_id
    for update;

    if exists (
      select 1 from household_members
      where user_id = p_user_id and role = 'owner' and status = 'active'
    ) then
      raise exception 'Transfer ownership or delete your homes before deleting the account'
        using errcode = 'AD002';
    end if;

    -- Reason: leave_household() and the task-event triggers attribute work to
    -- auth.uid(). This function is service_role only, so pin that identity to
    -- the target while leaving the households, then restore the caller's.
    v_prev_sub    := coalesce(current_setting('request.jwt.claim.sub', true), '');
    v_prev_claims := coalesce(current_setting('request.jwt.claims', true), '');
    perform set_config('request.jwt.claim.sub', p_user_id::text, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);

    for v_home in
      select household_id from household_members
      where user_id = p_user_id and status = 'active'
      order by household_id
    loop
      perform leave_household(v_home);
    end loop;

    perform set_config('request.jwt.claim.sub', v_prev_sub, true);
    perform set_config('request.jwt.claims', v_prev_claims, true);

    update profiles
    set account_state = 'deleting', deletion_requested_at = now()
    where user_id = p_user_id;
  end if;

  perform _scrub_account_data(p_user_id);

  return 'deleting';
end;
$$;

revoke all on function begin_account_deletion(uuid) from public, anon, authenticated;
grant execute on function begin_account_deletion(uuid) to service_role;

-- Same check as before, pointed at the new signature.
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
       where p.oid = 'public.begin_account_deletion(uuid)'::regprocedure
     );
end;
$$;

-- Nothing else references the old signature (plpgsql bodies are not tracked
-- dependencies; the only references were _scrubbing_user, replaced above, and
-- the pre-existing tests). No CASCADE.
drop function begin_account_deletion();

-- (2) Random tombstone id. gen_random_uuid() is a CSPRNG (122 random bits).
-- Assigned once; repeated scrubs keep it. A collision is retried.
create or replace function _scrub_account_data(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gone constant text := 'Deleted member';
  v_try  integer;
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
      avatar_url   = null
  where user_id = p_user_id;

  if exists (
    select 1 from profiles
    where user_id = p_user_id and public_id !~ '^DELETED-[0-9a-f]{32}$'
  ) then
    for v_try in 1..5 loop
      begin
        update profiles
        set public_id = 'DELETED-' || replace(gen_random_uuid()::text, '-', '')
        where user_id = p_user_id;
        exit;
      exception when unique_violation then
        if v_try = 5 then
          raise;
        end if;
      end;
    end loop;
  end if;
end;
$$;

revoke all on function _scrub_account_data(uuid) from public, anon, authenticated;
