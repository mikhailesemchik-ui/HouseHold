-- Audit finding F3: create_settlement let any active member record a payment
-- between two other people. The caller must now be the sender or the
-- recipient, and an active member of the household.
--
-- The other party only needs a genuine membership record in the household
-- (active or departed), so an active member can record a real payment with
-- someone who has left. Departed members cannot start a settlement, and
-- ownership grants no extra right to record payments between others.
--
-- Signature, return type and grants are unchanged. Existing settlements are
-- not touched.

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

  -- The caller is active (checked above); the other party needs any membership
  -- row, so payments with former members can still be recorded.
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
