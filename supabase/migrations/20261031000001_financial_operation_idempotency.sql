-- Audit finding F13: idempotent financial operations.
--
-- A lost response after a committed create_equal_split_expense or
-- create_settlement used to let a retry insert a second record. Each logical
-- submission now carries one client-generated request UUID (p_request_id):
--   * the first request claims (actor, request id) in financial_operations and
--     creates the record in the same transaction, so any failure rolls back
--     the claim together with the financial rows;
--   * a replay with the same key and canonical payload returns the original
--     result; a different payload is rejected (HF002);
--   * if the original record was later deleted the replay is rejected (HF003)
--     and never recreates it. Keys are kept indefinitely.
-- Keys are scoped to auth.uid(), so another user's operation is never visible
-- or colliding. A key never replaces authorization: caller membership is
-- checked before any lookup. Calls without p_request_id behave as before.
--
-- Compatibility: CREATE OR REPLACE cannot change a return type or add a
-- parameter without creating an overload, so each function is dropped (no
-- CASCADE; nothing in the database depends on them) and recreated under the
-- same name in this one transaction. The old 6-argument named calls still
-- resolve to the new function through the defaulted parameter, so older apps
-- keep working, without duplicate protection. create_equal_split_expense now
-- returns the new expense id instead of void. The F3 settlement rules and the
-- F11 permissions are unchanged.

create table financial_operations (
  actor_id     uuid        not null references profiles (user_id),
  request_id   uuid        not null,
  household_id uuid        not null references households (id) on delete cascade,
  kind         text        not null,
  fingerprint  text        not null,
  result_id    uuid        not null,
  created_at   timestamptz not null default now(),
  primary key (actor_id, request_id),
  constraint financial_operations_kind_check check (kind in ('expense', 'settlement')),
  constraint financial_operations_fingerprint_check check (fingerprint ~ '^[0-9a-f]{64}$')
);

alter table financial_operations enable row level security;
revoke all on financial_operations from public, anon, authenticated;
-- No policies: only the SECURITY DEFINER functions below read or write it.

create or replace function _expense_request_fingerprint(
  p_household_id uuid,
  p_title        text,
  p_amount_cents bigint,
  p_currency     text,
  p_paid_by      uuid,
  p_participants uuid[]
)
returns text
language sql
immutable
set search_path = public
as $$
  select encode(sha256(convert_to(format(
    'expense|%s|%s|%s|%s|%s|%s',
    p_household_id,
    trim(p_title),
    p_amount_cents,
    p_currency,
    p_paid_by,
    coalesce((
      select string_agg(u::text, ',' order by u::text)
      from (select distinct u from unnest(p_participants) u where u is not null) d
    ), '')
  ), 'UTF8')), 'hex');
$$;

create or replace function _settlement_request_fingerprint(
  p_household_id uuid,
  p_from_user_id uuid,
  p_to_user_id   uuid,
  p_amount_cents bigint,
  p_currency     text,
  p_note         text
)
returns text
language sql
immutable
set search_path = public
as $$
  select encode(sha256(convert_to(format(
    'settlement|%s|%s|%s|%s|%s|%s',
    p_household_id,
    p_from_user_id,
    p_to_user_id,
    p_amount_cents,
    p_currency,
    case when p_note is null then 'N' else 'S' || p_note end
  ), 'UTF8')), 'hex');
$$;

revoke all on function _expense_request_fingerprint(uuid, text, bigint, text, uuid, uuid[])
  from public, anon, authenticated;
revoke all on function _settlement_request_fingerprint(uuid, uuid, uuid, bigint, text, text)
  from public, anon, authenticated;

drop function create_equal_split_expense(uuid, text, bigint, text, uuid, uuid[]);

create function create_equal_split_expense(
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

revoke all on function create_equal_split_expense(uuid, text, bigint, text, uuid, uuid[], uuid)
  from public, anon;
grant execute on function create_equal_split_expense(uuid, text, bigint, text, uuid, uuid[], uuid)
  to authenticated;

drop function create_settlement(uuid, uuid, uuid, bigint, text, text);

create function create_settlement(
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

revoke all on function create_settlement(uuid, uuid, uuid, bigint, text, text, uuid)
  from public, anon;
grant execute on function create_settlement(uuid, uuid, uuid, bigint, text, text, uuid)
  to authenticated;
