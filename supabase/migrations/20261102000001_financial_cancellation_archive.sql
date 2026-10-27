-- Audit finding F4: auditable financial cancellations.
--
-- Cancelling an expense or settlement still physically deletes the live row,
-- exactly as before, so every client (old or new) computes the same active
-- balances and receives ordinary Realtime DELETE events. What is new is that a
-- BEFORE DELETE trigger first copies the original record into an append-only
-- archive: the full row, an expense's participant shares, the authenticated
-- actor, a database-generated time and an optional reason.
--
-- * Direct DELETE (older apps) and the new cancel_* RPCs take the same path.
--   The actor is always auth.uid(); only the RPCs can attach a reason, through a
--   transaction-local setting that PostgREST clients cannot set.
-- * Cascaded deletes (pg_trigger_depth() > 1, e.g. a future household or account
--   erasure) are not cancellations and are not archived, and the archive has no
--   foreign key, so it can neither block nor be silently erased by them.
--   Deleting a household that has expenses still fails today because of the
--   existing household_events foreign key; that pre-existing limitation is not
--   changed here.
-- * Archive rows are readable by currently active members of the original
--   household only and are immutable: no client privileges, plus triggers that
--   refuse UPDATE, DELETE and TRUNCATE. A future approved erasure policy must
--   disable those triggers explicitly in its own migration.
-- * The original financial_operations key (F13) is untouched, so replaying the
--   original create request still returns HF003 and never recreates the record.
-- * Settlement DELETE is extended to the sender, the recipient, the original
--   creator (legacy third-party records) and the household owner. Nobody gains
--   the right to create a settlement between other people.
-- * No new household event types: older apps show unknown types as "performed
--   an action", and expense deletions already log expense_deleted.
-- Existing rows are not modified. Deletions made before this migration cannot
-- be reconstructed.

create table financial_archive (
  id               uuid        primary key default gen_random_uuid(),
  kind             text        not null,
  record_id        uuid        not null,
  household_id     uuid        not null,
  snapshot         jsonb       not null,
  canceled_by      uuid        null,
  canceled_by_name text        not null,
  canceled_at      timestamptz not null default now(),
  reason           text        null,
  constraint financial_archive_kind_check check (kind in ('expense', 'settlement')),
  constraint financial_archive_reason_length check (reason is null or char_length(reason) <= 200),
  constraint financial_archive_unique_record unique (kind, record_id)
);

create index financial_archive_household_canceled
  on financial_archive (household_id, canceled_at desc);

alter table financial_archive enable row level security;
revoke all on financial_archive from public, anon, authenticated;
grant select on financial_archive to authenticated;

create policy "financial_archive_select_active_member"
  on financial_archive for select
  to authenticated
  using (is_active_household_member(household_id));

create or replace function financial_archive_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'financial_archive is append-only' using errcode = 'HC003';
end;
$$;

create trigger financial_archive_no_update_delete
  before update or delete on financial_archive
  for each row execute function financial_archive_immutable();

create trigger financial_archive_no_truncate
  before truncate on financial_archive
  for each statement execute function financial_archive_immutable();

create or replace function archive_financial_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor    uuid := auth.uid();
  v_kind     text;
  v_snapshot jsonb;
  v_reason   text;
begin
  -- Deleted by a foreign-key cascade, not cancelled by anyone.
  if pg_trigger_depth() > 1 then
    return old;
  end if;

  if tg_table_name = 'expenses' then
    v_kind := 'expense';
    v_snapshot := to_jsonb(old) || jsonb_build_object(
      'participants',
      coalesce((
        select jsonb_agg(to_jsonb(ep) order by ep.user_id)
        from expense_participants ep
        where ep.expense_id = old.id
      ), '[]'::jsonb)
    );
  else
    v_kind := 'settlement';
    v_snapshot := to_jsonb(old);
  end if;

  v_reason := nullif(left(btrim(coalesce(current_setting('app.cancel_reason', true), '')), 200), '');

  insert into financial_archive (
    kind, record_id, household_id, snapshot, canceled_by, canceled_by_name, reason
  ) values (
    v_kind, old.id, old.household_id, v_snapshot, v_actor,
    coalesce(_resolve_actor_name(v_actor), 'System'), v_reason
  );

  return old;
end;
$$;

revoke all on function archive_financial_deletion() from public, anon, authenticated;

create trigger expenses_archive_before_delete
  before delete on expenses
  for each row execute function archive_financial_deletion();

create trigger expense_settlements_archive_before_delete
  before delete on expense_settlements
  for each row execute function archive_financial_deletion();

-- Settlement DELETE: sender, recipient, original creator or household owner.
drop policy "settlements_delete_creator" on expense_settlements;

create policy "settlements_delete_authorized"
  on expense_settlements for delete
  to authenticated
  using (
    is_active_household_member(household_id)
    and (
      created_by = auth.uid()
      or from_user_id = auth.uid()
      or to_user_id = auth.uid()
      or _is_household_owner(household_id)
    )
  );

create or replace function cancel_expense(
  p_expense_id uuid,
  p_reason     text default null
)
returns financial_archive
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller  uuid := auth.uid();
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_row     expenses;
  v_archive financial_archive;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HC000';
  end if;

  if char_length(v_reason) > 200 then
    raise exception 'Reason is too long' using errcode = 'HC004';
  end if;

  -- The row lock serializes concurrent cancellations of the same expense.
  select * into v_row from expenses where id = p_expense_id for update;

  if found then
    if not is_active_household_member(v_row.household_id) then
      raise exception 'Expense not found' using errcode = 'HC001';
    end if;
    if not (
      v_row.created_by = v_caller
      or v_row.paid_by = v_caller
      or _is_household_owner(v_row.household_id)
    ) then
      raise exception 'You are not allowed to cancel this expense' using errcode = 'HC002';
    end if;

    perform set_config('app.cancel_reason', coalesce(v_reason, ''), true);
    delete from expenses where id = p_expense_id;

    select * into v_archive
    from financial_archive where kind = 'expense' and record_id = p_expense_id;
    return v_archive;
  end if;

  -- Already cancelled: return the original result, only to active members of
  -- its household, without changing anything.
  select * into v_archive
  from financial_archive where kind = 'expense' and record_id = p_expense_id;
  if found and is_active_household_member(v_archive.household_id) then
    return v_archive;
  end if;

  raise exception 'Expense not found' using errcode = 'HC001';
end;
$$;

create or replace function cancel_settlement(
  p_settlement_id uuid,
  p_reason        text default null
)
returns financial_archive
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller  uuid := auth.uid();
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_row     expense_settlements;
  v_archive financial_archive;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = 'HC000';
  end if;

  if char_length(v_reason) > 200 then
    raise exception 'Reason is too long' using errcode = 'HC004';
  end if;

  select * into v_row from expense_settlements where id = p_settlement_id for update;

  if found then
    if not is_active_household_member(v_row.household_id) then
      raise exception 'Payment not found' using errcode = 'HC001';
    end if;
    if not (
      v_row.created_by = v_caller
      or v_row.from_user_id = v_caller
      or v_row.to_user_id = v_caller
      or _is_household_owner(v_row.household_id)
    ) then
      raise exception 'You are not allowed to cancel this payment' using errcode = 'HC002';
    end if;

    perform set_config('app.cancel_reason', coalesce(v_reason, ''), true);
    delete from expense_settlements where id = p_settlement_id;

    select * into v_archive
    from financial_archive where kind = 'settlement' and record_id = p_settlement_id;
    return v_archive;
  end if;

  select * into v_archive
  from financial_archive where kind = 'settlement' and record_id = p_settlement_id;
  if found and is_active_household_member(v_archive.household_id) then
    return v_archive;
  end if;

  raise exception 'Payment not found' using errcode = 'HC001';
end;
$$;

revoke all on function cancel_expense(uuid, text) from public, anon;
grant execute on function cancel_expense(uuid, text) to authenticated;
revoke all on function cancel_settlement(uuid, text) from public, anon;
grant execute on function cancel_settlement(uuid, text) to authenticated;

alter publication supabase_realtime add table financial_archive;
