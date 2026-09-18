-- ============================================================
-- expense_settlements: first-class model for recording real-world repayments.
-- A settlement records that from_user_id paid to_user_id an amount_cents.
-- Clients insert via RPC; no direct INSERT policy.
-- ============================================================

create table expense_settlements (
  id           uuid        primary key default gen_random_uuid(),
  household_id uuid        not null references households(id) on delete cascade,
  from_user_id uuid        not null references profiles(user_id),
  from_name    text        not null,
  to_user_id   uuid        not null references profiles(user_id),
  to_name      text        not null,
  amount_cents bigint      not null,
  currency     text        not null default 'EUR',
  note         text,
  created_by   uuid        not null references profiles(user_id),
  created_at   timestamptz not null default now(),
  constraint expense_settlements_amount_positive  check (amount_cents > 0),
  constraint expense_settlements_currency_format  check (currency ~ '^[A-Z]{3}$'),
  constraint expense_settlements_different_users  check (from_user_id <> to_user_id)
);

create index expense_settlements_household_created
  on expense_settlements (household_id, created_at desc);

alter table expense_settlements enable row level security;

-- Active members of the household can read settlements.
create policy "settlements_select_active_member"
  on expense_settlements for select
  to authenticated
  using (is_active_household_member(household_id));

-- Only members may delete their own settlements.
create policy "settlements_delete_creator"
  on expense_settlements for delete
  to authenticated
  using (
    created_by = auth.uid()
    and is_active_household_member(household_id)
  );

-- ============================================================
-- RPC: create_settlement
-- Atomically validates and inserts a settlement row.
-- Caller must be an active member. from_user and to_user must be active members.
-- ============================================================

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

  if p_amount_cents <= 0 then
    raise exception 'Amount must be positive' using errcode = 'HS003';
  end if;

  if p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid currency code' using errcode = 'HS004';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = p_from_user_id and status = 'active'
  ) then
    raise exception 'Payer is not an active member' using errcode = 'HS005';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = p_to_user_id and status = 'active'
  ) then
    raise exception 'Receiver is not an active member' using errcode = 'HS006';
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

revoke all on function create_settlement(uuid, uuid, uuid, bigint, text, text) from public;
grant execute on function create_settlement(uuid, uuid, uuid, bigint, text, text)
  to authenticated;

-- ============================================================
-- Realtime
-- ============================================================

alter publication supabase_realtime add table expense_settlements;
