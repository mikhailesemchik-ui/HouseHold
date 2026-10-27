-- Audit finding F12: currency and amount integrity.
--
-- * households.currency (default 'EUR') is the single currency of a household.
--   create_equal_split_expense and create_settlement now reject any other
--   currency (HE008 / HS009), so balances can never combine currencies.
--   Clients cannot change it (households has no UPDATE grant). The current app
--   sends EUR and has no currency picker; exchange rates are not supported.
-- * One operation may not exceed 100,000,000 cents (EUR 1,000,000.00),
--   inclusive (HE009 / HS010). The same ceiling is enforced for every INSERT
--   path by a trigger on expenses, expense_settlements and expense_participants.
--   A trigger rather than a CHECK on purpose: it applies to new rows only and
--   never blocks editing or deleting an older row that might already exceed the
--   limit, whereas even a NOT VALID CHECK would reject later updates of such a row.
-- * Both RPCs keep their signatures, return types, grants, SECURITY DEFINER
--   settings and F3 / F11 / F13 behavior. The currency and amount checks run
--   after the F13 replay lookup and before the key is claimed, so a refused
--   request never consumes an idempotency key, and a replay of an already
--   processed request still returns its original result.
-- * Existing rows are not touched: no conversion, deletion or settlement.
--   Existing households receive the default 'EUR'; this is metadata only.

alter table households add column currency text not null default 'EUR';
alter table households
  add constraint households_currency_format check (currency ~ '^[A-Z]{3}$');

create or replace function enforce_financial_amount_cap()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_cents bigint;
begin
  -- Separate statements: NEW only has the columns of the firing table.
  if tg_table_name = 'expense_participants' then
    v_cents := new.share_cents;
  else
    v_cents := new.amount_cents;
  end if;
  if v_cents > 100000000 then
    raise exception 'Amount exceeds the maximum of 1,000,000.00'
      using errcode = case tg_table_name when 'expense_settlements' then 'HS010' else 'HE009' end;
  end if;
  return new;
end;
$$;

create trigger expenses_amount_cap
  before insert on expenses
  for each row execute function enforce_financial_amount_cap();
create trigger expense_settlements_amount_cap
  before insert on expense_settlements
  for each row execute function enforce_financial_amount_cap();
create trigger expense_participants_amount_cap
  before insert on expense_participants
  for each row execute function enforce_financial_amount_cap();

create or replace function create_equal_split_expense(
  p_household_id    uuid,
  p_title           text,
  p_amount_cents    bigint,
  p_currency        text,
  p_paid_by         uuid,
  p_participant_ids uuid[],
  p_request_id      uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller       uuid := auth.uid();
  v_expense_id   uuid := gen_random_uuid();
  v_payer_name   text;
  v_unique_ids   uuid[];
  v_count        int;
  v_base_share   bigint;
  v_remainder    bigint;
  v_uid          uuid;
  v_display_name text;
  v_idx          int := 0;
  v_fp           text;
  v_op           financial_operations;
  v_claimed      int;
  v_household_currency text;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HE000';
  end if;

  if not is_active_household_member(p_household_id) then
    raise exception 'Not a member of this household' using errcode = 'HE001';
  end if;

  -- Replay: same actor and key. Authorization above still applies.
  if p_request_id is not null then
    v_fp := _expense_request_fingerprint(
      p_household_id, p_title, p_amount_cents, p_currency, p_paid_by, p_participant_ids
    );
    select * into v_op
    from financial_operations
    where actor_id = v_caller and request_id = p_request_id;
    if found then
      if v_op.kind <> 'expense' or v_op.fingerprint <> v_fp then
        raise exception 'Request id was already used for a different operation'
          using errcode = 'HF002';
      end if;
      if not exists (select 1 from expenses where id = v_op.result_id) then
        raise exception 'This operation was already processed and the record has since been removed'
          using errcode = 'HF003';
      end if;
      return v_op.result_id;
    end if;
  end if;

  if trim(p_title) = '' then
    raise exception 'Title cannot be blank' using errcode = 'HE002';
  end if;

  if p_amount_cents <= 0 then
    raise exception 'Amount must be positive' using errcode = 'HE003';
  end if;

  if p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid currency code' using errcode = 'HE004';
  end if;

  select currency into v_household_currency from households where id = p_household_id;
  if p_currency is distinct from v_household_currency then
    raise exception 'Currency does not match the household currency'
      using errcode = 'HE008';
  end if;

  if p_amount_cents > 100000000 then
    raise exception 'Amount exceeds the maximum of 1,000,000.00'
      using errcode = 'HE009';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id = p_paid_by
      and status = 'active'
  ) then
    raise exception 'Payer is not an active member' using errcode = 'HE005';
  end if;

  select display_name into v_payer_name
  from profiles where user_id = p_paid_by;

  if v_payer_name is null then
    v_payer_name := 'Unknown';
  end if;

  select array_agg(distinct uid order by uid)
  into v_unique_ids
  from unnest(p_participant_ids) as uid;

  if v_unique_ids is null or array_length(v_unique_ids, 1) = 0 then
    raise exception 'Participant list cannot be empty' using errcode = 'HE006';
  end if;

  foreach v_uid in array v_unique_ids loop
    if not exists (
      select 1 from household_members
      where household_id = p_household_id
        and user_id = v_uid
        and status = 'active'
    ) then
      raise exception 'Participant % is not an active member', v_uid
        using errcode = 'HE007';
    end if;
  end loop;

  -- Atomic claim. A concurrent request with the same key waits here for the
  -- first one to finish, then falls through to the replay path.
  if p_request_id is not null then
    insert into financial_operations (
      actor_id, request_id, household_id, kind, fingerprint, result_id
    ) values (
      v_caller, p_request_id, p_household_id, 'expense', v_fp, v_expense_id
    )
    on conflict (actor_id, request_id) do nothing;
    get diagnostics v_claimed = row_count;
    if v_claimed = 0 then
      select * into v_op
      from financial_operations
      where actor_id = v_caller and request_id = p_request_id;
      if v_op.kind <> 'expense' or v_op.fingerprint <> v_fp then
        raise exception 'Request id was already used for a different operation'
          using errcode = 'HF002';
      end if;
      if not exists (select 1 from expenses where id = v_op.result_id) then
        raise exception 'This operation was already processed and the record has since been removed'
          using errcode = 'HF003';
      end if;
      return v_op.result_id;
    end if;
  end if;

  v_count      := array_length(v_unique_ids, 1);
  v_base_share := p_amount_cents / v_count;
  v_remainder  := p_amount_cents % v_count;

  insert into expenses (
    id, household_id, title, amount_cents, currency,
    paid_by, paid_by_display_name, created_by
  ) values (
    v_expense_id, p_household_id, trim(p_title), p_amount_cents, p_currency,
    p_paid_by, v_payer_name, v_caller
  );

  foreach v_uid in array v_unique_ids loop
    select display_name into v_display_name
    from profiles where user_id = v_uid;

    if v_display_name is null then
      v_display_name := 'Deleted member';
    end if;

    insert into expense_participants (expense_id, user_id, display_name, share_cents)
    values (
      v_expense_id,
      v_uid,
      v_display_name,
      v_base_share + (case when v_idx < v_remainder then 1 else 0 end)
    );

    v_idx := v_idx + 1;
  end loop;

  return v_expense_id;
end;
$$;

create or replace function create_settlement(
  p_household_id uuid,
  p_from_user_id uuid,
  p_to_user_id   uuid,
  p_amount_cents bigint,
  p_currency     text,
  p_note         text default null,
  p_request_id   uuid default null
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
  v_id        uuid := gen_random_uuid();
  v_fp        text;
  v_op        financial_operations;
  v_claimed   int;
  v_household_currency text;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HS000';
  end if;

  if not is_active_household_member(p_household_id) then
    raise exception 'Not a member of this household' using errcode = 'HS001';
  end if;

  -- Replay: same actor and key. Authorization above still applies.
  if p_request_id is not null then
    v_fp := _settlement_request_fingerprint(
      p_household_id, p_from_user_id, p_to_user_id, p_amount_cents, p_currency, p_note
    );
    select * into v_op
    from financial_operations
    where actor_id = v_caller and request_id = p_request_id;
    if found then
      if v_op.kind <> 'settlement' or v_op.fingerprint <> v_fp then
        raise exception 'Request id was already used for a different operation'
          using errcode = 'HF002';
      end if;
      select * into v_row from expense_settlements where id = v_op.result_id;
      if not found then
        raise exception 'This operation was already processed and the record has since been removed'
          using errcode = 'HF003';
      end if;
      return v_row;
    end if;
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

  select currency into v_household_currency from households where id = p_household_id;
  if p_currency is distinct from v_household_currency then
    raise exception 'Currency does not match the household currency'
      using errcode = 'HS009';
  end if;

  if p_amount_cents > 100000000 then
    raise exception 'Amount exceeds the maximum of 1,000,000.00'
      using errcode = 'HS010';
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

  -- Atomic claim (see create_equal_split_expense).
  if p_request_id is not null then
    insert into financial_operations (
      actor_id, request_id, household_id, kind, fingerprint, result_id
    ) values (
      v_caller, p_request_id, p_household_id, 'settlement', v_fp, v_id
    )
    on conflict (actor_id, request_id) do nothing;
    get diagnostics v_claimed = row_count;
    if v_claimed = 0 then
      select * into v_op
      from financial_operations
      where actor_id = v_caller and request_id = p_request_id;
      if v_op.kind <> 'settlement' or v_op.fingerprint <> v_fp then
        raise exception 'Request id was already used for a different operation'
          using errcode = 'HF002';
      end if;
      select * into v_row from expense_settlements where id = v_op.result_id;
      if not found then
        raise exception 'This operation was already processed and the record has since been removed'
          using errcode = 'HF003';
      end if;
      return v_row;
    end if;
  end if;

  select coalesce(display_name, 'Deleted member') into v_from_name
    from profiles where user_id = p_from_user_id;
  select coalesce(display_name, 'Deleted member') into v_to_name
    from profiles where user_id = p_to_user_id;

  insert into expense_settlements (
    id, household_id, from_user_id, from_name,
    to_user_id, to_name, amount_cents, currency, note, created_by
  ) values (
    v_id, p_household_id, p_from_user_id, v_from_name,
    p_to_user_id, v_to_name, p_amount_cents, p_currency, p_note, v_caller
  )
  returning * into v_row;

  return v_row;
end;
$$;
