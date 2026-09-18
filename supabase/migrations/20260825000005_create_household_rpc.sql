-- Atomically creates a household, makes the caller its owner, and opens the
-- initial membership period. Returns the created household row.
create or replace function create_household(p_name text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name      text := trim(p_name);
  v_user_id   uuid := auth.uid();
  v_household households;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if v_name = '' then
    raise exception 'Household name must not be blank' using errcode = 'HO001';
  end if;

  insert into households (name, created_by)
  values (v_name, v_user_id)
  returning * into v_household;

  -- Upsert so the function is safe if called more than once for the same pair.
  insert into household_members (household_id, user_id, role, status)
  values (v_household.id, v_user_id, 'owner', 'active')
  on conflict (household_id, user_id) do update
    set role = 'owner', status = 'active', left_at = null;

  insert into household_membership_periods (household_id, user_id)
  values (v_household.id, v_user_id);

  return v_household;
end;
$$;

-- Only authenticated users may call this function.
revoke execute on function create_household(text) from public;
grant  execute on function create_household(text) to authenticated;
