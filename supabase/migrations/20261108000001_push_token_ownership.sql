-- Push hardening: token ownership and reliable outbox processing.
--
-- 1. OWNERSHIP. A push token identifies one app installation, so it can have
--    only one owner at a time. Until now the same token string could be stored
--    for several users: after a revoked session, a shared device kept
--    receiving the previous account's notifications. The token is now unique,
--    and register_device_push_token() moves it to the caller.
--
--    A token string is NOT proof that the caller holds the device; it is only a
--    bearer secret that the platform gives to the app. So this function cannot
--    verify physical possession, and a caller who somehow learns another
--    device's token can take that registration over (the owner re-registers at
--    their next launch; see the app's startup sync). What limits the damage:
--    tokens are never readable by other users (row level security), the
--    function takes no user id, answers every call identically and removes
--    ONLY rows holding exactly the presented token, so other devices of the
--    same user are never touched.
--
--    Existing duplicates: where several users hold the same token, the most
--    recently refreshed registration is kept. Duplicate ownership of one token
--    cannot all be valid (one installation, one signed-in user), and the older
--    ones are exactly the stale cross-account registrations this closes; their
--    users register again at their next launch. Audit first on any real
--    database with:
--      select token, count(*) from device_push_tokens group by 1 having count(*) > 1;
--
--    Deployed app versions write the table directly; that keeps working for
--    unowned tokens (a token owned by someone else is refused by the unique
--    constraint, never duplicated). Direct INSERT / UPDATE can be revoked in a
--    later release once those versions are gone.
--
-- 2. OUTBOX. The worker claims rows atomically (FOR UPDATE SKIP LOCKED) with a
--    lease, counts attempts, retries a bounded number of times and records
--    success or failure. A crashed worker's rows become claimable again when
--    the lease expires. Delivery to the push provider is AT LEAST ONCE: a crash
--    after sending but before recording can send again. Processed and failed
--    rows are deleted after a retention period, so notification text does not
--    accumulate.

-- ---------------------------------------------------------------------------
-- 1. One owner per token
-- ---------------------------------------------------------------------------

do $$
declare
  v_removed integer;
begin
  with ranked as (
    select id,
           row_number() over (
             partition by token order by updated_at desc, id desc
           ) as position
    from device_push_tokens
  )
  delete from device_push_tokens t
  using ranked r
  where t.id = r.id and r.position > 1;
  get diagnostics v_removed = row_count;
  if v_removed > 0 then
    raise notice 'removed % superseded duplicate push token registrations', v_removed;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.device_push_tokens'::regclass
      and conname = 'device_push_tokens_token_unique'
  ) then
    alter table device_push_tokens
      add constraint device_push_tokens_token_unique unique (token);
  end if;
end $$;

-- The caller's own registration of this installation's token.
--   p_register = true : the token becomes the caller's (idempotent).
--   p_register = false: the caller has not opted in; the token is only released
--                       from other users, nothing is registered for the caller.
-- The caller is auth.uid(); there is no user id parameter. Inactive accounts
-- (deleting / deleted) are refused. Returns nothing, so a caller cannot tell
-- whether the token was owned by anyone else.
create or replace function register_device_push_token(
  p_token    text,
  p_platform text,
  p_register boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_token   text := trim(coalesce(p_token, ''));
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;
  if p_platform is null or p_platform not in ('android', 'ios') then
    raise exception 'Invalid platform' using errcode = 'PT001';
  end if;
  -- (a regular expression repetition is capped at 255, so the length is separate)
  if length(v_token) not between 32 and 4096
     or v_token !~ '^[A-Za-z0-9:_.=+/%-]+$' then
    raise exception 'Invalid push token' using errcode = 'PT002';
  end if;

  -- Serializes against begin_account_deletion(), which locks this row FOR
  -- UPDATE: a deleting account never gains a registration.
  perform 1 from profiles where user_id = v_user_id and account_state = 'active' for share;
  if not found then
    raise exception 'Account is not active' using errcode = 'AD003';
  end if;

  -- One transaction at a time per token string, so concurrent claims end with
  -- exactly one owner (the later one).
  perform pg_advisory_xact_lock(hashtextextended('push_token:' || v_token, 0));

  delete from device_push_tokens
  where token = v_token and user_id <> v_user_id;

  if p_register then
    insert into device_push_tokens (user_id, token, platform)
    values (v_user_id, v_token, p_platform)
    on conflict (user_id, token) do update
      set platform = excluded.platform, updated_at = now();
  end if;
end;
$$;

revoke all on function register_device_push_token(text, text, boolean) from public, anon;
grant execute on function register_device_push_token(text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Reliable outbox processing (service role only, called by the worker)
-- ---------------------------------------------------------------------------

alter table notification_outbox
  add column if not exists claimed_at    timestamptz,
  add column if not exists attempt_count integer not null default 0,
  add column if not exists failed_at     timestamptz;

-- Atomically hands out up to p_limit pending rows. A row is pending until it is
-- processed or has failed for good, is not leased by another worker, and has
-- attempts left. The title and body are deliberately NOT returned: the worker
-- sends generic visible text and never needs them.
create or replace function claim_notification_outbox(
  p_limit        integer  default 10,
  p_lease        interval default interval '5 minutes',
  p_max_attempts integer  default 5
)
returns table (
  id                uuid,
  recipient_user_id uuid,
  household_id      uuid,
  type              text,
  payload           jsonb,
  attempt_count     integer
)
language plpgsql
set search_path = public
as $$
begin
  -- Rows whose attempts are used up (including by crashed workers) stop here.
  update notification_outbox o
  set failed_at = now(), claimed_at = null
  where o.processed_at is null
    and o.failed_at is null
    and o.attempt_count >= p_max_attempts
    and (o.claimed_at is null or o.claimed_at < now() - p_lease);

  return query
  with picked as (
    select o.id
    from notification_outbox o
    where o.processed_at is null
      and o.failed_at is null
      and o.attempt_count < p_max_attempts
      and (o.claimed_at is null or o.claimed_at < now() - p_lease)
    order by o.created_at, o.id
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  )
  update notification_outbox o
  set claimed_at = now(), attempt_count = o.attempt_count + 1
  from picked
  where o.id = picked.id
  returning o.id, o.recipient_user_id, o.household_id, o.type, o.payload,
            o.attempt_count;
end;
$$;

create or replace function complete_notification(p_id uuid)
returns void
language sql
set search_path = public
as $$
  update notification_outbox
  set processed_at = now(), claimed_at = null
  where id = p_id and processed_at is null;
$$;

-- A failed attempt. Retried on the next run unless it is permanent or the
-- attempts are used up, in which case the row is closed as failed.
create or replace function fail_notification(
  p_id           uuid,
  p_permanent    boolean default false,
  p_max_attempts integer default 5
)
returns void
language sql
set search_path = public
as $$
  update notification_outbox
  set claimed_at = null,
      failed_at = case
        when p_permanent or attempt_count >= p_max_attempts then now()
        else null
      end
  where id = p_id and processed_at is null;
$$;

-- Deletes finished rows after their retention period (bounded per call).
create or replace function prune_notification_outbox(
  p_processed_after interval default interval '7 days',
  p_failed_after    interval default interval '14 days'
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_count integer;
begin
  with doomed as (
    select id from notification_outbox
    where (processed_at is not null and processed_at < now() - p_processed_after)
       or (failed_at is not null and failed_at < now() - p_failed_after)
    limit 1000
  )
  delete from notification_outbox o
  using doomed
  where o.id = doomed.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function claim_notification_outbox(integer, interval, integer)
  from public, anon, authenticated;
revoke all on function complete_notification(uuid) from public, anon, authenticated;
revoke all on function fail_notification(uuid, boolean, integer)
  from public, anon, authenticated;
revoke all on function prune_notification_outbox(interval, interval)
  from public, anon, authenticated;
grant execute on function claim_notification_outbox(integer, interval, integer) to service_role;
grant execute on function complete_notification(uuid) to service_role;
grant execute on function fail_notification(uuid, boolean, integer) to service_role;
grant execute on function prune_notification_outbox(interval, interval) to service_role;
