-- ============================================================
-- Account reconciliation tests (migration 20261107000001, finding F7B)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/account_reconciliation.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back. Real overlap between sessions and the
-- pg_cron schedule are covered by the separate shell scripts.
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

CREATE FUNCTION pg_temp.as_admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE 'RESET ROLE'; END $$;

CREATE FUNCTION pg_temp.as_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE service_role';
END $$;

CREATE FUNCTION pg_temp.as_anon() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  EXECUTE 'RESET ROLE';
  EXECUTE 'SET LOCAL ROLE anon';
END $$;

CREATE FUNCTION pg_temp.val(p_expr text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE 'select (' || p_expr || ')::text' INTO v;
  RETURN v;
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

CREATE FUNCTION pg_temp.bal(p_h uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  select coalesce(string_agg(u::text || ':' || n, ',' order by u), '') from (
    select u, sum(n) n from (
      select paid_by u, amount_cents n from expenses where household_id = p_h
      union all select user_id, -share_cents from expense_participants
        where expense_id in (select id from expenses where household_id = p_h)
      union all select from_user_id, amount_cents from expense_settlements where household_id = p_h
      union all select to_user_id, -amount_cents from expense_settlements where household_id = p_h
    ) t group by u) z
$$;

DO $$
DECLARE
  o  uuid := 'fe000000-0000-0000-0000-000000000001'; -- household owner, stays active
  a  uuid := 'fe000000-0000-0000-0000-000000000002'; -- full deletion flow
  u1 uuid := 'fe000000-0000-0000-0000-000000000011'; -- deleting, Auth gone
  u2 uuid := 'fe000000-0000-0000-0000-000000000012'; -- deleting, Auth present
  u3 uuid := 'fe000000-0000-0000-0000-000000000013'; -- active, Auth gone
  u4 uuid := 'fe000000-0000-0000-0000-000000000014'; -- already deleted
  u5 uuid := 'fe000000-0000-0000-0000-000000000015'; -- finalization fails
  u6 uuid := 'fe000000-0000-0000-0000-000000000016';
  u7 uuid := 'fe000000-0000-0000-0000-000000000017';
  h uuid; hz uuid; code text; ex uuid; sx uuid; e1 uuid; late uuid;
  r text; bal text; t4 timestamptz; n integer;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'rec'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (o,1),(a,2),(u2,3)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'REC-'||i,'Rec'||i FROM (VALUES (o,1),(a,2),(u3,3)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  VALUES (u1,'REC-U1','Real Name','deleting',now()),
         (u2,'REC-U2','Real Name','deleting',now());
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deleted_at)
  VALUES (u4,'DELETED-0123456789abcdef0123456789abcdef','Deleted member','deleted',now() - interval '1 day');
  t4 := (SELECT deleted_at FROM profiles WHERE user_id = u4);

  -- A late write by u1 that no earlier scrub pass has seen
  PERFORM pg_temp.as_user(o); SELECT id INTO h FROM create_household('REC H');
  PERFORM pg_temp.as_admin();
  INSERT INTO expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
    VALUES (h,'Late',700,'EUR',u1,'Late Name',u1) RETURNING id INTO late;
  INSERT INTO expense_participants (expense_id,user_id,display_name,share_cents)
    VALUES (late,u1,'Late Name',700);

  PERFORM pg_temp.as_service();
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R1 an account with no Auth user is finalized',
    r = '1' AND (SELECT account_state FROM profiles WHERE user_id = u1) = 'deleted'
    AND (SELECT deleted_at IS NOT NULL FROM profiles WHERE user_id = u1));
  PERFORM pg_temp.check('R2 an account whose Auth user still exists is not finalized',
    (SELECT account_state FROM profiles WHERE user_id = u2) = 'deleting'
    AND EXISTS (SELECT 1 FROM auth.users WHERE id = u2));
  PERFORM pg_temp.check('R3 active profiles are untouched, even with no Auth user',
    (SELECT account_state FROM profiles WHERE user_id = u3) = 'active'
    AND (SELECT account_state FROM profiles WHERE user_id IN (o, a) GROUP BY account_state) = 'active'
    AND (SELECT display_name FROM profiles WHERE user_id = u3) = 'Rec3');
  PERFORM pg_temp.check('R4 an already deleted profile is untouched',
    (SELECT deleted_at FROM profiles WHERE user_id = u4) = t4);
  PERFORM pg_temp.check('R5 the final scrub pass ran (late write, name, tombstone id)',
    (SELECT paid_by_display_name FROM expenses WHERE id = late) = 'Deleted member'
    AND (SELECT display_name FROM expense_participants WHERE expense_id = late) = 'Deleted member'
    AND (SELECT amount_cents FROM expenses WHERE id = late) = 700
    AND (SELECT display_name = 'Deleted member' AND public_id ~ '^DELETED-[0-9a-f]{32}$'
         FROM profiles WHERE user_id = u1));
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('R6 a second reconciliation changes nothing',
    pg_temp.val('reconcile_account_deletions()') = '0');

  -- Health counts: u2 has its Auth user, u5 / u6 do not
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  VALUES (u5,'REC-U5','Five','deleting',now() - interval '2 hours'),
         (u6,'REC-U6','Six','deleting',now() - interval '1 hour');
  PERFORM pg_temp.check('R7 health reports finalizable and auth-present accounts separately',
    (SELECT finalizable_count = 2 AND auth_present_count = 1
        AND oldest_finalizable_at = now() - interval '2 hours'
     FROM account_deletion_health()));

  -- One failing account does not block the others
  PERFORM pg_temp.as_admin();
  CREATE FUNCTION pg_temp.fail_u5() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN
    IF new.user_id = 'fe000000-0000-0000-0000-000000000015'::uuid
       AND new.account_state = 'deleted' THEN
      RAISE EXCEPTION 'boom for test' USING errcode = 'XX555';
    END IF;
    RETURN new;
  END $f$;
  CREATE TRIGGER fail_u5 BEFORE UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_u5();
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  VALUES (u7,'REC-U7','Seven','deleting',now());
  PERFORM pg_temp.as_service();
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R8 one failing account is skipped; the others are finalized',
    r = '2'
    AND (SELECT account_state FROM profiles WHERE user_id = u5) = 'deleting'
    AND (SELECT account_state FROM profiles WHERE user_id = u6) = 'deleted'
    AND (SELECT account_state FROM profiles WHERE user_id = u7) = 'deleted');
  PERFORM pg_temp.check('R8b the failed account was rolled back, not half scrubbed or half closed',
    (SELECT deleted_at IS NULL FROM profiles WHERE user_id = u5));
  DROP TRIGGER fail_u5 ON profiles;
  PERFORM pg_temp.as_service();
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.check('R8c once the fault is gone the account is retried and finalized',
    r = '1' AND (SELECT account_state FROM profiles WHERE user_id = u5) = 'deleted');

  -- Batch limit
  PERFORM pg_temp.as_admin();
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  SELECT gen_random_uuid(),'BATCH-'||i,'B'||i,'deleting',now() - (i || ' minutes')::interval
  FROM generate_series(1,105) i;
  PERFORM pg_temp.as_service();
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R9 a run finalizes at most 100 accounts, oldest requests first',
    r = '100'
    AND (SELECT count(*) FROM profiles WHERE public_id LIKE 'BATCH-%' AND account_state = 'deleting') = 5
    AND (SELECT count(*) FROM profiles WHERE display_name ~ '^B[0-9]+$' AND account_state = 'deleting') = 5
    AND (SELECT min(deletion_requested_at) FROM profiles WHERE display_name ~ '^B[0-9]+$' AND account_state = 'deleting')
        > now() - interval '6 minutes');
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('R10 the remaining accounts are handled by the next run, then nothing is left',
    pg_temp.val('reconcile_account_deletions()') = '5'
    AND pg_temp.val('reconcile_account_deletions()') = '0');

  -- Normal flow end to end, with financial history
  PERFORM pg_temp.as_user(o);
  SELECT hi.code INTO code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(a); PERFORM join_household_by_invite(code);
  e1 := create_equal_split_expense(h,'Dinner',3000,'EUR',a,array[a,o]);
  ex := create_equal_split_expense(h,'Cancelled',1000,'EUR',a,array[a,o]);
  sx := (create_settlement(h,a,o,200,'EUR')).id;
  PERFORM cancel_expense(ex, 'mine'); PERFORM cancel_settlement(sx, 'mine too');
  PERFORM pg_temp.as_admin();
  bal := pg_temp.bal(h);
  PERFORM pg_temp.as_service();
  PERFORM begin_account_deletion(a);
  PERFORM pg_temp.as_admin();
  DELETE FROM auth.users WHERE id = a;
  PERFORM pg_temp.as_service();
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R11 a normally started deletion is closed by reconciliation, history intact',
    r = '1' AND (SELECT account_state FROM profiles WHERE user_id = a) = 'deleted'
    AND pg_temp.bal(h) = bal
    AND (SELECT snapshot->>'amount_cents' FROM financial_archive WHERE record_id = ex) = '1000'
    AND (SELECT snapshot->>'paid_by_display_name' FROM financial_archive WHERE record_id = ex) = 'Deleted member'
    AND EXISTS (SELECT 1 FROM expenses WHERE paid_by = a));
  PERFORM pg_temp.as_user(o);
  PERFORM pg_temp.check('R12 the F4 archive stays append-only for clients',
    pg_temp.rows(format($q$update financial_archive set canceled_by_name = 'x' where household_id = %L$q$, h)) LIKE 'err:%'
    AND pg_temp.rows(format($q$delete from financial_archive where household_id = %L$q$, h)) LIKE 'err:%');
  PERFORM delete_household(h);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R13 F7A household deletion still works afterwards',
    NOT EXISTS (SELECT 1 FROM households WHERE id = h)
    AND NOT EXISTS (SELECT 1 FROM financial_archive WHERE household_id = h)
    AND EXISTS (SELECT 1 FROM profiles WHERE user_id = a AND account_state = 'deleted'));

  -- Privileges
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R14 only service_role (and the owner) may reconcile or read health',
    pg_get_function_arguments('reconcile_account_deletions()'::regprocedure) = ''
    AND has_function_privilege('service_role','reconcile_account_deletions()','EXECUTE')
    AND has_function_privilege('service_role','account_deletion_health()','EXECUTE')
    AND NOT has_function_privilege('authenticated','reconcile_account_deletions()','EXECUTE')
    AND NOT has_function_privilege('anon','reconcile_account_deletions()','EXECUTE')
    AND NOT has_function_privilege('public','reconcile_account_deletions()','EXECUTE')
    AND NOT has_function_privilege('authenticated','account_deletion_health()','EXECUTE')
    AND NOT has_function_privilege('anon','account_deletion_health()','EXECUTE')
    AND NOT has_function_privilege('public','account_deletion_health()','EXECUTE')
    AND NOT has_function_privilege('authenticated','begin_account_deletion(uuid)','EXECUTE')
    AND (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'reconcile_account_deletions()'::regprocedure) = 'postgres'
    AND (SELECT prosecdef FROM pg_proc WHERE oid = 'reconcile_account_deletions()'::regprocedure)
    AND (SELECT proconfig FROM pg_proc WHERE oid = 'reconcile_account_deletions()'::regprocedure) = array['search_path=public']);
  INSERT INTO profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
    VALUES ('fe000000-0000-0000-0000-000000000099','REC-Z','Z','deleting',now());
  PERFORM pg_temp.as_user(o);
  PERFORM pg_temp.check('R15 an authenticated user cannot reconcile or read health',
    pg_temp.val('reconcile_account_deletions()') = 'err:42501'
    AND pg_temp.val('account_deletion_health()') = 'err:42501');
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.check('R16 anon cannot reconcile or read health',
    pg_temp.val('reconcile_account_deletions()') = 'err:42501'
    AND pg_temp.val('account_deletion_health()') = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('R17 the refused calls finalized nothing',
    (SELECT account_state FROM profiles WHERE user_id = 'fe000000-0000-0000-0000-000000000099') = 'deleting');
END $$;

ROLLBACK;
