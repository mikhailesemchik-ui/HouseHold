-- Follow-up to 20261028000001 (finding F3), interim rule.
--
-- A departed member cannot see or dispute household records, so an active
-- member must not be able to claim "I paid <former member>": that would let
-- the caller wipe their own debt unilaterally. The reverse, "<former member>
-- paid me", works against the caller's own interest and stays allowed.
--
-- Rule: the caller is active and is the sender or the recipient; both parties
-- have a membership row; the recipient must be an active member. (A former
-- recipient is only reachable when the caller is the sender, so that case is
-- exactly the one being refused.) Ownership grants no bypass. Signature,
-- return type, grants and search_path are unchanged; existing rows untouched.
-- Write-off and former-member resolution are deferred.

create or replace function create_settlement(
  p_household_id uuid,
  p_from_user_id uuid,
  p_to_user_id   uuid,
  p_amount_cents bigint,
  p_currency     text,
  p_note         text default null
)
returns expense_settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller    uuid := auth.uid();
  v_from_name text;
  v_to_name   text;
  v_row       expense_settlements;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HS000';
  end if;

  if not is_active_household_member(p_household_id) then
    raise exception 'Not a member of this household' using errcode = 'HS001';
  end if;

  if p_from_user_id = p_to_user_id then
    raise exception 'Payer and receiver must be different members' using errcode = 'HS002';
  end if;

  if v_caller is distinct from p_from_user_id
     and v_caller is distinct from p_to_user_id then
    raise exception 'You can only record a payment you made or received'
      using errcode = 'HS007';
  end if;

  if p_amount_cents <= 0 then
    raise exception 'Amount must be positive' using errcode = 'HS003';
  end if;

  if p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid currency code' using errcode = 'HS004';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = p_from_user_id
  ) then
    raise exception 'Payer has no membership in this household' using errcode = 'HS005';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = p_to_user_id
  ) then
    raise exception 'Receiver has no membership in this household' using errcode = 'HS006';
  end if;

  -- Interim rule: a payment to a former member cannot be claimed by the sender.
  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id      = p_to_user_id
      and status       = 'active'
  ) then
    raise exception 'A payment to a former member cannot be recorded'
      using errcode = 'HS008';
  end if;

  select coalesce(display_name, 'Deleted member') into v_from_name
    from profiles where user_id = p_from_user_id;
  select coalesce(display_name, 'Deleted member') into v_to_name
    from profiles where user_id = p_to_user_id;

  insert into expense_settlements (
    household_id, from_user_id, from_name,
    to_user_id, to_name, amount_cents, currency, note, created_by
  ) values (
    p_household_id, p_from_user_id, v_from_name,
    p_to_user_id, v_to_name, p_amount_cents, p_currency, p_note, v_caller
  )
  returning * into v_row;

  return v_row;
end;
$$;
