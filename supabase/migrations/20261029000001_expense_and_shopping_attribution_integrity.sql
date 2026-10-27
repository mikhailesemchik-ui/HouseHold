-- Audit finding F11: financial and shopping attribution integrity.
--
-- Expenses
--   * Title edits: expense creator, payer, a participant, or the household
--     owner (active members only).
--   * Deletes: creator, payer, or the household owner.
--   * Only the title column is writable by clients (column-level grant), and
--     the guard trigger now also pins paid_by_display_name and created_at, so
--     the payer's displayed name and the record's identity cannot be spoofed.
--   * Creation stays collaborative (create_equal_split_expense unchanged):
--     created_by (the caller) and paid_by remain separate identities.
-- Shopping
--   * While an item is completed, completed_by / completed_at cannot be
--     rewritten. Reopen (both null) and recompletion still work, and completion
--     still has to name the authenticated user.
--
-- Existing rows are not modified.

create or replace function _is_household_owner(p_household_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = auth.uid()
      and role         = 'owner'
      and status       = 'active'
  );
$$;

revoke all on function _is_household_owner(uuid) from public, anon;
grant execute on function _is_household_owner(uuid) to authenticated;

drop policy if exists "expenses_update_active_member" on expenses;
drop policy if exists "expenses_delete_active_member" on expenses;

create policy "expenses_update_authorized"
  on expenses for update
  to authenticated
  using (
    is_active_household_member(household_id)
    and (
      created_by = auth.uid()
      or paid_by = auth.uid()
      or _is_household_owner(household_id)
      or exists (
        select 1 from expense_participants ep
        where ep.expense_id = expenses.id
          and ep.user_id    = auth.uid()
      )
    )
  )
  with check (is_active_household_member(household_id));

create policy "expenses_delete_authorized"
  on expenses for delete
  to authenticated
  using (
    is_active_household_member(household_id)
    and (
      created_by = auth.uid()
      or paid_by = auth.uid()
      or _is_household_owner(household_id)
    )
  );

-- Clients may only change the title; everything else is identity or money.
revoke update on expenses from authenticated;
grant update (title) on expenses to authenticated;

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
  if new.paid_by_display_name is distinct from old.paid_by_display_name then
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

create or replace function enforce_shopping_item_completion_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.completed_at is null and new.completed_at is not null then
    if new.completed_by is distinct from auth.uid() then
      raise exception 'completed_by must be the authenticated user when completing a shopping item'
        using errcode = 'SH001';
    end if;
  elsif old.completed_at is not null and new.completed_at is not null then
    if new.completed_by is distinct from old.completed_by
       or new.completed_at is distinct from old.completed_at then
      raise exception 'completion of a shopping item cannot be rewritten; reopen it first'
        using errcode = 'SH003';
    end if;
  end if;
  return new;
end;
$$;
