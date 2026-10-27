-- Audit finding F7A: an owner must be able to delete a whole household.
--
-- Deleting a populated household used to fail: the cascade removed the
-- household row first, and the expense / task AFTER DELETE triggers then
-- inserted event rows that point at the household that was already gone.
-- delete_household() instead removes the child data explicitly, in
-- foreign-key-safe order, while the household row still exists, and deletes
-- the household row last. Everything runs in one transaction.
--
-- Archive erasure (F4). financial_archive stays append-only. A row may be
-- deleted only when ALL of the following hold, so a client cannot reproduce it:
--   * the statement is a row DELETE (UPDATE and TRUNCATE are always refused);
--   * the transaction-local setting app.erase_household equals that row's
--     household id (scopes the erasure to exactly one household);
--   * current_user is the owner of delete_household(). Inside the SECURITY
--     DEFINER function that is the function owner; for a client session it is
--     authenticated / anon, and a session cannot switch to the owner role.
-- The setting alone is never sufficient: clients may be able to set a custom
-- setting, but they cannot satisfy the current_user check, and
-- authenticated/anon hold no DELETE privilege on the table at all.
-- The F4 delete triggers are left untouched, so deleting expenses and
-- settlements here still writes archive rows, which are erased right after.
--
-- Not covered: account deletion (F7B), which is a separate operation.

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
  raise exception 'financial_archive is append-only' using errcode = 'HC003';
end;
$$;

create or replace function delete_household(p_household_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'Authentication required' using errcode = 'HD000';
  end if;

  -- Cheap pre-check so that outsiders never take locks on a household.
  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id      = v_caller
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only the household owner may delete it' using errcode = 'HD002';
  end if;

  -- Lock order matches join / remove (invites, then membership) with the
  -- household row in between. Writers that insert children need a key-share
  -- lock on the household row, so they wait here and then fail on the
  -- foreign key instead of leaving orphan rows.
  perform 1 from household_invites where household_id = p_household_id for update;
  perform 1 from households where id = p_household_id for update;

  -- Ownership may have changed while waiting for the locks: check again.
  perform 1
  from household_members
  where household_id = p_household_id
    and user_id      = v_caller
    and role         = 'owner'
    and status       = 'active'
  for update;
  if not found then
    raise exception 'Only the household owner may delete it' using errcode = 'HD002';
  end if;

  perform set_config('app.erase_household', p_household_id::text, true);

  delete from expense_settlements where household_id = p_household_id;
  delete from expenses            where household_id = p_household_id;
  delete from tasks               where household_id = p_household_id;
  delete from financial_archive   where household_id = p_household_id;
  delete from financial_operations where household_id = p_household_id;
  -- Remaining children (members, periods, invites, shopping, events, outbox)
  -- have no delete-time triggers and are removed by the cascade.
  delete from households          where id = p_household_id;

  perform set_config('app.erase_household', '', true);
end;
$$;

revoke all on function delete_household(uuid) from public, anon;
grant execute on function delete_household(uuid) to authenticated;
