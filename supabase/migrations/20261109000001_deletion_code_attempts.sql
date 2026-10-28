-- F1b hardening: a per-user limit on emailed-code verification attempts made
-- through the delete-account Edge Function.
--
-- Why: the function checks the code with Supabase Auth from its own source IP,
-- so Auth's IP-based verification limit is one bucket shared by every user. This
-- adds a limit per authenticated user that is enforced BEFORE Auth is contacted.
--
-- Policy (fixed window, counts ALL submissions):
--   * at most 5 submissions per user per 15-minute window;
--   * the window starts at the first reservation after the previous window
--     ended and is NOT extended by later attempts (a fixed window, so a burst
--     of up to 10 is possible across a window boundary: accepted tradeoff);
--   * every reservation counts, including ones whose code turns out to be
--     right and ones the caller abandons. Counting only failures would need a
--     second write after the Auth call, and a gap between the two is exactly
--     what parallel requests would use to get past the limit;
--   * a rejected attempt changes nothing, so it can neither extend nor reset
--     the window; access returns by itself when the window has passed.
--
-- reserve_deletion_code_attempt() is one INSERT .. ON CONFLICT DO UPDATE with a
-- WHERE guard. Concurrent calls for a user queue on that row's lock and each
-- re-checks the guard against the latest row, so no more than 5 are ever
-- accepted per window; a CHECK constraint repeats the cap in the table itself.
--
-- What this does NOT do: revoke a code Auth already issued, stop that code
-- from being used through ordinary email sign-in, fix Auth accepting one code
-- in several simultaneous verifications, or remove the shared Auth limit at the
-- function's IP. A compromised session can use up its own account's attempts
-- (the deliberate tradeoff); the rightful owner regains access when the window
-- ends. Many separate malicious accounts can still load the shared Auth limit.
--
-- Only the user id is stored: no email, code or token. One row per user, and
-- the row goes with the Auth user (ON DELETE CASCADE). Rows idle for a day are
-- pruned a few at a time by the function itself, so no cron job is needed.

create table deletion_code_attempts (
  user_id           uuid        primary key references auth.users (id) on delete cascade,
  window_started_at timestamptz not null default now(),
  attempt_count     integer     not null check (attempt_count between 1 and 5)
);

-- No client or service-role access to the table itself: the function below is
-- the only way in. RLS stays on with no policy as a second barrier.
alter table deletion_code_attempts enable row level security;
revoke all on deletion_code_attempts from public, anon, authenticated, service_role;

create or replace function reserve_deletion_code_attempt(p_user_id uuid)
returns table (allowed boolean, retry_after_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max    constant integer  := 5;
  c_window constant interval := interval '15 minutes';
  v_now     timestamptz := clock_timestamp();
  v_started timestamptz;
begin
  if p_user_id is null then
    raise exception 'User id required' using errcode = 'DC000';
  end if;

  -- Bounded housekeeping: a few rows idle for a day, never the caller's own.
  delete from deletion_code_attempts
  where ctid in (
    select ctid from deletion_code_attempts
    where window_started_at < v_now - interval '1 day' and user_id <> p_user_id
    limit 20
    for update skip locked
  );

  insert into deletion_code_attempts as a (user_id, window_started_at, attempt_count)
  values (p_user_id, v_now, 1)
  on conflict (user_id) do update
    set window_started_at = case
          when a.window_started_at <= v_now - c_window then v_now
          else a.window_started_at end,
        attempt_count = case
          when a.window_started_at <= v_now - c_window then 1
          else a.attempt_count + 1 end
    where a.window_started_at <= v_now - c_window or a.attempt_count < c_max;

  if found then
    return query select true, 0;
    return;
  end if;

  -- Over the limit: report when the window ends; change nothing.
  select window_started_at into v_started
  from deletion_code_attempts where user_id = p_user_id;
  return query select false,
    greatest(1, ceil(extract(epoch from (v_started + c_window - clock_timestamp()))))::integer;
end;
$$;

revoke all on function reserve_deletion_code_attempt(uuid) from public, anon, authenticated;
grant execute on function reserve_deletion_code_attempt(uuid) to service_role;
