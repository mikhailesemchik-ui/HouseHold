-- ============================================================
-- Deletion-code attempt limiter tests (migration 20261109000001)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/deletion_code_attempts.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back. Windows are aged by editing rows as
-- the table owner, so no test needs a clock change or a 15-minute wait and no
-- test-only bypass exists in the function. Parallel behavior is covered by
-- deletion_code_attempts_concurrency.sh.
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

-- Reserves an attempt as the CURRENT role: 't', 'f:<seconds>' or 'err:<SQLSTATE>'.
CREATE FUNCTION pg_temp.reserve(p_user text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  EXECUTE format('select * from reserve_deletion_code_attempt(%s)', p_user) INTO r;
  RETURN CASE WHEN r.allowed THEN 't' ELSE 'f:' || r.retry_after_seconds END;
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

-- Runs a statement as the CURRENT role: 'ok' or 'err:<SQLSTATE>'.
CREATE FUNCTION pg_temp.run(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

CREATE FUNCTION pg_temp.attempts(p_user uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT coalesce((SELECT attempt_count FROM deletion_code_attempts WHERE user_id = p_user), 0)
$$;

DO $$
DECLARE
  a uuid := 'fe000000-0000-0000-0000-00000000000a';
  b uuid := 'fe000000-0000-0000-0000-00000000000b';
  c uuid := 'fe000000-0000-0000-0000-00000000000c';
  d uuid := 'fe000000-0000-0000-0000-00000000000d'; -- profile is 'deleting'
  e uuid := 'fe000000-0000-0000-0000-00000000000e'; -- no profile
  gone uuid := 'fe000000-0000-0000-0000-0000000000ff'; -- not an Auth user
  r text; w1 timestamptz; w2 timestamptz; n int; ok boolean;
  profiles_before text; profiles_after text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'dca'||i||'@test.local','authenticated','authenticated',now(),now(),false
  FROM (VALUES (a,1),(b,2),(c,3),(d,4),(e,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'DCA-'||i,'Dca'||i FROM (VALUES (a,1),(b,2),(c,3)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  VALUES (d,'DCA-4','Dca4','deleting',now());

  -- Roles and privileges first, while there is no state to confuse them.
  PERFORM pg_temp.as_anon();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T1 anon cannot call the function', r = 'err:42501', r);

  PERFORM pg_temp.as_user(a);
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T2 an authenticated user cannot call it, not even for themselves',
    r = 'err:42501' AND pg_temp.attempts(a) = 0, r);

  PERFORM pg_temp.check('T3 PUBLIC has no EXECUTE and only service_role holds it',
    NOT EXISTS (
      SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
      WHERE p.proname = 'reserve_deletion_code_attempt' AND x.grantee = 0)
    AND (SELECT array_agg(pg_get_userbyid(x.grantee) ORDER BY pg_get_userbyid(x.grantee))
         FROM pg_proc p, aclexplode(p.proacl) x
         WHERE p.proname = 'reserve_deletion_code_attempt'
           AND pg_get_userbyid(x.grantee) <> 'postgres')
        = ARRAY['service_role']::name[]);

  PERFORM pg_temp.check('T4 the function is SECURITY DEFINER with a pinned search_path',
    (SELECT prosecdef AND proconfig @> ARRAY['search_path=public']
     FROM pg_proc WHERE proname = 'reserve_deletion_code_attempt'));

  ok := true;
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', r);
    ok := ok AND pg_temp.run('select * from deletion_code_attempts') = 'err:42501'
             AND pg_temp.run(format('insert into deletion_code_attempts(user_id,attempt_count) values (%L,1)', a)) = 'err:42501'
             AND pg_temp.run('update deletion_code_attempts set attempt_count = 1') = 'err:42501'
             AND pg_temp.run('delete from deletion_code_attempts') = 'err:42501';
    EXECUTE 'RESET ROLE';
  END LOOP;
  PERFORM pg_temp.check('T5 anon, authenticated and service_role cannot read or write the table', ok);

  -- The service role (what the Edge Function uses) can reserve.
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T6 the service role can reserve; the first attempt is allowed',
    r = 't' AND pg_temp.attempts(a) = 1, r);

  -- Five allowed, the sixth refused.
  PERFORM pg_temp.as_service();
  FOR n IN 2..5 LOOP
    r := pg_temp.reserve(quote_literal(a));
    IF r <> 't' THEN RAISE EXCEPTION 'T7 FAIL: attempt % gave %', n, r; END IF;
  END LOOP;
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T7 five submissions are allowed in the window', pg_temp.attempts(a) = 5);

  SELECT window_started_at INTO w1 FROM deletion_code_attempts WHERE user_id = a;
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  SELECT window_started_at INTO w2 FROM deletion_code_attempts WHERE user_id = a;
  PERFORM pg_temp.check('T8 the sixth is refused with a sane retry time, and changes nothing',
    r ~ '^f:[0-9]+$' AND split_part(r, ':', 2)::int BETWEEN 1 AND 900
    AND pg_temp.attempts(a) = 5 AND w1 = w2, r);

  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T9 further refusals neither raise the count nor move the window',
    r ~ '^f:' AND pg_temp.attempts(a) = 5
    AND (SELECT window_started_at FROM deletion_code_attempts WHERE user_id = a) = w1);

  -- Another user is independent.
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(b));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T10 a different user has an independent limit',
    r = 't' AND pg_temp.attempts(b) = 1 AND pg_temp.attempts(a) = 5, r);

  -- Window mechanics, with the window aged by the table owner.
  UPDATE deletion_code_attempts SET window_started_at = now() - interval '14 minutes' WHERE user_id = b;
  SELECT window_started_at INTO w1 FROM deletion_code_attempts WHERE user_id = b;
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(b));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T11 use inside the window counts but does not extend it',
    r = 't' AND pg_temp.attempts(b) = 2
    AND (SELECT window_started_at FROM deletion_code_attempts WHERE user_id = b) = w1);

  UPDATE deletion_code_attempts SET window_started_at = now() - interval '16 minutes' WHERE user_id = a;
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T12 once the window has passed, access returns by itself with a fresh window',
    r = 't' AND pg_temp.attempts(a) = 1
    AND (SELECT window_started_at FROM deletion_code_attempts WHERE user_id = a) > now() - interval '1 minute', r);

  UPDATE deletion_code_attempts SET attempt_count = 5, window_started_at = now() - interval '899 seconds' WHERE user_id = a;
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T13 just before the window ends the user is still refused',
    r ~ '^f:' AND split_part(r, ':', 2)::int BETWEEN 1 AND 5, r);

  -- Invalid input fails closed.
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('T14 a null user id is refused', pg_temp.reserve('null::uuid') = 'err:DC000');
  PERFORM pg_temp.check('T15 an unknown user id is refused, not recorded',
    pg_temp.reserve(quote_literal(gone)) = 'err:23503');
  PERFORM pg_temp.check('T16 a malformed id is refused', pg_temp.reserve($q$'not-a-uuid'$q$) = 'err:22P02');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T17 nothing was stored for invalid ids',
    NOT EXISTS (SELECT 1 FROM deletion_code_attempts WHERE user_id = gone));

  -- The cap is also a table constraint.
  PERFORM pg_temp.check('T18 the table itself refuses a count above the cap',
    pg_temp.run(format('update deletion_code_attempts set attempt_count = 6 where user_id = %L', a)) = 'err:23514'
    AND pg_temp.run(format('insert into deletion_code_attempts(user_id,attempt_count) values (%L,0)', c)) = 'err:23514');

  -- Pruning and growth.
  INSERT INTO deletion_code_attempts (user_id, window_started_at, attempt_count)
  VALUES (c, now() - interval '2 days', 3);
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(b));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('T19 rows idle for a day are pruned; the caller and fresh rows are kept',
    NOT EXISTS (SELECT 1 FROM deletion_code_attempts WHERE user_id = c)
    AND EXISTS (SELECT 1 FROM deletion_code_attempts WHERE user_id = a)
    AND EXISTS (SELECT 1 FROM deletion_code_attempts WHERE user_id = b), r);

  -- Deleting profiles keep working, financial tombstone data is untouched.
  SELECT string_agg(user_id::text || account_state || coalesce(public_id,''), ',' ORDER BY user_id)
    INTO profiles_before FROM profiles WHERE user_id::text LIKE 'fe000000%';
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(d));
  PERFORM pg_temp.as_admin();
  SELECT string_agg(user_id::text || account_state || coalesce(public_id,''), ',' ORDER BY user_id)
    INTO profiles_after FROM profiles WHERE user_id::text LIKE 'fe000000%';
  PERFORM pg_temp.check('T20 a deleting account is handled and no profile changes',
    r = 't' AND profiles_before = profiles_after, r);

  -- The row goes with the Auth user.
  PERFORM pg_temp.as_service();
  r := pg_temp.reserve(quote_literal(e));
  PERFORM pg_temp.as_admin();
  DELETE FROM auth.users WHERE id = e;
  PERFORM pg_temp.check('T21 deleting the Auth user removes its attempt row',
    r = 't' AND NOT EXISTS (SELECT 1 FROM deletion_code_attempts WHERE user_id = e), r);

  RAISE NOTICE 'ALL DELETION CODE ATTEMPT TESTS PASSED';
END $$;

ROLLBACK;
