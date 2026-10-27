-- ============================================================
-- Household currency and amount limit tests (migration 20261101000001, finding F12)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/financial_currency_amount_limits.sql
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

-- Evaluates a single-value SELECT expression; returns it as text, or 'err:<SQLSTATE>'.
CREATE FUNCTION pg_temp.val(p_expr text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE 'select (' || p_expr || ')::text' INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

-- Runs a DML statement; returns the affected row count as text, or 'err:<SQLSTATE>'.
CREATE FUNCTION pg_temp.rows(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n::text;
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

DO $$
DECLARE
  a  uuid := 'f7000000-0000-0000-0000-00000000000a'; -- owner
  b  uuid := 'f7000000-0000-0000-0000-00000000000b';
  c  uuid := 'f7000000-0000-0000-0000-00000000000c'; -- leaves later
  u  uuid := 'f7000000-0000-0000-0000-00000000000d'; -- unrelated member
  h uuid; hu uuid; v_code text;
  k1 uuid := 'cccccccc-0000-4000-8000-000000000001';
  k2 uuid := 'cccccccc-0000-4000-8000-000000000002';
  k3 uuid := 'cccccccc-0000-4000-8000-000000000003';
  k4 uuid := 'cccccccc-0000-4000-8000-000000000004';
  e1 text; e2 text; r text; legacy_usd uuid; legacy_big uuid; legacy_set uuid;
  snap_usd text; snap_big text; snap_set text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'cur'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(u,4)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'CUR-'||i,'Cur'||i FROM (VALUES (a,1),(b,2),(c,3),(u,4)) v(id,i);
  PERFORM pg_temp.as_user(a); SELECT id INTO h FROM create_household('CUR H');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(u); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_admin();

  PERFORM pg_temp.check('a new household defaults to EUR',
    (SELECT currency = 'EUR' FROM households WHERE id = h));

  -- legacy rows created before the rules existed (guard triggers bypassed for the fixture)
  ALTER TABLE expenses DISABLE TRIGGER expenses_amount_cap;
  ALTER TABLE expense_settlements DISABLE TRIGGER expense_settlements_amount_cap;
  INSERT INTO expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
  VALUES (h,'Legacy USD',5000,'USD',a,'Cur1',a) RETURNING id INTO legacy_usd;
  INSERT INTO expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
  VALUES (h,'Legacy huge',250000000,'EUR',a,'Cur1',a) RETURNING id INTO legacy_big;
  INSERT INTO expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by)
  VALUES (h,b,'Cur2',a,'Cur1',900,'GBP',b) RETURNING id INTO legacy_set;
  ALTER TABLE expenses ENABLE TRIGGER expenses_amount_cap;
  ALTER TABLE expense_settlements ENABLE TRIGGER expense_settlements_amount_cap;
  SELECT row(x.*)::text INTO snap_usd FROM expenses x WHERE id = legacy_usd;
  SELECT row(x.*)::text INTO snap_big FROM expenses x WHERE id = legacy_big;
  SELECT row(x.*)::text INTO snap_set FROM expense_settlements x WHERE id = legacy_set;

  -- ---------------- currency ----------------
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('1 EUR expense accepted',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L,%L]::uuid[])$q$, h,a,a,b)) !~ '^err:');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('2 EUR settlement accepted',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR'))::text$q$, h,b,a)) !~ '^err:');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('3 USD expense rejected for an EUR household',
    pg_temp.val(format($q$create_equal_split_expense(%L,'US',3000,'USD',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE008');
  PERFORM pg_temp.check('5 a well-formed but unsupported currency is rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'ZZ',3000,'ZZZ',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE008');
  PERFORM pg_temp.check('5b a malformed currency still fails the format check first',
    pg_temp.val(format($q$create_equal_split_expense(%L,'x',3000,'eur',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE004');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('4 USD settlement rejected for an EUR household',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'USD'))::text$q$, h,b,a)) = 'err:HS009');
  PERFORM pg_temp.check('5c unsupported settlement currency rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'ZZZ'))::text$q$, h,b,a)) = 'err:HS009');

  -- ---------------- amount limits ----------------
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('6 zero expense rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'z',0,'EUR',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE003');
  PERFORM pg_temp.check('6b negative expense rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'n',-5,'EUR',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE003');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('6c zero and negative settlements rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,0,'EUR'))::text$q$, h,b,a)) = 'err:HS003'
    AND pg_temp.val(format($q$(create_settlement(%L,%L,%L,-1,'EUR'))::text$q$, h,b,a)) = 'err:HS003');

  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Max',100000000,'EUR',%L,array[%L,%L,%L]::uuid[])$q$, h,a,a,b,c));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('7 exactly 100000000 cents is accepted (inclusive)', e1 !~ '^err:', 'result='||e1);
  PERFORM pg_temp.check('10 the odd-cent split at the maximum is exact',
    (SELECT array_agg(share_cents ORDER BY share_cents DESC) = ARRAY[33333334, 33333333, 33333333]::bigint[]
        AND sum(share_cents) = 100000000
       FROM expense_participants WHERE expense_id = e1::uuid));
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('7b exactly 100000000 cents settlement is accepted',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,100000000,'EUR'))::text$q$, h,b,a)) !~ '^err:');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('8 100000001 cents expense rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Over',100000001,'EUR',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE009');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('8b 100000001 cents settlement rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,100000001,'EUR'))::text$q$, h,b,a)) = 'err:HS010');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('9 the largest bigint is rejected, not wrapped',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Huge',9223372036854775807,'EUR',%L,array[%L]::uuid[])$q$, h,a,a)) = 'err:HE009');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('9b settlement at the largest bigint is rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,9223372036854775807,'EUR'))::text$q$, h,b,a)) = 'err:HS010');

  -- ---------------- database backstop for every insert path ----------------
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17 a direct over-cap insert is stopped by the trigger',
    pg_temp.rows(format($q$insert into expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by) values (%L,'direct',100000001,'EUR',%L,'Cur1',%L)$q$, h,a,a)) = 'err:HE009'
    AND pg_temp.rows(format($q$insert into expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by) values (%L,%L,'x',%L,'y',100000001,'EUR',%L)$q$, h,b,a,b)) = 'err:HS010');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('17b clients have no direct insert path to expenses or settlements',
    pg_temp.rows(format($q$insert into expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by) values (%L,'direct',100,'EUR',%L,'Cur1',%L)$q$, h,a,a)) = 'err:42501'
    AND pg_temp.rows(format($q$insert into expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by) values (%L,%L,'x',%L,'y',100,'EUR',%L)$q$, h,a,b,a)) = 'err:42501');
  PERFORM pg_temp.check('17c clients cannot change a household currency',
    pg_temp.rows(format($q$update households set currency = 'USD' where id = %L$q$, h)) = 'err:42501');
  PERFORM pg_temp.check('17d clients cannot rewrite an expense currency or amount',
    pg_temp.rows(format($q$update expenses set currency = 'USD' where id = %L$q$, e1::uuid)) = 'err:42501'
    AND pg_temp.rows(format($q$update expenses set amount_cents = 1 where id = %L$q$, e1::uuid)) = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17e a household currency must be a three-letter code',
    pg_temp.rows(format($q$update households set currency = 'euro' where id = %L$q$, h)) = 'err:23514');

  -- the schema allows another currency; the same one-currency rule applies to it
  PERFORM pg_temp.as_user(a); SELECT id INTO hu FROM create_household('CUR US'); PERFORM pg_temp.as_admin();
  UPDATE households SET currency = 'USD' WHERE id = hu;
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('11 a USD household accepts USD and rejects EUR',
    pg_temp.val(format($q$create_equal_split_expense(%L,'US ok',1000,'USD',%L,array[%L]::uuid[])$q$, hu,a,a)) !~ '^err:'
    AND pg_temp.val(format($q$create_equal_split_expense(%L,'EU bad',1000,'EUR',%L,array[%L]::uuid[])$q$, hu,a,a)) = 'err:HE008');

  -- ---------------- F13 idempotency ----------------
  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Keyed',2000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1));
  e2 := pg_temp.val(format($q$create_equal_split_expense(%L,'Keyed',2000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1));
  PERFORM pg_temp.check('13 a matching replay still returns the original', e1 !~ '^err:' AND e1 = e2, format('%s / %s', e1, e2));
  PERFORM pg_temp.check('14 the same key with another currency is HF002',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Keyed',2000,'USD',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1)) = 'err:HF002');
  PERFORM pg_temp.check('14b the same key with another amount is HF002',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Keyed',2001,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1)) = 'err:HF002');
  r := pg_temp.val(format($q$create_equal_split_expense(%L,'K2',2000,'USD',%L,array[%L]::uuid[],%L)$q$, h,a,a,k2))
    || pg_temp.val(format($q$create_equal_split_expense(%L,'K2',100000001,'EUR',%L,array[%L]::uuid[],%L)$q$, h,a,a,k2));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15 refused requests do not consume keys',
    r = 'err:HE008err:HE009' AND (SELECT count(*) = 0 FROM financial_operations WHERE request_id = k2), 'result='||r);
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('15a the same key then works with a valid payload',
    pg_temp.val(format($q$create_equal_split_expense(%L,'K2',2000,'EUR',%L,array[%L]::uuid[],%L)$q$, h,a,a,k2)) !~ '^err:');
  PERFORM pg_temp.as_user(b);
  r := pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'USD',null,%L))::text$q$, h,b,a,k3))
    || pg_temp.val(format($q$(create_settlement(%L,%L,%L,100000001,'EUR',null,%L))::text$q$, h,b,a,k3));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15b a refused settlement does not consume its key',
    r = 'err:HS009err:HS010' AND (SELECT count(*) = 0 FROM financial_operations WHERE request_id = k3), 'result='||r);
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('15c the settlement key then works with a valid payload',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR',null,%L))::text$q$, h,b,a,k3)) !~ '^err:');
  PERFORM pg_temp.check('14c a settlement key reused with another currency is HF002',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'USD',null,%L))::text$q$, h,b,a,k3)) = 'err:HF002');

  -- ---------------- earlier fixes still hold ----------------
  PERFORM pg_temp.as_user(u);
  PERFORM pg_temp.check('11b F3: a third party still cannot record a settlement',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR'))::text$q$, h,a,b)) = 'err:HS007');
  PERFORM pg_temp.check('12 F11: an unrelated member still cannot delete or rename an expense',
    pg_temp.rows(format($q$delete from expenses where id = %L$q$, e1::uuid)) = '0'
    AND pg_temp.rows(format($q$update expenses set title = 'x' where id = %L$q$, e1::uuid)) = '0');
  PERFORM pg_temp.as_user(c); PERFORM leave_household(h);
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('11c F3: a payment to a former member is still refused',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR'))::text$q$, h,a,c)) = 'err:HS008');

  -- ---------------- older clients and legacy data ----------------
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('18 six-argument named calls (older apps) still work',
    pg_temp.val(format($q$create_equal_split_expense(p_household_id => %L, p_title => 'old', p_amount_cents => 1000, p_currency => 'EUR', p_paid_by => %L, p_participant_ids => array[%L]::uuid[])$q$, h,a,a)) !~ '^err:');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('18b older settlement calls still work',
    pg_temp.val(format($q$(create_settlement(p_household_id => %L, p_from_user_id => %L, p_to_user_id => %L, p_amount_cents => 700, p_currency => 'EUR'))::text$q$, h,b,a)) !~ '^err:');

  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('16b a legacy over-cap expense can still be renamed by an authorized user (forward-only limit)',
    pg_temp.rows(format($q$update expenses set title = 'Legacy huge (renamed)' where id = %L$q$, legacy_big)) = '1');
  PERFORM pg_temp.as_admin();
  UPDATE expenses SET title = 'Legacy huge' WHERE id = legacy_big;
  PERFORM pg_temp.check('16 legacy USD, GBP and over-cap rows are unchanged and still readable',
    (SELECT row(x.*)::text FROM expenses x WHERE id = legacy_usd) = snap_usd
    AND (SELECT row(x.*)::text FROM expense_settlements x WHERE id = legacy_set) = snap_set
    AND (SELECT amount_cents = 250000000 AND currency = 'EUR' FROM expenses WHERE id = legacy_big));
END $$;

ROLLBACK;
