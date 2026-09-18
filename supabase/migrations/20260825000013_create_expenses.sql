-- ============================================================
-- expenses + expense_participants, RLS, RPC
-- ============================================================

create table expenses (
  id              uuid        primary key default gen_random_uuid(),
  household_id    uuid        not null references households(id) on delete cascade,
  title           text        not null,
  amount_cents    bigint      not null,
  currency        text        not null default 'EUR',
  paid_by         uuid        not null references profiles(user_id),
  paid_by_display_name text  not null,
  created_by      uuid        not null references profiles(user_id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint expenses_title_not_empty   check (trim(title) <> ''),
  constraint expenses_amount_positive   check (amount_cents > 0),
  constraint expenses_currency_format   check (currency ~ '^[A-Z]{3}$')
);

create table expense_participants (
  expense_id   uuid    not null references expenses(id) on delete cascade,
  user_id      uuid    not null references profiles(user_id),
  display_name text    not null,
  share_cents  bigint  not null,
  primary key (expense_id, user_id),
  constraint expense_participants_share_nonneg check (share_cents >= 0)
);

-- Indexes
create index expenses_household_created
  on expenses (household_id, created_at desc);

create index expense_participants_expense
  on expense_participants (expense_id);

-- Reuse set_updated_at trigger from tasks migration
create trigger set_expenses_updated_at
  before update on expenses
  for each row execute function set_updated_at();

-- ============================================================
-- RLS
-- ============================================================

alter table expenses            enable row level security;
alter table expense_participants enable row level security;

-- expenses: active members of the household can read, update title, delete
create policy "expenses_select_active_member"
  on expenses for select
  to authenticated
  using (is_active_household_member(household_id));

-- Only RPC inserts expenses; no direct INSERT policy.

create policy "expenses_update_active_member"
  on expenses for update
  to authenticated
  using (is_active_household_member(household_id))
  with check (is_active_household_member(household_id));

create policy "expenses_delete_active_member"
  on expenses for delete
  to authenticated
  using (is_active_household_member(household_id));

-- expense_participants: readable when caller is an active member of the parent household
create policy "expense_participants_select_active_member"
  on expense_participants for select
  to authenticated
  using (
    exists (
      select 1 from expenses e
      where e.id = expense_participants.expense_id
        and is_active_household_member(e.household_id)
    )
  );

-- ============================================================
-- Allow co-members to see each other's profiles.
-- Required for member-name resolution in member picker.
-- ============================================================

create policy "profiles_select_co_member"
  on profiles for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from household_members hm
      where hm.user_id = profiles.user_id
        and is_active_household_member(hm.household_id)
    )
  );

-- ============================================================
-- RPC: create_equal_split_expense
-- Atomically creates an expense and equal-split participants.
-- Payer need not be in the participant list.
-- Remainder cents go to the first participant (sorted by user_id).
-- ============================================================

create or replace function create_equal_split_expense(
  p_household_id   uuid,
  p_title          text,
  p_amount_cents   bigint,
  p_currency       text,
  p_paid_by        uuid,
  p_participant_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller         uuid := auth.uid();
  v_expense_id     uuid;
  v_payer_name     text;
  v_unique_ids     uuid[];
  v_count          int;
  v_base_share     bigint;
  v_remainder      bigint;
  v_uid            uuid;
  v_display_name   text;
  v_idx            int := 0;
begin
  -- Caller must be authenticated
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HE000';
  end if;

  -- Caller must be an active member of the household
  if not is_active_household_member(p_household_id) then
    raise exception 'Not a member of this household' using errcode = 'HE001';
  end if;

  -- Validate inputs
  if trim(p_title) = '' then
    raise exception 'Title cannot be blank' using errcode = 'HE002';
  end if;

  if p_amount_cents <= 0 then
    raise exception 'Amount must be positive' using errcode = 'HE003';
  end if;

  if p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid currency code' using errcode = 'HE004';
  end if;

  -- Payer must be an active member
  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id = p_paid_by
      and status = 'active'
  ) then
    raise exception 'Payer is not an active member' using errcode = 'HE005';
  end if;

  -- Fetch payer display name
  select display_name into v_payer_name
  from profiles where user_id = p_paid_by;

  if v_payer_name is null then
    v_payer_name := 'Unknown';
  end if;

  -- De-duplicate participant IDs and verify each is an active member
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

  v_count    := array_length(v_unique_ids, 1);
  v_base_share := p_amount_cents / v_count;
  v_remainder  := p_amount_cents % v_count;

  -- Insert expense
  insert into expenses (
    household_id, title, amount_cents, currency,
    paid_by, paid_by_display_name, created_by
  ) values (
    p_household_id, trim(p_title), p_amount_cents, p_currency,
    p_paid_by, v_payer_name, v_caller
  )
  returning id into v_expense_id;

  -- Insert participants (first gets any remainder cent)
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
end;
$$;

revoke all on function create_equal_split_expense(uuid, text, bigint, text, uuid, uuid[]) from public;
grant execute on function create_equal_split_expense(uuid, text, bigint, text, uuid, uuid[])
  to authenticated;

-- ============================================================
-- Realtime
-- ============================================================

alter publication supabase_realtime add table expenses;
