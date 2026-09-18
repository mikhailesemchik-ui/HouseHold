create table shopping_items (
  id           uuid        primary key default gen_random_uuid(),
  household_id uuid        not null references households(id) on delete cascade,
  name         text        not null,
  quantity     text        null,
  created_by   uuid        not null references profiles(user_id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  completed_at timestamptz null,
  completed_by uuid        null references profiles(user_id) on delete set null,

  constraint shopping_items_name_not_empty
    check (trim(name) <> ''),

  constraint shopping_items_completion_consistency
    check ((completed_at is null) = (completed_by is null))
);

-- Household list queries and ordering.
create index shopping_items_household_created
  on shopping_items (household_id, created_at desc);

-- Fast filter for incomplete items per household.
create index shopping_items_incomplete
  on shopping_items (household_id)
  where completed_at is null;

-- Recent completed items (for clear-completed queries).
create index shopping_items_completed
  on shopping_items (household_id, completed_at desc)
  where completed_at is not null;

create trigger shopping_items_updated_at
  before update on shopping_items
  for each row execute function set_updated_at();

-- When transitioning from incomplete to complete, completed_by must equal
-- auth.uid(). Enforced in a trigger because RLS WITH CHECK cannot access OLD.
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
  end if;
  return new;
end;
$$;

create trigger shopping_items_enforce_completion_identity
  before update on shopping_items
  for each row execute function enforce_shopping_item_completion_identity();

alter table shopping_items enable row level security;

create policy "shopping_items_select_active_member"
  on shopping_items for select
  to authenticated
  using (is_active_household_member(household_id));

create policy "shopping_items_insert_active_member"
  on shopping_items for insert
  to authenticated
  with check (
    is_active_household_member(household_id)
    and created_by = auth.uid()
  );

create policy "shopping_items_update_active_member"
  on shopping_items for update
  to authenticated
  using (is_active_household_member(household_id))
  with check (is_active_household_member(household_id));

create policy "shopping_items_delete_active_member"
  on shopping_items for delete
  to authenticated
  using (is_active_household_member(household_id));

-- Deletes all completed items for an active member's household in one operation.
create or replace function clear_completed_shopping_items(p_household_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_active_household_member(p_household_id) then
    raise exception 'Not an active member of this household'
      using errcode = 'SH002';
  end if;
  delete from shopping_items
  where household_id = p_household_id
    and completed_at is not null;
end;
$$;

revoke all on function clear_completed_shopping_items(uuid) from anon;
grant execute on function clear_completed_shopping_items(uuid) to authenticated;

alter publication supabase_realtime add table shopping_items;
