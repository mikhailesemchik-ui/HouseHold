create table household_membership_periods (
  id           uuid        primary key default gen_random_uuid(),
  household_id uuid        not null references households (id) on delete cascade,
  user_id      uuid        not null references profiles (user_id),
  joined_at    timestamptz not null default now(),
  left_at      timestamptz null
);

create index household_membership_periods_lookup
  on household_membership_periods (household_id, user_id);

alter table household_membership_periods enable row level security;

-- Active household members can read membership periods for their household.
-- No insert/update/delete policies: clients cannot mutate this table directly.
create policy "membership_periods_select_active_member"
  on household_membership_periods for select
  to authenticated
  using (is_active_household_member(household_id));

-- Backfill: seed an initial period for each existing active membership.
insert into household_membership_periods (household_id, user_id, joined_at)
select household_id, user_id, joined_at
from household_members
where status = 'active';
