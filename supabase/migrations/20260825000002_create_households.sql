create table households (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null,
  created_by uuid        not null references profiles (user_id),
  created_at timestamptz not null default now()
);

alter table households enable row level security;

-- SELECT policy added in 20260825000003 after household_members is created.
