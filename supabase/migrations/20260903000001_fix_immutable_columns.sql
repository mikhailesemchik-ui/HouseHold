-- ============================================================
-- Enforce immutability of structural / financial columns that
-- RLS WITH CHECK alone cannot protect (no access to OLD row).
-- ============================================================

-- tasks: household_id and created_by must not change after INSERT.
create or replace function tasks_guard_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.household_id <> old.household_id then
    raise exception 'tasks.household_id is immutable'
      using errcode = 'HO020';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'tasks.created_by is immutable'
      using errcode = 'HO021';
  end if;
  return new;
end;
$$;

create trigger tasks_immutable_guard
  before update on tasks
  for each row execute function tasks_guard_immutable();

-- shopping_items: household_id and created_by must not change.
create or replace function shopping_items_guard_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.household_id <> old.household_id then
    raise exception 'shopping_items.household_id is immutable'
      using errcode = 'HO022';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'shopping_items.created_by is immutable'
      using errcode = 'HO023';
  end if;
  return new;
end;
$$;

create trigger shopping_items_immutable_guard
  before update on shopping_items
  for each row execute function shopping_items_guard_immutable();

-- expenses: financial and structural fields must not change.
-- Only the title column is intended to be user-editable.
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
  return new;
end;
$$;

create trigger expenses_immutable_guard
  before update on expenses
  for each row execute function expenses_guard_immutable();
