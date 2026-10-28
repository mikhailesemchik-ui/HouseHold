-- F7B: automatic recovery of interrupted account deletions (function half).
--
-- If the Auth user is deleted but finalize_account_deletion() then fails, the
-- profile stays 'deleting'. reconcile_account_deletions() finishes those
-- accounts. It is called on a schedule (see the next migration), never by
-- clients: EXECUTE stays with service_role and the owner only, and the function
-- takes no user id.
--
-- Changes from 20261105000001:
--   * Every account is finalized through finalize_account_deletion(), so the
--     final scrub pass and the "Auth user is gone" check are the same code as
--     the normal path.
--   * Each account runs in its own subtransaction: one failing account is
--     logged (id and SQLSTATE only) and skipped, the others still complete.
--   * At most 100 accounts per call, oldest request first. Rows are locked
--     with SKIP LOCKED, so overlapping runs and a racing begin / finalize on
--     the same account never wait for each other or process it twice. The
--     exception handler runs inside the same transaction that holds the row
--     lock, so finalize's own FOR UPDATE does not wait on it.
--   * A permanently failing account is retried (and logged) on every run; it
--     only crowds out others if 100 or more accounts fail at once.

create or replace function reconcile_account_deletions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_count   integer := 0;
begin
  for v_user_id in
    select p.user_id
    from profiles p
    where p.account_state = 'deleting'
      and not exists (select 1 from auth.users u where u.id = p.user_id)
    order by p.deletion_requested_at nulls first, p.user_id
    limit 100
    for update of p skip locked
  loop
    begin
      perform finalize_account_deletion(v_user_id);
      v_count := v_count + 1;
    exception when others then
      -- Reason: no SQLERRM; constraint messages can carry row data.
      raise warning 'account reconciliation failed for % (sqlstate %)', v_user_id, sqlstate;
    end;
  end loop;
  return v_count;
end;
$$;

revoke all on function reconcile_account_deletions() from public, anon, authenticated;
grant execute on function reconcile_account_deletions() to service_role;

-- Counts only, no names or emails. "finalizable": Auth user gone, the next
-- reconciliation closes it. "auth_present": Auth user still exists, so the
-- user must retry or an operator must look (reconciliation never touches it).
create or replace function account_deletion_health()
returns table (
  finalizable_count      bigint,
  oldest_finalizable_at  timestamptz,
  auth_present_count     bigint,
  oldest_auth_present_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select count(*)                         filter (where not a.present),
         min(p.deletion_requested_at)     filter (where not a.present),
         count(*)                         filter (where a.present),
         min(p.deletion_requested_at)     filter (where a.present)
  from profiles p
  cross join lateral (
    select exists (select 1 from auth.users u where u.id = p.user_id) as present
  ) a
  where p.account_state = 'deleting';
$$;

revoke all on function account_deletion_health() from public, anon, authenticated;
grant execute on function account_deletion_health() to service_role;
