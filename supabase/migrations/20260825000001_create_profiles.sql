create table profiles (
  user_id    uuid        primary key references auth.users (id) on delete cascade,
  public_id  text        unique not null,
  display_name text      not null,
  avatar_url text        null,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

create policy "profiles_select_own"
  on profiles for select
  to authenticated
  using (auth.uid() = user_id);

create policy "profiles_insert_own"
  on profiles for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "profiles_update_own"
  on profiles for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
