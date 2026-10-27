-- ============================================================
-- Household deletion tests (migration 20261104000001, finding F7A)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/delete_household.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back.
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

-- Row counts of every household-scoped table for one household.
CREATE FUNCTION pg_temp.leftovers(p_h uuid) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  select (select count(*) from household_members where household_id = p_h)
       + (select count(*) from household_membership_periods where household_id = p_h)
       + (select count(*) from household_invites where household_id = p_h)
       + (select count(*) from tasks where household_id = p_h)
       + (select count(*) from task_occurrences where household_id = p_h)
       + (select count(*) from task_events where household_id = p_h)
       + (select count(*) from shopping_items where household_id = p_h)
       + (select count(*) from expenses where household_id = p_h)
       + (select count(*) from expense_participants where expense_id in (select id from expenses where household_id = p_h))
       + (select count(*) from expense_settlements where household_id = p_h)
       + (select count(*) from financial_operations where household_id = p_h)
       + (select count(*) from financial_archive where household_id = p_h)
       + (select count(*) from household_events where household_id = p_h)
       + (select count(*) from notification_outbox where household_id = p_h)
       + (select count(*) from households where id = p_h)
$$;

-- A fingerprint of everything that belongs to one household.
CREATE FUNCTION pg_temp.fingerprint(p_h uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  select md5(concat_ws('|',
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from expenses x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from expense_settlements x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from tasks x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from shopping_items x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from financial_archive x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from household_events x where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.id), '') from household_invites x where household_id = p_h),
    (select count(*)::text from financial_operations where household_id = p_h),
    (select coalesce(string_agg(row(x.*)::text, ',' order by x.user_id), '') from household_members x where household_id = p_h)))
$$;

DO $$
DECLARE
  a  uuid := 'fb000000-0000-0000-0000-00000000000a'; -- owner of h and h2
  b  uuid := 'fb000000-0000-0000-0000-00000000000b'; -- member of h, h2; owns h3
  c  uuid := 'fb000000-0000-0000-0000-00000000000c'; -- member removed from h
  d  uuid := 'fb000000-0000-0000-0000-00000000000d'; -- outsider
  h uuid; h2 uuid; h3 uuid; he uuid; hx uuid; v_code text;
  e1 uuid; e2 uuid; s1 uuid; s2 uuid;
  k1 uuid := 'eeeeeeee-0000-4000-8000-000000000001';
  k2 uuid := 'eeeeeeee-0000-4000-8000-000000000002';
  code_h text; hz uuid; fp_z text; fp2 text; fp3 text; archives_other int; r text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'del'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(d,4)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'DEL-'||i,'Del'||i FROM (VALUES (a,1),(b,2),(c,3),(d,4)) v(id,i);

  PERFORM pg_temp.as_user(a);
  SELECT id INTO h FROM create_household('DEL MAIN');
  SELECT id INTO h2 FROM create_household('DEL OTHER');
  SELECT id INTO he FROM create_household('DEL EMPTY');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  code_h := v_code;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(a);
  SELECT hi.code INTO v_code FROM create_household_invite(h2) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  SELECT id INTO h3 FROM create_household('DEL B OWNED');

  -- h2 and h3 get data, so we can prove they are untouched
  PERFORM pg_temp.as_user(a);
  e2 := create_equal_split_expense(h2,'Other dinner',2000,'EUR',a,array[a,b]);
  PERFORM pg_temp.as_admin();
  INSERT INTO tasks (household_id,title,created_by,due_at,recurrence_type,recurrence_started_at)
  VALUES (h2,'Other task',a,now(),'daily',now());
  INSERT INTO shopping_items (household_id,name,created_by) VALUES (h2,'Other milk',a);
  PERFORM pg_temp.as_user(b);
  PERFORM create_equal_split_expense(h3,'B own',900,'EUR',b,array[b]);
  PERFORM pg_temp.as_admin();

  -- populate h
  PERFORM pg_temp.as_user(a);
  e1 := create_equal_split_expense(h,'Dinner',3000,'EUR',a,array[a,b,c],k1);
  PERFORM create_equal_split_expense(h,'Cancelled dinner',1000,'EUR',a,array[a,b]);
  s1 := (create_settlement(h,b,a,500,'EUR',null,k2)).id;
  s2 := (create_settlement(h,c,a,100,'EUR')).id;
  PERFORM cancel_expense((SELECT id FROM expenses WHERE household_id = h AND title = 'Cancelled dinner'), 'oops');
  PERFORM cancel_settlement(s2, 'wrong');
  PERFORM pg_temp.as_admin();
  INSERT INTO tasks (household_id,title,created_by,assigned_to,due_at,recurrence_type,recurrence_started_at)
  VALUES (h,'Recurring',a,b,now(),'daily',now()),(h,'Plain',a,null,null,'none',null);
  INSERT INTO shopping_items (household_id,name,created_by) VALUES (h,'Milk',a),(h,'Bread',b);
  PERFORM pg_temp.as_user(a); PERFORM remove_household_member(h, c);   -- outbox + event rows
  PERFORM create_household_invite(h);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('00 setup: the household is populated in every table',
    (SELECT count(*) FROM financial_archive WHERE household_id = h) = 2
    AND (SELECT count(*) FROM task_occurrences WHERE household_id = h) >= 1
    AND (SELECT count(*) FROM household_events WHERE household_id = h) > 0
    AND (SELECT count(*) FROM financial_operations WHERE household_id = h) = 2
    AND (SELECT count(*) FROM notification_outbox WHERE household_id = h) > 0
    AND (SELECT count(*) FROM expense_participants WHERE expense_id = e1) = 3);
  fp2 := pg_temp.fingerprint(h2);
  fp3 := pg_temp.fingerprint(h3);
  SELECT count(*) INTO archives_other FROM financial_archive WHERE household_id <> h;

  -- Denied callers
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('01 a plain member is denied and nothing changes',
    pg_temp.val(format('delete_household(%L)', h)) = 'err:HD002' AND pg_temp.leftovers(h) > 0);
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('02 a removed member is denied',
    pg_temp.val(format('delete_household(%L)', h)) = 'err:HD002');
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('03 an outsider is denied, and an unknown id looks the same',
    pg_temp.val(format('delete_household(%L)', h)) = 'err:HD002'
    AND pg_temp.val(format('delete_household(%L)', gen_random_uuid())) = 'err:HD002');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('03b anonymous callers cannot execute it',
    has_function_privilege('anon', 'delete_household(uuid)', 'EXECUTE') = false
    AND has_function_privilege('authenticated', 'delete_household(uuid)', 'EXECUTE'));

  -- Archive protection outside the RPC
  PERFORM pg_temp.as_user(a);
  PERFORM set_config('app.erase_household', h::text, true);   -- forged context
  PERFORM pg_temp.check('04 a forged erase setting does not let a client delete archive rows',
    pg_temp.rows(format('delete from financial_archive where household_id = %L', h)) = 'err:42501');
  PERFORM pg_temp.check('04b ... nor update or truncate them',
    pg_temp.rows($q$update financial_archive set reason = 'x'$q$) = 'err:42501'
    AND pg_temp.rows($q$truncate financial_archive$q$) = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM set_config('app.erase_household', h2::text, true);
  PERFORM pg_temp.check('05 the erase context is scoped to one household: it cannot erase another one',
    pg_temp.rows(format('delete from financial_archive where household_id = %L', h)) = 'err:HC003'
    AND pg_temp.rows($q$update financial_archive set reason = 'x'$q$) = 'err:HC003'
    AND pg_temp.rows($q$truncate financial_archive$q$) = 'err:HC003');
  PERFORM set_config('app.erase_household', '', true);
  PERFORM pg_temp.check('06 ordinary cancellations still archive',
    (SELECT count(*) FROM financial_archive WHERE household_id = h) = 2);

  -- Empty household
  PERFORM pg_temp.as_user(a);
  PERFORM delete_household(he);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('07 an owner can delete an empty household',
    pg_temp.leftovers(he) = 0);

  -- Populated household
  PERFORM pg_temp.as_user(a);
  PERFORM delete_household(h);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('08 the populated household and every dependent row are gone',
    pg_temp.leftovers(h) = 0, pg_temp.leftovers(h)::text);
  PERFORM pg_temp.check('09 no archive row, event, outbox row or F13 key remains for it',
    NOT EXISTS (SELECT 1 FROM financial_archive WHERE household_id = h)
    AND NOT EXISTS (SELECT 1 FROM financial_operations WHERE household_id = h)
    AND NOT EXISTS (SELECT 1 FROM financial_operations WHERE request_id IN (k1, k2))
    AND NOT EXISTS (SELECT 1 FROM household_events WHERE household_id = h)
    AND NOT EXISTS (SELECT 1 FROM task_events WHERE household_id = h));
  PERFORM pg_temp.check('10 other households are logically unchanged',
    pg_temp.fingerprint(h2) = fp2 AND pg_temp.fingerprint(h3) = fp3
    AND (SELECT count(*) FROM financial_archive WHERE household_id <> h) = archives_other);
  PERFORM pg_temp.check('11 user accounts, profiles and other memberships are preserved',
    (SELECT count(*) FROM profiles WHERE user_id IN (a,b,c,d)) = 4
    AND (SELECT count(*) FROM auth.users WHERE id IN (a,b,c,d)) = 4
    AND EXISTS (SELECT 1 FROM household_members WHERE household_id = h2 AND user_id = a AND role = 'owner' AND status = 'active')
    AND EXISTS (SELECT 1 FROM household_members WHERE household_id = h2 AND user_id = b AND status = 'active')
    AND EXISTS (SELECT 1 FROM household_members WHERE household_id = h3 AND user_id = b AND role = 'owner'));

  -- After deletion
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('12 the former owner cannot delete it again',
    pg_temp.val(format('delete_household(%L)', h)) = 'err:HD002');
  PERFORM pg_temp.check('13 late financial requests fail with a definite refusal',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Dinner',3000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1)) LIKE 'err:HE%'
    AND pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR',null,%L)).id$q$, h,b,a,k2)) LIKE 'err:HS%');
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('14 joining with a code of the deleted household fails',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code_h)) = 'err:HO004');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('15 other households keep working normally',
    pg_temp.val(format($q$create_equal_split_expense(%L,'After',500,'EUR',%L,array[%L]::uuid[])$q$, h3,b,b)) !~ '^err:');

  -- A cleanup failure rolls everything back
  PERFORM pg_temp.as_user(a);
  SELECT id INTO hz FROM create_household('DEL ATOMIC');
  PERFORM create_equal_split_expense(hz,'Z',700,'EUR',a,array[a],'eeeeeeee-0000-4000-8000-000000000009');
  PERFORM pg_temp.as_admin();
  INSERT INTO tasks (household_id,title,created_by) VALUES (hz,'Z task',a);
  INSERT INTO shopping_items (household_id,name,created_by) VALUES (hz,'Z item',a);
  fp_z := pg_temp.fingerprint(hz);
  CREATE FUNCTION pg_temp.boom() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN RAISE EXCEPTION 'boom' USING errcode = 'XX999'; END $f$;
  CREATE TRIGGER boom BEFORE DELETE ON financial_operations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.boom();
  BEGIN
    PERFORM pg_temp.as_user(a);
    PERFORM delete_household(hz);
    PERFORM pg_temp.check('16 the failure test must fail', false);
  EXCEPTION WHEN SQLSTATE 'XX999' THEN
    NULL;
  END;
  PERFORM pg_temp.as_admin();
  DROP TRIGGER boom ON financial_operations;
  PERFORM pg_temp.check('16 a failing cleanup step rolls the whole deletion back',
    pg_temp.fingerprint(hz) = fp_z AND pg_temp.leftovers(hz) > 0
    AND (SELECT count(*) FROM financial_archive WHERE household_id = hz) = 0);
  PERFORM pg_temp.check('16b ... and the erase context does not leak out of the failed call',
    coalesce(current_setting('app.erase_household', true), '') = '');
  PERFORM pg_temp.as_user(a);
  PERFORM delete_household(hz);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17 after the fault is removed the same deletion succeeds',
    pg_temp.leftovers(hz) = 0);

  -- Direct financial deletes outside the RPC still archive (F4 unchanged)
  PERFORM pg_temp.as_user(b);
  r := pg_temp.rows(format('delete from expenses where household_id = %L and title = %L', h3, 'B own'));
  PERFORM pg_temp.check('18 a direct DELETE of an expense still archives it',
    r = '1' AND (SELECT count(*) FROM financial_archive WHERE household_id = h3 AND kind = 'expense') = 1);
END $$;

ROLLBACK;
