create table household_members (
  household_id uuid        not null references households (id) on delete cascade,
  user_id      uuid        not null references profiles (user_id),
  role         text        not null,
  status       text        not null,
  joined_at    timestamptz not null default now(),
  left_at      timestamptz null,
  primary key (household_id, user_id),
  constraint household_members_role_check   check (role   in ('owner', 'member')),
  constraint household_members_status_check check (status in ('active', 'left'))
);

alter table household_members enable row level security;

-- Use a security-definer function to check membership without re-entering
-- RLS on this table, which would cause a policy self-reference cycle.
create or replace function is_active_household_member(p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = auth.uid()
      and status       = 'active'
  );
$$;

-- Active household members can read their household.
create policy "households_select_member"
  on households for select
  to authenticated
  using (is_active_household_member(id));

-- Members can read all membership rows for households they actively belong to.
create policy "household_members_select_active"
  on household_members for select
  to authenticated
  using (is_active_household_member(household_id));
