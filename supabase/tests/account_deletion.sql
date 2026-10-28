-- ============================================================
-- Account deletion tests (migration 20261105000001, finding F7B)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/account_deletion.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back. The Auth side (admin deleteUser) is
-- covered by the separate local integration script, not here.
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
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;

CREATE FUNCTION pg_temp.as_admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE 'RESET ROLE'; END $$;

-- The trusted backend: no JWT identity, role service_role (the Edge Function).
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

-- Net balance per user id of one household, as a comparable string.
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

-- Everything about other people that must not change when someone is deleted.
CREATE FUNCTION pg_temp.others(p_h uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  select md5(concat_ws('|',
    (select coalesce(string_agg(x.id::text || x.title || x.amount_cents || x.currency, ',' order by x.id), '') from expenses x where household_id = p_h),
    (select coalesce(string_agg(x.id::text || x.amount_cents || x.from_user_id || x.to_user_id, ',' order by x.id), '') from expense_settlements x where household_id = p_h),
    (select count(*)::text from tasks where household_id = p_h),
    (select count(*)::text from shopping_items where household_id = p_h)))
$$;

DO $$
DECLARE
  o  uuid := 'fc000000-0000-0000-0000-00000000000a'; -- owner of h1
  a  uuid := 'fc000000-0000-0000-0000-00000000000b'; -- deleted first
  b  uuid := 'fc000000-0000-0000-0000-00000000000c'; -- stays
  c  uuid := 'fc000000-0000-0000-0000-00000000000d'; -- deleted second
  x  uuid := 'fc000000-0000-0000-0000-00000000000e'; -- no profile
  n1 uuid := 'fc000000-0000-0000-0000-000000000011'; -- hardening: profile creation
  n2 uuid := 'fc000000-0000-0000-0000-000000000012';
  n3 uuid := 'fc000000-0000-0000-0000-000000000013';
  n4 uuid := 'fc000000-0000-0000-0000-000000000014';
  n5 uuid := 'fc000000-0000-0000-0000-000000000015';
  n6 uuid := 'fc000000-0000-0000-0000-000000000016';
  h1 uuid; h2 uuid; h3 uuid; h4 uuid; hz uuid; code1 text; code2 text;
  e1 uuid; e2 uuid; ex uuid; sx uuid; s1 uuid;
  ka uuid := 'cdcdcdcd-0000-4000-8000-0000000000a1';
  kb uuid := 'cdcdcdcd-0000-4000-8000-0000000000b1';
  bal_h1 text; bal_h2 text; oth_h1 text; oth_h2 text; r text; snap text; pid_a text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'acc'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (o,1),(a,2),(b,3),(c,4),(x,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name,avatar_url)
  SELECT id,'ACC-'||i,'Acc'||i,'https://example.test/'||i FROM (VALUES (o,1),(a,2),(b,3),(c,4)) v(id,i);

  PERFORM pg_temp.as_user(o); SELECT id INTO h1 FROM create_household('ACC H1');
  SELECT hi.code INTO code1 FROM create_household_invite(h1) hi;
  PERFORM pg_temp.as_user(b); SELECT id INTO h2 FROM create_household('ACC H2');
  SELECT hi.code INTO code2 FROM create_household_invite(h2) hi;
  PERFORM pg_temp.as_user(a); PERFORM join_household_by_invite(code1); PERFORM join_household_by_invite(code2);
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(code1);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(code1); PERFORM join_household_by_invite(code2);

  -- financial history involving a and c in h1 and h2
  PERFORM pg_temp.as_user(a);
  e1 := create_equal_split_expense(h1,'Dinner',3000,'EUR',a,array[a,b,c],ka);
  ex := create_equal_split_expense(h1,'Cancelled',1000,'EUR',a,array[a,b]);
  s1 := (create_settlement(h1,a,b,500,'EUR')).id;
  sx := (create_settlement(h1,a,b,200,'EUR')).id;
  PERFORM cancel_expense(ex, 'mine'); PERFORM cancel_settlement(sx, 'mine too');
  PERFORM pg_temp.as_user(b);
  e2 := create_equal_split_expense(h1,'Rent',2000,'EUR',b,array[a,b,c],kb);
  PERFORM create_equal_split_expense(h2,'Groceries',900,'EUR',b,array[a,b,c]);
  PERFORM pg_temp.as_user(c);
  PERFORM create_settlement(h1,c,a,100,'EUR');
  PERFORM create_equal_split_expense(h2,'C paid',600,'EUR',c,array[a,c]);
  PERFORM pg_temp.as_admin();
  INSERT INTO tasks (household_id,title,created_by,assigned_to,recurrence_type)
    VALUES (h1,'Open task',o,a,'none');
  INSERT INTO tasks (household_id,title,created_by,recurrence_type) VALUES (h1,'Done task',o,'none');
  PERFORM pg_temp.as_user(a);
  UPDATE tasks SET completed_at = now(), completed_by = a WHERE title = 'Done task' AND household_id = h1;
  PERFORM pg_temp.as_admin();
  INSERT INTO shopping_items (household_id,name,created_by) VALUES (h1,'Milk by a',a);
  INSERT INTO device_push_tokens (user_id,token,platform) VALUES (a,'tok-a','android'),(b,'tok-b','android');
  INSERT INTO notification_outbox (recipient_user_id,household_id,type,title,body)
    VALUES (a,h1,'t','for a','x'),(b,h1,'t','for b','x');

  bal_h1 := pg_temp.bal(h1); bal_h2 := pg_temp.bal(h2);
  oth_h1 := pg_temp.others(h1); oth_h2 := pg_temp.others(h2);

  -- Eligibility
  PERFORM pg_temp.as_user(a);
  SELECT id INTO h3 FROM create_household('ACC SHARED OWN');
  SELECT hi.code INTO code1 FROM create_household_invite(h3) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(code1);
  PERFORM pg_temp.as_user(a);
  SELECT id INTO h4 FROM create_household('ACC SOLO OWN');
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('01 an owner of a shared household is blocked',
    pg_temp.val(format('begin_account_deletion(%L)', a)) = 'err:AD002');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('02 the blocker list names both owned homes with member counts',
    (SELECT count(*) FROM account_deletion_blockers()) = 2
    AND (SELECT active_member_count FROM account_deletion_blockers() WHERE name = 'ACC SOLO OWN') = 1);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('03 a blocked attempt changes nothing',
    (SELECT account_state FROM profiles WHERE user_id = a) = 'active'
    AND (SELECT count(*) FROM household_members WHERE user_id = a AND status = 'active') = 4);
  PERFORM pg_temp.as_user(a);
  PERFORM transfer_household_ownership(h3, b);
  PERFORM delete_household(h4);
  PERFORM pg_temp.check('04 after transferring one home and deleting the other, the account is eligible',
    (SELECT count(*) FROM account_deletion_blockers()) = 0);

  -- Atomicity: a failing cleanup step rolls everything back
  PERFORM pg_temp.as_admin();
  CREATE FUNCTION pg_temp.boom() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN RAISE EXCEPTION 'boom' USING errcode = 'XX999'; END $f$;
  CREATE TRIGGER boom BEFORE DELETE ON device_push_tokens
    FOR EACH ROW EXECUTE FUNCTION pg_temp.boom();
  BEGIN
    PERFORM pg_temp.as_service();
    PERFORM begin_account_deletion(a);
    PERFORM pg_temp.check('05 the failure test must fail', false);
  EXCEPTION WHEN SQLSTATE 'XX999' THEN NULL;
  END;
  PERFORM pg_temp.as_admin();
  DROP TRIGGER boom ON device_push_tokens;
  PERFORM pg_temp.check('05 a failing cleanup leaves the account fully active and intact',
    (SELECT account_state FROM profiles WHERE user_id = a) = 'active'
    AND (SELECT display_name FROM profiles WHERE user_id = a) = 'Acc2'
    AND (SELECT count(*) FROM household_members WHERE user_id = a AND status = 'active') = 3
    AND (SELECT paid_by_display_name FROM expenses WHERE id = e1) = 'Acc2');

  -- Unauthorized / foreign requests
  PERFORM pg_temp.as_service();
  PERFORM pg_temp.check('06 a target without a profile is refused',
    pg_temp.val(format('begin_account_deletion(%L)', x)) = 'err:AD001'
    AND pg_temp.val('begin_account_deletion(null::uuid)') = 'err:AD000');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('06b only service_role may call begin / finalize / reconcile; the zero-argument form is gone',
    to_regprocedure('begin_account_deletion()') IS NULL
    AND pg_get_function_arguments('begin_account_deletion(uuid)'::regprocedure) = 'p_user_id uuid'
    AND has_function_privilege('service_role','begin_account_deletion(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','begin_account_deletion(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','begin_account_deletion(uuid)','EXECUTE')
    AND NOT has_function_privilege('public','begin_account_deletion(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','finalize_account_deletion(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','reconcile_account_deletions()','EXECUTE')
    AND NOT has_function_privilege('anon','reconcile_account_deletions()','EXECUTE')
    AND has_function_privilege('service_role','finalize_account_deletion(uuid)','EXECUTE')
    AND has_function_privilege('service_role','reconcile_account_deletions()','EXECUTE')
    AND NOT has_function_privilege('authenticated','_scrub_account_data(uuid)','EXECUTE'));

  -- Clients cannot start a deletion themselves, for themselves or anyone else
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('06c an authenticated user cannot call begin_account_deletion at all',
    pg_temp.val(format('begin_account_deletion(%L)', b)) = 'err:42501'
    AND pg_temp.val(format('begin_account_deletion(%L)', o)) = 'err:42501'
    AND pg_temp.val('begin_account_deletion()') = 'err:42883');
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.check('06d anon cannot call it either',
    pg_temp.val(format('begin_account_deletion(%L)', b)) = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('06e the refused calls changed nothing',
    (SELECT count(*) FROM profiles WHERE user_id IN (o, b) AND account_state = 'active') = 2
    AND EXISTS (SELECT 1 FROM household_members WHERE user_id = b AND status = 'active'));

  -- Delete a
  PERFORM pg_temp.as_service();
  r := begin_account_deletion(a);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('07 deletion reports the deleting state and revokes every membership',
    r = 'deleting'
    AND (SELECT account_state FROM profiles WHERE user_id = a) = 'deleting'
    AND NOT EXISTS (SELECT 1 FROM household_members WHERE user_id = a AND status = 'active')
    AND NOT EXISTS (SELECT 1 FROM household_membership_periods WHERE user_id = a AND left_at IS NULL));
  PERFORM pg_temp.check('08 financial balances of both households are unchanged',
    pg_temp.bal(h1) = bal_h1 AND pg_temp.bal(h2) = bal_h2);
  PERFORM pg_temp.check('09 other people''s rows are unchanged',
    pg_temp.others(h1) = oth_h1 AND pg_temp.others(h2) = oth_h2);
  PERFORM pg_temp.check('10 stored names of the user are scrubbed from live rows',
    (SELECT paid_by_display_name FROM expenses WHERE id = e1) = 'Deleted member'
    AND (SELECT display_name FROM expense_participants WHERE expense_id = e1 AND user_id = a) = 'Deleted member'
    AND (SELECT from_name FROM expense_settlements WHERE id = s1) = 'Deleted member'
    AND NOT EXISTS (SELECT 1 FROM household_events WHERE actor_user_id = a AND actor_display_name <> 'Deleted member')
    AND NOT EXISTS (SELECT 1 FROM expenses WHERE paid_by = a AND paid_by_display_name <> 'Deleted member'));
  PERFORM pg_temp.check('11 other participants keep their names',
    (SELECT display_name FROM expense_participants WHERE expense_id = e1 AND user_id = b) = 'Acc3'
    AND (SELECT paid_by_display_name FROM expenses WHERE id = e2) = 'Acc3'
    AND (SELECT to_name FROM expense_settlements WHERE id = s1) = 'Acc3');
  PERFORM pg_temp.check('12 archive snapshots are scrubbed for the user only, amounts intact',
    (SELECT snapshot->>'paid_by_display_name' = 'Deleted member'
        AND snapshot->>'amount_cents' = '1000' AND snapshot->>'paid_by' = a::text
        AND (SELECT count(*) FROM jsonb_array_elements(snapshot->'participants') p
             WHERE p->>'display_name' = 'Deleted member') = 1
        AND (SELECT p->>'display_name' FROM jsonb_array_elements(snapshot->'participants') p
             WHERE p->>'user_id' = b::text) = 'Acc3'
        AND canceled_by_name = 'Deleted member'
     FROM financial_archive WHERE record_id = ex)
    AND (SELECT snapshot->>'from_name' = 'Deleted member' AND snapshot->>'to_name' = 'Acc3'
                AND snapshot->>'amount_cents' = '200'
         FROM financial_archive WHERE record_id = sx));
  PERFORM pg_temp.check('13 only the deleting user''s F13 keys are removed',
    NOT EXISTS (SELECT 1 FROM financial_operations WHERE actor_id = a)
    AND EXISTS (SELECT 1 FROM financial_operations WHERE actor_id = b AND request_id = kb));
  PERFORM pg_temp.check('14 task and shopping history stays consistent',
    (SELECT completed_by FROM tasks WHERE title = 'Done task' AND household_id = h1) = a
    AND (SELECT assigned_to IS NULL FROM tasks WHERE title = 'Open task' AND household_id = h1)
    AND (SELECT created_by FROM shopping_items WHERE name = 'Milk by a') = a);
  PERFORM pg_temp.check('15 device tokens and pending notifications of the user are gone, others remain',
    NOT EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = a)
    AND NOT EXISTS (SELECT 1 FROM notification_outbox WHERE recipient_user_id = a)
    AND EXISTS (SELECT 1 FROM device_push_tokens WHERE user_id = b)
    AND EXISTS (SELECT 1 FROM notification_outbox WHERE recipient_user_id = b));
  PERFORM pg_temp.check('16 the profile is a tombstone: no name, no avatar, public id replaced, same user id',
    (SELECT display_name = 'Deleted member' AND avatar_url IS NULL
        AND public_id ~ '^DELETED-[0-9a-f]{32}$'
        AND public_id <> 'DELETED-' || replace(a::text, '-', '') FROM profiles WHERE user_id = a));
  pid_a := (SELECT public_id FROM profiles WHERE user_id = a);

  -- An existing JWT of the deleting user has no access
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('17 reads return nothing',
    (SELECT count(*) FROM households) = 0 AND (SELECT count(*) FROM expenses) = 0
    AND (SELECT count(*) FROM expense_settlements) = 0 AND (SELECT count(*) FROM tasks) = 0
    AND (SELECT count(*) FROM shopping_items) = 0 AND (SELECT count(*) FROM financial_archive) = 0
    AND (SELECT count(*) FROM household_events) = 0 AND (SELECT count(*) FROM household_members WHERE household_id IN (h1,h2) AND user_id <> a) = 0);
  PERFORM pg_temp.check('18 direct writes are refused or touch nothing',
    pg_temp.rows(format($q$insert into tasks (household_id,title,created_by,recurrence_type) values (%L,'x',%L,'none')$q$, h1, a)) LIKE 'err:%'
    AND pg_temp.rows(format($q$update tasks set title = 'hacked' where household_id = %L$q$, h1)) = '0'
    AND pg_temp.rows(format($q$delete from shopping_items where household_id = %L$q$, h1)) = '0'
    AND pg_temp.rows(format($q$insert into shopping_items (household_id,name,created_by) values (%L,'x',%L)$q$, h1, a)) LIKE 'err:%');
  PERFORM pg_temp.check('19 RPCs are refused',
    pg_temp.val('create_household(''new'')') = 'err:AD003'
    AND pg_temp.val(format('join_household_by_invite(%L)', code2)) = 'err:AD003'
    AND pg_temp.val(format('(create_settlement(%L,%L,%L,100,''EUR'')).id', h1, a, b)) LIKE 'err:%'
    AND pg_temp.val(format($q$create_equal_split_expense(%L,'x',100,'EUR',%L,array[%L]::uuid[])$q$, h1, a, a)) LIKE 'err:%'
    AND pg_temp.val(format('(cancel_expense(%L)).id', e2)) LIKE 'err:%');
  PERFORM pg_temp.check('20 it cannot edit its profile, revive its state or register push tokens',
    pg_temp.rows($q$update profiles set display_name = 'Back' where true$q$) = '0'
    AND pg_temp.rows($q$update profiles set account_state = 'active' where true$q$) LIKE 'err:%'
    AND pg_temp.rows(format($q$insert into device_push_tokens (user_id,token,platform) values (%L,'new','android')$q$, a)) LIKE 'err:%');
  -- Forged scrub context from a client changes nothing
  PERFORM pg_temp.as_user(b);
  PERFORM set_config('app.scrub_user', c::text, true);
  PERFORM pg_temp.check('21 a forged scrub setting does not let a client rewrite history',
    pg_temp.rows(format($q$update financial_archive set canceled_by_name = 'x' where household_id = %L$q$, h1)) = 'err:42501'
    AND pg_temp.rows(format($q$update expenses set paid_by_display_name = 'Deleted member' where id = %L$q$, e2)) = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM set_config('app.scrub_user', '', true);
  PERFORM pg_temp.check('21b ... even as the table owner the setting needs the privileged function context',
    pg_temp.rows(format($q$update financial_archive set canceled_by_name = 'x' where household_id = %L$q$, h1)) = 'err:HC003'
    OR current_user = (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'public.begin_account_deletion(uuid)'::regprocedure));
  -- service_role is the new caller of begin_account_deletion, but it is not the
  -- privileged owner role: a forged setting gives it no scrub authority either.
  PERFORM pg_temp.as_service();
  PERFORM set_config('app.scrub_user', c::text, true);
  PERFORM pg_temp.check('21c service_role with a forged scrub setting still cannot rewrite history',
    pg_temp.rows(format($q$update financial_archive set canceled_by_name = 'x' where household_id = %L$q$, h1)) IN ('err:HC003', 'err:42501')
    AND pg_temp.rows(format($q$update expenses set paid_by_display_name = 'Deleted member' where id = %L$q$, e2)) = 'err:HO029'
    AND pg_temp.val(format('_scrubbing_user(%L)', c)) IN ('false', 'err:42501'));
  PERFORM pg_temp.as_admin();
  PERFORM set_config('app.scrub_user', '', true);

  -- Idempotent retry
  PERFORM pg_temp.as_service();
  r := begin_account_deletion(a);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('22 repeating the deletion is safe, changes nothing and keeps the tombstone id',
    r = 'deleting' AND pg_temp.bal(h1) = bal_h1 AND pg_temp.others(h1) = oth_h1
    AND (SELECT count(*) FROM financial_archive WHERE record_id = ex) = 1
    AND (SELECT public_id FROM profiles WHERE user_id = a) = pid_a);

  -- Other users keep full access
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('23 other members keep full access and see the tombstone name',
    (SELECT count(*) FROM expenses WHERE household_id = h1) = 2
    AND (SELECT count(*) FROM financial_archive WHERE household_id = h1) = 2
    AND pg_temp.val(format($q$create_equal_split_expense(%L,'After',100,'EUR',%L,array[%L]::uuid[])$q$, h1, b, b)) !~ '^err:'
    AND pg_temp.val(format($q$create_equal_split_expense(%L,'Dead payer',100,'EUR',%L,array[%L]::uuid[])$q$, h1, a, b)) LIKE 'err:%');
  PERFORM pg_temp.as_user(o);
  PERFORM pg_temp.check('23b a former member cannot be paid through a new settlement (F3)',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,100,'EUR')).id$q$, h1, b, a)) LIKE 'err:HS%');

  -- Second deleted user stays distinct
  PERFORM pg_temp.as_service();
  PERFORM begin_account_deletion(c);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('24 two deleted users stay two distinct identities with unchanged balances',
    (SELECT count(DISTINCT user_id) FROM profiles WHERE user_id IN (a, c) AND display_name = 'Deleted member') = 2
    AND (SELECT count(DISTINCT public_id) FROM profiles WHERE user_id IN (a, c)) = 2
    AND pg_temp.bal(h2) = bal_h2
    AND pg_temp.bal(h1) LIKE '%' || a::text || '%' AND pg_temp.bal(h1) LIKE '%' || c::text || '%');

  -- Finalization needs the Auth user to be gone
  PERFORM pg_temp.check('25 finalization is refused while the Auth user still exists',
    pg_temp.val(format('finalize_account_deletion(%L)', a)) = 'err:AD005'
    AND (SELECT account_state FROM profiles WHERE user_id = a) = 'deleting');
  PERFORM pg_temp.check('25b finalization of an account that never started deleting is refused',
    pg_temp.val(format('finalize_account_deletion(%L)', b)) = 'err:AD004');
  DELETE FROM auth.users WHERE id = a;
  r := pg_temp.val(format('finalize_account_deletion(%L)', a));
  PERFORM pg_temp.check('26 once the Auth user is gone finalization works and is repeatable',
    r = 'deleted' AND pg_temp.val(format('finalize_account_deletion(%L)', a)) = 'deleted');
  PERFORM pg_temp.check('26b ... and the tombstone keeps its history',
    (SELECT deleted_at IS NOT NULL FROM profiles WHERE user_id = a)
    AND EXISTS (SELECT 1 FROM expenses WHERE paid_by = a));
  DELETE FROM auth.users WHERE id = c;
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.check('27 reconciliation closes interrupted deletions, once',
    r = '1' AND pg_temp.val('reconcile_account_deletions()') = '0'
    AND (SELECT account_state FROM profiles WHERE user_id = c) = 'deleted');

  -- Reconciliation only ever finishes accounts whose Auth user is really gone
  INSERT INTO profiles (user_id,public_id,display_name,account_state)
    VALUES (x,'ACC-Z','Deleted member','deleting');
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.check('27b reconciliation never closes an account whose Auth user still exists',
    r = '0'
    AND (SELECT account_state FROM profiles WHERE user_id = x) = 'deleting'
    AND (SELECT account_state FROM profiles WHERE user_id = b) = 'active'
    AND (SELECT account_state FROM profiles WHERE user_id = o) = 'active');
  DELETE FROM auth.users WHERE id = x;
  r := pg_temp.val('reconcile_account_deletions()');
  PERFORM pg_temp.check('27c ... and closes exactly the one whose Auth user vanished, leaving active users alone',
    r = '1' AND (SELECT account_state FROM profiles WHERE user_id = x) = 'deleted'
    AND (SELECT account_state FROM profiles WHERE user_id IN (b, o) GROUP BY account_state) = 'active'
    AND pg_temp.val('reconcile_account_deletions()') = '0');

  -- A deleted profile cannot come back
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('27d a deleted profile cannot join or create households',
    pg_temp.val(format('join_household_by_invite(%L)', code2)) = 'err:AD003'
    AND pg_temp.val('create_household(''back'')') = 'err:AD003'
    AND pg_temp.rows(format($q$update profiles set account_state = 'active' where user_id = %L$q$, a)) LIKE 'err:%');
  PERFORM pg_temp.as_admin();

  -- F7A still works for a household containing tombstones
  PERFORM pg_temp.as_user(o);
  PERFORM delete_household(h1);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('28 whole-household deletion still works with tombstone members',
    NOT EXISTS (SELECT 1 FROM households WHERE id = h1)
    AND NOT EXISTS (SELECT 1 FROM financial_archive WHERE household_id = h1)
    AND EXISTS (SELECT 1 FROM households WHERE id = h2)
    AND EXISTS (SELECT 1 FROM profiles WHERE user_id IN (a, c)));

  -- Hardening: profiles INSERT / UPDATE privileges
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'hard'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (n1,1),(n2,2),(n3,3),(n4,4)) v(id,i);

  PERFORM pg_temp.as_user(n1);
  r := pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'HARD-0001','User-HARD')$q$, n1));
  PERFORM pg_temp.check('29 legitimate profile creation (user_id, public_id, display_name) still works',
    r = '1' AND (SELECT account_state FROM profiles WHERE user_id = n1) = 'active');
  r := pg_temp.rows(format($q$update profiles set display_name = 'Renamed', avatar_url = 'https://example.test/n1' where user_id = %L$q$, n1));
  PERFORM pg_temp.check('29b ... and the client may edit its own name and avatar',
    r = '1' AND (SELECT display_name FROM profiles WHERE user_id = n1) = 'Renamed');
  PERFORM pg_temp.as_user(n2);
  PERFORM pg_temp.check('30 a client cannot insert server-controlled state columns',
    pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,account_state) values (%L,'HARD-0002','x','deleting')$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,account_state) values (%L,'HARD-0002','x','deleted')$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,account_state) values (%L,'HARD-0002','x','active')$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,deleted_at) values (%L,'HARD-0002','x',now())$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,deletion_requested_at) values (%L,'HARD-0002','x',now())$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,created_at) values (%L,'HARD-0002','x',now())$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name,avatar_url) values (%L,'HARD-0002','x','u')$q$, n2)) = 'err:42501');
  PERFORM pg_temp.check('30b a client cannot create a profile for someone else',
    pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'HARD-0009','x')$q$, n3)) = 'err:42501');
  r := pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'HARD-0002','Two')$q$, n2));
  PERFORM pg_temp.check('30c a client cannot update server-controlled columns of its own row',
    r = '1'
    AND pg_temp.rows(format($q$update profiles set account_state = 'deleting' where user_id = %L$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$update profiles set deleted_at = now() where user_id = %L$q$, n2)) = 'err:42501'
    AND pg_temp.rows(format($q$update profiles set public_id = 'HARD-ZZZZ' where user_id = %L$q$, n2)) = 'err:42501'
    AND (SELECT account_state FROM profiles WHERE user_id = n2) = 'active');
  PERFORM pg_temp.check('30d a deleted tombstone cannot be re-created or taken over',
    pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'HARD-0010','x')$q$, a)) = 'err:42501'
    AND pg_temp.rows(format($q$update profiles set display_name = 'mine' where user_id = %L$q$, a)) = '0');

  -- Hardening: tombstone namespace
  PERFORM pg_temp.as_user(n3);
  PERFORM pg_temp.check('31 the old predictable tombstone id cannot be registered by a client',
    pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,%L,'Squatter')$q$,
      n3, 'DELETED-' || replace(n4::text, '-', ''))) = 'err:23514'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,%L,'Squatter')$q$,
      n3, 'deleted-' || replace(n4::text, '-', ''))) = 'err:23514'
    AND pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'DELETED-anything','Squatter')$q$, n3)) = 'err:23514');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('31b ... even for a privileged writer, an active profile may not use the prefix',
    pg_temp.rows(format($q$insert into profiles (user_id,public_id,display_name) values (%L,'DELETED-x','Squatter')$q$, n3)) = 'err:23514');
  INSERT INTO profiles (user_id,public_id,display_name) VALUES (n3,'HARD-0003','Three'),(n4,'HARD-0004','Four');
  PERFORM pg_temp.as_service();
  PERFORM begin_account_deletion(n3);
  PERFORM begin_account_deletion(n4);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('32 tombstone ids are random, well-formed and unique, never derived from the user id',
    (SELECT count(DISTINCT public_id) FROM profiles WHERE user_id IN (n3, n4)) = 2
    AND NOT EXISTS (SELECT 1 FROM profiles WHERE user_id IN (n3, n4)
                    AND (public_id !~ '^DELETED-[0-9a-f]{32}$'
                         OR public_id = 'DELETED-' || replace(user_id::text, '-', '')))
    AND (SELECT account_state FROM profiles WHERE user_id = n3) = 'deleting');

  -- A random-id collision is retried; persistent failure aborts atomically.
  CREATE SEQUENCE pg_temp.collide;
  CREATE FUNCTION pg_temp.collide() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN
    IF new.public_id LIKE 'DELETED-%' AND old.public_id NOT LIKE 'DELETED-%'
       AND nextval('pg_temp.collide') <= tg_argv[0]::int THEN
      RAISE EXCEPTION 'dup' USING errcode = '23505';
    END IF;
    RETURN new;
  END $f$;
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
    VALUES (n5,'hard5@test.local','authenticated','authenticated',now(),now(),true),
           (n6,'hard6@test.local','authenticated','authenticated',now(),now(),true);
  INSERT INTO profiles (user_id,public_id,display_name) VALUES (n5,'HARD-0005','Five'),(n6,'HARD-0006','Six');
  CREATE TRIGGER collide BEFORE UPDATE OF public_id ON profiles
    FOR EACH ROW EXECUTE FUNCTION pg_temp.collide(2);
  PERFORM pg_temp.as_service();
  r := begin_account_deletion(n5);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('33 two simulated random collisions are retried and deletion succeeds',
    r = 'deleting' AND (SELECT public_id FROM profiles WHERE user_id = n5) ~ '^DELETED-[0-9a-f]{32}$');
  DROP TRIGGER collide ON profiles;
  CREATE TRIGGER collide BEFORE UPDATE OF public_id ON profiles
    FOR EACH ROW EXECUTE FUNCTION pg_temp.collide(1000);
  PERFORM pg_temp.as_service();
  r := pg_temp.val(format('begin_account_deletion(%L)', n6));
  PERFORM pg_temp.as_admin();
  DROP TRIGGER collide ON profiles;
  PERFORM pg_temp.check('33b a persistent collision fails the whole deletion and leaves the account active',
    r = 'err:23505' AND (SELECT account_state FROM profiles WHERE user_id = n6) = 'active'
    AND (SELECT display_name FROM profiles WHERE user_id = n6) = 'Six');
END $$;

ROLLBACK;
