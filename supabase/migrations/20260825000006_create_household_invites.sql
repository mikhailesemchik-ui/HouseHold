-- Generates a cryptographically secure random 8-character code (XXXX-XXXX).
-- Omits visually ambiguous characters: 0, O, I, 1.
-- Uses gen_random_uuid() — always available in PG 13+, no extension needed.
-- 256 % 32 == 0, so single-byte values modulo 32 carry no bias.
create or replace function generate_invite_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_uuid  text := replace(gen_random_uuid()::text, '-', '');
  v_part1 text := '';
  v_part2 text := '';
  i       int;
  v_byte  int;
begin
  for i in 0..3 loop
    v_byte := ('x' || substr(v_uuid, i * 2 + 1, 2))::bit(8)::int;
    v_part1 := v_part1 || substr(v_chars, (v_byte % 32) + 1, 1);
  end loop;
  for i in 4..7 loop
    v_byte := ('x' || substr(v_uuid, i * 2 + 1, 2))::bit(8)::int;
    v_part2 := v_part2 || substr(v_chars, (v_byte % 32) + 1, 1);
  end loop;
  return v_part1 || '-' || v_part2;
end;
$$;

create table household_invites (
  id           uuid        primary key default gen_random_uuid(),
  household_id uuid        not null references households (id) on delete cascade,
  code         text        unique not null,
  created_by   uuid        not null references profiles (user_id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz null,
  revoked_at   timestamptz null
);

alter table household_invites enable row level security;

-- Only the active owner of the household may read its invites.
-- Invite creation and revocation go through security-definer RPCs;
-- no direct client INSERT/UPDATE/DELETE policies are intentionally absent.
create policy "invites_select_owner"
  on household_invites for select
  to authenticated
  using (
    exists (
      select 1 from household_members
      where household_members.household_id = household_invites.household_id
        and household_members.user_id      = auth.uid()
        and household_members.role         = 'owner'
        and household_members.status       = 'active'
    )
  );

-- Creates a reusable invite code for a household. Only the active owner may call this.
create or replace function create_household_invite(p_household_id uuid)
returns household_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_code    text;
  v_invite  household_invites;
  v_tries   int := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = p_household_id
      and user_id      = v_user_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only household owners may create invites' using errcode = 'HO002';
  end if;

  loop
    v_code := generate_invite_code();
    begin
      insert into household_invites (household_id, code, created_by)
      values (p_household_id, v_code, v_user_id)
      returning * into v_invite;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries >= 10 then
        raise exception 'Failed to generate a unique invite code after 10 attempts';
      end if;
    end;
  end loop;

  return v_invite;
end;
$$;

-- Sets revoked_at on an invite. Only the active owner of the household may call this.
create or replace function revoke_household_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_household_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  select household_id into v_household_id
  from household_invites
  where id = p_invite_id;

  if v_household_id is null then
    raise exception 'Invite not found' using errcode = 'HO003';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = v_household_id
      and user_id      = v_user_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only household owners may revoke invites' using errcode = 'HO002';
  end if;

  update household_invites
  set revoked_at = now()
  where id = p_invite_id;
end;
$$;

revoke execute on function create_household_invite(uuid) from public;
grant  execute on function create_household_invite(uuid) to authenticated;

revoke execute on function revoke_household_invite(uuid) from public;
grant  execute on function revoke_household_invite(uuid) to authenticated;
