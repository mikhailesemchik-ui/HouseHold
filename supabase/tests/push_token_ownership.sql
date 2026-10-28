-- ============================================================
-- Push token ownership and outbox tests (migration 20261108000001)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/push_token_ownership.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back. Real concurrency is covered by
-- push_token_ownership_concurrency.sh.
-- ============================================================

BEGIN;

CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN RAISE NOTICE '% PASS', p_name;
  ELSE RAISE EXCEPTION '% FAIL: %', p_name, p_detail; END IF;
END $$;

CREATE FUNCTION pg_temp.as_user(p uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p, 'role', 'authenticated')::text, true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;

CREATE FUNCTION pg_temp.as_nobody() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;

CREATE FUNCTION pg_temp.as_anon() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE anon';
END $$;

CREATE FUNCTION pg_temp.as_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE service_role';
END $$;

CREATE FUNCTION pg_temp.as_admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE 'RESET ROLE'; END $$;

-- Evaluates an expression; a void result reads as 'ok', an error as 'err:<SQLSTATE>'.
CREATE FUNCTION pg_temp.val(p_expr text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE 'select (' || p_expr || ')::text' INTO v;
  RETURN coalesce(nullif(v, ''), 'ok');
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

CREATE FUNCTION pg_temp.rows(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n::text;
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

-- A well formed token for tests: 'tok' + a tag, padded to 40 characters.
CREATE FUNCTION pg_temp.tok(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT rpad('tok' || p, 40, 'x')
$$;

-- Owners of a token as a stable string (read as the table owner).
CREATE FUNCTION pg_temp.owners(p_token text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(right(user_id::text, 2), ',' ORDER BY user_id), '-')
  FROM device_push_tokens WHERE token = p_token
$$;

DO $$
DECLARE
  a  uuid := 'fd000000-0000-0000-0000-00000000000a';
  b  uuid := 'fd000000-0000-0000-0000-00000000000b';
  c  uuid := 'fd000000-0000-0000-0000-00000000000c';
  d  uuid := 'fd000000-0000-0000-0000-00000000000d'; -- deleting
  e  uuid := 'fd000000-0000-0000-0000-00000000000e'; -- no profile
  t1 text := pg_temp.tok('1');
  t2 text := pg_temp.tok('2');
  t3 text := pg_temp.tok('3');
  t4 text := pg_temp.tok('4');
  r text; n1 uuid; n2 uuid; n3 uuid;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'push'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(d,4),(e,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'PUSH-'||i,'Push'||i FROM (VALUES (a,1),(b,2),(c,3)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  VALUES (d,'PUSH-4','Push4','deleting',now());

  -- 1-2. Registration and idempotency
  PERFORM pg_temp.as_user(a);
  r := pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android'));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T1 an active user registers a token',
    r = 'ok' AND pg_temp.owners(t1) = '0a'
    AND (SELECT platform FROM device_push_tokens WHERE token = t1) = 'android');
  -- an aged registration (inserted directly: the update trigger would reset it)
  INSERT INTO device_push_tokens (user_id,token,platform,updated_at)
  VALUES (a, pg_temp.tok('5'), 'android', now() - interval '30 days');
  PERFORM pg_temp.as_user(a);
  PERFORM register_device_push_token(t1, 'android');
  PERFORM register_device_push_token(t1, 'android');
  PERFORM register_device_push_token(pg_temp.tok('5'), 'android');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T2 registering again is idempotent: one row, and the registration is refreshed',
    (SELECT count(*) FROM device_push_tokens WHERE token = t1) = 1
    AND (SELECT count(*) FROM device_push_tokens WHERE token = pg_temp.tok('5')) = 1
    AND (SELECT updated_at > now() - interval '1 minute' FROM device_push_tokens WHERE token = pg_temp.tok('5')));

  -- 3. Cross-account: the token moves to the caller, nothing is duplicated
  PERFORM pg_temp.as_user(b);
  PERFORM register_device_push_token(t1, 'android');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T3 a token has one owner: a registration by B moves it away from A',
    pg_temp.owners(t1) = '0b'
    AND NOT EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = a AND token = t1));

  -- 4. A new account that did NOT opt in still releases the stale owner
  PERFORM pg_temp.as_user(a);
  PERFORM register_device_push_token(t2, 'android');
  PERFORM pg_temp.as_user(c);
  r := pg_temp.val(format('register_device_push_token(%L,%L,false)', t2, 'android'));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T4 a non-opted-in account releases the stale owner and registers nothing',
    r = 'ok' AND pg_temp.owners(t2) = '-'
    AND NOT EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = c));

  -- 5. Two devices of one user: releasing one token never touches the other
  PERFORM pg_temp.as_user(a);
  PERFORM register_device_push_token(t2, 'android');
  PERFORM register_device_push_token(t3, 'ios');
  PERFORM pg_temp.as_user(b);
  PERFORM register_device_push_token(t2, 'android');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T5 the same user''s other device keeps its registration',
    pg_temp.owners(t3) = '0a' AND pg_temp.owners(t2) = '0b'
    AND (SELECT platform FROM device_push_tokens WHERE token = t3) = 'ios');

  -- 6. Same-user rotation: the owner removes the old row, nothing else moves
  PERFORM pg_temp.as_user(a);
  PERFORM register_device_push_token(t4, 'ios');
  PERFORM pg_temp.check('T6 the owner can remove their old token directly (rotation)',
    pg_temp.rows(format('delete from device_push_tokens where token = %L', t3)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T6b ... and only that one',
    pg_temp.owners(t3) = '-' AND pg_temp.owners(t4) = '0a' AND pg_temp.owners(t2) = '0b');

  -- 7. Malicious claim: bounded, silent and identical for every token
  PERFORM pg_temp.as_user(c);
  r := pg_temp.val(format('register_device_push_token(%L,%L,false)', t4, 'ios'));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T7 a caller who knows a token can release it from its owner (documented limit), but only that exact token',
    r = 'ok' AND pg_temp.owners(t4) = '-' AND pg_temp.owners(t2) = '0b');
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('T7b the answer is the same for an unknown token (no ownership oracle)',
    pg_temp.val(format('register_device_push_token(%L,%L,false)', pg_temp.tok('zz'), 'ios')) = r);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T7c the claim registered nothing for the caller',
    NOT EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = c));

  -- 8. Unauthorized callers
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.check('T8 anon cannot call it',
    pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android')) = 'err:42501');
  PERFORM pg_temp.as_nobody();
  PERFORM pg_temp.check('T8b an authenticated role without a user is refused',
    pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android')) = 'err:HO000');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T8c EXECUTE is granted to authenticated only',
    has_function_privilege('authenticated','register_device_push_token(text,text,boolean)','EXECUTE')
    AND NOT has_function_privilege('anon','register_device_push_token(text,text,boolean)','EXECUTE')
    AND NOT has_function_privilege('public','register_device_push_token(text,text,boolean)','EXECUTE'));
  PERFORM pg_temp.check('T8d the function takes no user id and pins its search_path',
    pg_get_function_arguments('register_device_push_token(text,text,boolean)'::regprocedure) NOT ILIKE '%user%'
    AND (SELECT proconfig FROM pg_proc WHERE oid = 'register_device_push_token(text,text,boolean)'::regprocedure)
        = array['search_path=public']);

  -- 9. Inactive accounts
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('T9 a deleting account cannot register or even release',
    pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android')) = 'err:AD003'
    AND pg_temp.val(format('register_device_push_token(%L,%L,false)', t2, 'android')) = 'err:AD003');
  PERFORM pg_temp.as_user(e);
  PERFORM pg_temp.check('T9b a user without a profile is refused',
    pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android')) = 'err:AD003');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T9c nothing changed for B by those refusals',
    pg_temp.owners(t2) = '0b' AND pg_temp.owners(t1) = '0b');

  -- 10. Input validation
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('T10 invalid tokens and platforms are refused',
    pg_temp.val(format('register_device_push_token(%L,%L)', 'short', 'android')) = 'err:PT002'
    AND pg_temp.val(format('register_device_push_token(%L,%L)', t1 || ' x', 'android')) = 'err:PT002'
    AND pg_temp.val(format('register_device_push_token(%L,%L)', t1 || E'\n', 'android')) = 'err:PT002'
    AND pg_temp.val(format('register_device_push_token(%L,%L)', t1 || '''', 'android')) = 'err:PT002'
    AND pg_temp.val(format('register_device_push_token(%L,%L)', repeat('a', 5000), 'android')) = 'err:PT002'
    AND pg_temp.val('register_device_push_token(null::text,''android'')') = 'err:PT002'
    AND pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'windows')) = 'err:PT001'
    AND pg_temp.val(format('register_device_push_token(%L,null::text)', t1)) = 'err:PT001');
  PERFORM pg_temp.check('T10b surrounding spaces are tolerated and trimmed',
    pg_temp.val(format('register_device_push_token(%L,%L)', '  ' || t1 || '  ', 'android')) = 'ok');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T10c ... and stored without them',
    pg_temp.owners(t1) = '0a');

  -- 11. Direct table access (deployed clients) cannot create a second owner
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('T11 a direct insert of an unowned token still works (old clients)',
    pg_temp.rows(format('insert into device_push_tokens (user_id,token,platform) values (%L,%L,''android'')', c, pg_temp.tok('9'))) = '1');
  PERFORM pg_temp.check('T11b a direct insert of a token owned by someone else is refused, not duplicated',
    pg_temp.rows(format('insert into device_push_tokens (user_id,token,platform) values (%L,%L,''android'')', c, t2)) = 'err:23505');
  PERFORM pg_temp.check('T11c the old client''s upsert form cannot take it either',
    pg_temp.rows(format('insert into device_push_tokens (user_id,token,platform) values (%L,%L,''android'') on conflict (user_id,token) do update set platform = excluded.platform', c, t2)) = 'err:23505');
  PERFORM pg_temp.check('T11d a direct insert for another user is refused by row level security',
    pg_temp.rows(format('insert into device_push_tokens (user_id,token,platform) values (%L,%L,''android'')', a, pg_temp.tok('8'))) = 'err:42501');
  PERFORM pg_temp.check('T11e re-pointing one''s own row at another user''s token is refused',
    pg_temp.rows(format('update device_push_tokens set token = %L where user_id = %L', t2, c)) = 'err:23505');
  PERFORM pg_temp.check('T11f a user cannot move a row to another user',
    pg_temp.rows(format('update device_push_tokens set user_id = %L where user_id = %L', a, c)) = 'err:42501');
  PERFORM pg_temp.check('T11g a user sees only their own rows and cannot delete others''',
    (SELECT count(*) FROM device_push_tokens) = 1
    AND pg_temp.rows(format('delete from device_push_tokens where token = %L', t2)) = '0');
  PERFORM pg_temp.as_admin();

  -- 12. The database itself refuses duplicates, whoever writes
  PERFORM pg_temp.check('T12 even the table owner cannot store one token for two users',
    pg_temp.rows(format('insert into device_push_tokens (user_id,token,platform) values (%L,%L,''android'')', a, t2)) = 'err:23505');

  -- 13. The migration's cleanup policy for pre-existing duplicates
  ALTER TABLE device_push_tokens DROP CONSTRAINT device_push_tokens_token_unique;
  DELETE FROM device_push_tokens;
  INSERT INTO device_push_tokens (user_id,token,platform,updated_at) VALUES
    (a, t1, 'android', now() - interval '3 days'),
    (b, t1, 'android', now() - interval '1 day'),
    (c, t1, 'android', now() - interval '2 days'),
    (a, t2, 'android', now()),
    (a, t3, 'ios', now());
  WITH ranked AS (
    SELECT id, row_number() OVER (PARTITION BY token ORDER BY updated_at DESC, id DESC) AS position
    FROM device_push_tokens)
  DELETE FROM device_push_tokens t USING ranked r WHERE t.id = r.id AND r.position > 1;
  PERFORM pg_temp.check('T13 duplicates keep the freshest registration; unrelated tokens are preserved',
    pg_temp.owners(t1) = '0b' AND pg_temp.owners(t2) = '0a' AND pg_temp.owners(t3) = '0a'
    AND (SELECT count(*) FROM device_push_tokens) = 3);
  ALTER TABLE device_push_tokens ADD CONSTRAINT device_push_tokens_token_unique UNIQUE (token);

  -- 14. Account deletion removes the tokens and blocks new ones
  DELETE FROM device_push_tokens;
  PERFORM pg_temp.as_user(a); PERFORM register_device_push_token(t1, 'android');
  PERFORM pg_temp.as_user(b); PERFORM register_device_push_token(t2, 'android');
  PERFORM pg_temp.as_service();
  PERFORM begin_account_deletion(a);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T14 deleting an account removes its tokens and only its tokens',
    NOT EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = a)
    AND pg_temp.owners(t2) = '0b');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('T14b ... and the deleting account cannot register again',
    pg_temp.val(format('register_device_push_token(%L,%L)', t1, 'android')) = 'err:AD003');
  PERFORM pg_temp.as_admin();

  -- 15. Outbox functions: service role only
  PERFORM pg_temp.check('T15 outbox helpers are executable by service_role only',
    has_function_privilege('service_role','claim_notification_outbox(integer,interval,integer)','EXECUTE')
    AND has_function_privilege('service_role','complete_notification(uuid)','EXECUTE')
    AND has_function_privilege('service_role','fail_notification(uuid,boolean,integer)','EXECUTE')
    AND has_function_privilege('service_role','prune_notification_outbox(interval,interval)','EXECUTE')
    AND NOT has_function_privilege('authenticated','claim_notification_outbox(integer,interval,integer)','EXECUTE')
    AND NOT has_function_privilege('authenticated','complete_notification(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','fail_notification(uuid,boolean,integer)','EXECUTE')
    AND NOT has_function_privilege('authenticated','prune_notification_outbox(interval,interval)','EXECUTE')
    AND NOT has_function_privilege('anon','claim_notification_outbox(integer,interval,integer)','EXECUTE')
    AND NOT has_function_privilege('public','claim_notification_outbox(integer,interval,integer)','EXECUTE'));
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('T15b a signed-in user cannot read or claim the outbox',
    pg_temp.val('(select count(*) from notification_outbox)') = 'err:42501'
    AND pg_temp.val('(select count(*) from claim_notification_outbox(5))') = 'err:42501');
  PERFORM pg_temp.as_admin();

  -- 16. Outbox claim, lease, retry, give-up
  INSERT INTO notification_outbox (recipient_user_id, type, title, body, payload, created_at)
  VALUES (b, 'zz_test', 'Private title', 'Private body about Home', '{"type":"zz","householdId":"h"}', now() - interval '1 hour')
  RETURNING id INTO n1;
  INSERT INTO notification_outbox (recipient_user_id, type, title, body, created_at)
  VALUES (b, 'zz_test', 'Other', 'Other', now() - interval '59 minutes') RETURNING id INTO n2;
  PERFORM pg_temp.as_service();
  r := pg_temp.val(format('(select count(*) from claim_notification_outbox(50) c where c.id in (%L,%L))', n1, n2));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T16 a claim returns the pending rows and counts the attempt',
    r = '2' AND (SELECT attempt_count FROM notification_outbox WHERE id = n1) = 1
    AND (SELECT claimed_at IS NOT NULL FROM notification_outbox WHERE id = n1));
  PERFORM pg_temp.check('T16b the claim result does not expose the notification text',
    NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) AS arg(name)
                WHERE p.oid = 'claim_notification_outbox(integer,interval,integer)'::regprocedure
                  AND arg.name IN ('title','body')));
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('T16c a second claim does not hand out leased rows',
    pg_temp.val(format('(select count(*) from claim_notification_outbox(50) c where c.id in (%L,%L))', n1, n2)) = '0');
  PERFORM pg_temp.as_admin();
  UPDATE notification_outbox SET claimed_at = now() - interval '10 minutes' WHERE id = n1;  -- a crashed worker
  PERFORM pg_temp.as_service();
  r := pg_temp.val(format('(select count(*) from claim_notification_outbox(50) c where c.id = %L)', n1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T16d a crashed worker''s lease expires and the row is claimable again',
    r = '1' AND (SELECT attempt_count FROM notification_outbox WHERE id = n1) = 2);
  PERFORM pg_temp.as_service();
  PERFORM complete_notification(n1);
  PERFORM fail_notification(n2);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T16e success is recorded; a retryable failure is released for the next run',
    (SELECT processed_at IS NOT NULL AND claimed_at IS NULL FROM notification_outbox WHERE id = n1)
    AND (SELECT processed_at IS NULL AND claimed_at IS NULL AND failed_at IS NULL FROM notification_outbox WHERE id = n2));
  UPDATE notification_outbox SET attempt_count = 4, claimed_at = NULL WHERE id = n2;
  PERFORM pg_temp.as_service();
  PERFORM claim_notification_outbox(50);       -- the fifth attempt
  PERFORM fail_notification(n2);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T16f retries are bounded: the fifth failed attempt closes the row for good',
    (SELECT failed_at IS NOT NULL AND attempt_count = 5 FROM notification_outbox WHERE id = n2));
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('T16g a closed row is never handed out again',
    pg_temp.val(format('(select count(*) from claim_notification_outbox(50) c where c.id = %L)', n2)) = '0');
  PERFORM pg_temp.as_admin();
  INSERT INTO notification_outbox (recipient_user_id, type, title, body)
  VALUES (b, 'zz_test', 'P', 'P') RETURNING id INTO n3;
  PERFORM pg_temp.as_service();
  PERFORM claim_notification_outbox(50);
  PERFORM fail_notification(n3, true);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T16h a permanent failure closes the row after one attempt',
    (SELECT failed_at IS NOT NULL AND attempt_count = 1 FROM notification_outbox WHERE id = n3));

  -- 17. Retention
  INSERT INTO notification_outbox (recipient_user_id, type, title, body)
  VALUES (b, 'zz_test', 'Pending', 'Pending') RETURNING id INTO n3;
  UPDATE notification_outbox SET processed_at = now() - interval '8 days' WHERE id = n1;
  UPDATE notification_outbox SET failed_at = now() - interval '15 days' WHERE id = n2;
  PERFORM pg_temp.as_service();
  r := pg_temp.val('prune_notification_outbox()');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T17 finished rows are deleted after their retention; pending rows stay',
    r::int >= 2 AND NOT EXISTS (SELECT 1 FROM notification_outbox WHERE id IN (n1, n2))
    AND EXISTS (SELECT 1 FROM notification_outbox WHERE id = n3));
END $$;

ROLLBACK;
