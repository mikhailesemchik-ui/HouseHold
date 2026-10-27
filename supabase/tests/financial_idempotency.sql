-- ============================================================
-- Financial operation idempotency tests (migration 20261031000001, finding F13)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/financial_idempotency.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Runs in one transaction and rolls back. Real concurrency is covered by
-- financial_idempotency_concurrency.sh (sequential calls cannot prove it).
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

-- Test-only trigger function (rolled back with everything else): fails for one participant.
CREATE FUNCTION public.audit_fail_participant() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF new.user_id = 'f5000000-0000-0000-0000-00000000000b' THEN
    RAISE EXCEPTION 'forced failure' USING ERRCODE = 'XX999';
  END IF;
  RETURN new;
END $$;

DO $$
DECLARE
  a  uuid := 'f5000000-0000-0000-0000-00000000000a'; -- owner, payer
  b  uuid := 'f5000000-0000-0000-0000-00000000000b';
  c  uuid := 'f5000000-0000-0000-0000-00000000000c'; -- leaves later
  u  uuid := 'f5000000-0000-0000-0000-00000000000d'; -- unrelated member
  x  uuid := 'f5000000-0000-0000-0000-00000000000e'; -- outsider
  h  uuid; h2 uuid; v_code text;
  k1 uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  k2 uuid := 'aaaaaaaa-0000-4000-8000-000000000002';
  k3 uuid := 'aaaaaaaa-0000-4000-8000-000000000003';
  k4 uuid := 'aaaaaaaa-0000-4000-8000-000000000004';
  k5 uuid := 'aaaaaaaa-0000-4000-8000-000000000005';
  k6 uuid := 'aaaaaaaa-0000-4000-8000-000000000006';
  k7 uuid := 'aaaaaaaa-0000-4000-8000-000000000007';
  k8 uuid := 'aaaaaaaa-0000-4000-8000-000000000008';
  k9 uuid := 'aaaaaaaa-0000-4000-8000-000000000009';
  e1 text; e2 text; s1 text; s2 text; r text; n int; before_n int;
  legacy_exp text; legacy_set text; lid uuid;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'id'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(u,4),(x,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'ID-'||i,'Id'||i FROM (VALUES (a,1),(b,2),(c,3),(u,4),(x,5)) v(id,i);
  PERFORM pg_temp.as_user(a); SELECT id INTO h FROM create_household('ID H1');
  SELECT id INTO h2 FROM create_household('ID H2');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(u); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(a); SELECT hi.code INTO v_code FROM create_household_invite(h2) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_admin();

  -- existing records that must stay untouched
  INSERT INTO expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
  VALUES (h,'Legacy',777,'EUR',a,'Id1',a) RETURNING id INTO lid;
  SELECT row(e.*)::text INTO legacy_exp FROM expenses e WHERE id = lid;
  INSERT INTO expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by)
  VALUES (h,b,'Id2',a,'Id1',300,'EUR',b) RETURNING id INTO lid;
  SELECT row(s.*)::text INTO legacy_set FROM expense_settlements s WHERE id = lid;

  -- ---------------- expenses ----------------
  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('1 first expense creation returns the new expense id',
    e1 !~ '^err:' AND (SELECT count(*) = 1 FROM expenses WHERE id = e1::uuid AND title = 'Groceries'), 'result='||e1);
  PERFORM pg_temp.check('18 stored operation has actor, household, kind, result and the canonical fingerprint',
    (SELECT actor_id = a AND household_id = h AND kind = 'expense' AND result_id = e1::uuid
        AND fingerprint = _expense_request_fingerprint(h,'Groceries',3000,'EUR',a,array[a,b]::uuid[])
        AND fingerprint ~ '^[0-9a-f]{64}$'
       FROM financial_operations WHERE request_id = k1));

  PERFORM pg_temp.as_user(a);
  e2 := pg_temp.val(format($q$create_equal_split_expense(%L,'  Groceries ',3000,'EUR',%L,array[%L,%L,%L]::uuid[],%L)$q$, h,a,b,a,b,k1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('2 same key and payload (reordered, repeated participants, padded title) returns the original',
    e2 = e1 AND (SELECT count(*) = 1 FROM expenses WHERE household_id = h AND title = 'Groceries')
    AND (SELECT count(*) = 2 FROM expense_participants WHERE expense_id = e1::uuid), 'result='||e2);

  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('4 same key, changed amount is rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3001,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1)) = 'err:HF002');
  PERFORM pg_temp.check('5 same key, changed participants is rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L]::uuid[],%L)$q$, h,a,a,k1)) = 'err:HF002');
  PERFORM pg_temp.check('6 same key, changed household is rejected',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h2,a,a,b,k1)) = 'err:HF002');
  PERFORM pg_temp.check('4b same key reused by a settlement is rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,100,'EUR',null,%L)).id$q$, h,a,b,k1)) = 'err:HF002');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('4c rejected replays created nothing',
    (SELECT count(*) = 1 FROM expenses WHERE household_id = h AND title = 'Groceries')
    AND (SELECT count(*) = 0 FROM expense_settlements WHERE household_id = h AND amount_cents = 100));

  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Coffee',500,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k2));
  e2 := pg_temp.val(format($q$create_equal_split_expense(%L,'Coffee',500,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k3));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('7 identical payloads with different keys are two legitimate records',
    e1 <> e2 AND e1 !~ '^err:' AND e2 !~ '^err:' AND (SELECT count(*) = 2 FROM expenses WHERE household_id = h AND title = 'Coffee'));

  -- same UUID used by different actors stays isolated
  PERFORM pg_temp.as_user(b);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,b,a,b,k1));
  e2 := pg_temp.val(format($q$create_equal_split_expense(%L,'Other thing',99,'EUR',%L,array[%L]::uuid[],%L)$q$, h,b,b,k1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('8/16 the same UUID under another actor is its own operation; no disclosure of the first',
    e1 !~ '^err:' AND e2 = 'err:HF002'
    AND (SELECT count(*) = 2 FROM financial_operations WHERE request_id = k1)
    AND (SELECT created_by = b FROM expenses WHERE id = e1::uuid), format('e1=%s e2=%s', e1, e2));

  -- outsider replay
  PERFORM pg_temp.as_user(x);
  r := pg_temp.val(format($q$create_equal_split_expense(%L,'Groceries',3000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('9 an outsider cannot replay or probe a key', r = 'err:HE001', 'result='||r);

  -- key table is not reachable by clients
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('16b clients cannot read the operations table', pg_temp.val($q$(select count(*) from financial_operations)$q$) = 'err:42501');
  PERFORM pg_temp.check('16c clients cannot write the operations table',
    pg_temp.rows(format($q$insert into financial_operations(actor_id,request_id,household_id,kind,fingerprint,result_id) values (%L,gen_random_uuid(),%L,'expense',repeat('0',64),gen_random_uuid())$q$, a, h)) = 'err:42501');
  PERFORM pg_temp.as_admin();

  -- validation failures do not claim a key
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('17 an invalid payload fails and leaves no operation or record',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Bad',0,'EUR',%L,array[%L]::uuid[],%L)$q$, h,a,a,k4)) = 'err:HE003');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17b nothing stored for the rejected key',
    (SELECT count(*) = 0 FROM financial_operations WHERE request_id = k4)
    AND (SELECT count(*) = 0 FROM expenses WHERE title = 'Bad'));

  -- atomic rollback when participant creation fails
  EXECUTE 'CREATE TRIGGER audit_fail_participant BEFORE INSERT ON expense_participants FOR EACH ROW EXECUTE FUNCTION public.audit_fail_participant()';
  PERFORM pg_temp.as_user(a);
  r := pg_temp.val(format($q$create_equal_split_expense(%L,'Atomic',2000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k5));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('10 participant failure rolls back expense and key together',
    r = 'err:XX999' AND (SELECT count(*) = 0 FROM expenses WHERE title = 'Atomic')
    AND (SELECT count(*) = 0 FROM financial_operations WHERE request_id = k5)
    AND (SELECT count(*) = 0 FROM expense_participants ep JOIN expenses e ON e.id = ep.expense_id WHERE e.title = 'Atomic'), 'result='||r);
  EXECUTE 'DROP TRIGGER audit_fail_participant ON expense_participants';
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('10b after the cause is fixed the same key succeeds',
    pg_temp.val(format($q$create_equal_split_expense(%L,'Atomic',2000,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,a,a,b,k5)) !~ '^err:');
  PERFORM pg_temp.as_admin();

  -- replay after deletion and after the payer left
  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Doomed',1200,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,c,a,c,k6));
  DELETE FROM expenses WHERE id = e1::uuid;
  r := pg_temp.val(format($q$create_equal_split_expense(%L,'Doomed',1200,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,c,a,c,k6));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('11 replay after deletion is refused and recreates nothing',
    r = 'err:HF003' AND (SELECT count(*) = 0 FROM expenses WHERE title = 'Doomed')
    AND (SELECT count(*) = 1 FROM financial_operations WHERE request_id = k6 AND result_id = e1::uuid), 'result='||r);

  PERFORM pg_temp.as_user(a);
  e1 := pg_temp.val(format($q$create_equal_split_expense(%L,'Payer leaves',900,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,c,a,c,k7));
  PERFORM pg_temp.as_user(c); PERFORM leave_household(h);
  PERFORM pg_temp.as_user(a);
  e2 := pg_temp.val(format($q$create_equal_split_expense(%L,'Payer leaves',900,'EUR',%L,array[%L,%L]::uuid[],%L)$q$, h,c,a,c,k7));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('2b a replay still returns the original after the payer left',
    e2 = e1 AND (SELECT count(*) = 1 FROM expenses WHERE title = 'Payer leaves'), format('e1=%s e2=%s', e1, e2));

  -- ---------------- settlements ----------------
  PERFORM pg_temp.as_user(b);
  s1 := pg_temp.val(format($q$(create_settlement(%L,%L,%L,1000,'EUR','cash',%L)).id$q$, h,b,a,k8));
  s2 := pg_temp.val(format($q$(create_settlement(%L,%L,%L,1000,'EUR','cash',%L)).id$q$, h,b,a,k8));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('3 settlement retry with the same key returns the same record',
    s1 = s2 AND s1 !~ '^err:' AND (SELECT count(*) = 1 FROM expense_settlements WHERE household_id = h AND amount_cents = 1000), format('s1=%s s2=%s', s1, s2));
  PERFORM pg_temp.check('18b settlement operation stores result and fingerprint',
    (SELECT result_id = s1::uuid AND kind = 'settlement'
        AND fingerprint = _settlement_request_fingerprint(h,b,a,1000,'EUR','cash')
       FROM financial_operations WHERE actor_id = b AND request_id = k8));
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('4d settlement key with a changed amount is rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,1001,'EUR','cash',%L)).id$q$, h,b,a,k8)) = 'err:HF002');
  PERFORM pg_temp.check('4e settlement key with a changed note is rejected',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,1000,'EUR',null,%L)).id$q$, h,b,a,k8)) = 'err:HF002');
  s2 := pg_temp.val(format($q$(create_settlement(%L,%L,%L,1000,'EUR','cash',%L)).id$q$, h,b,a,k9));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('7b identical settlement with another key is a separate record', s2 <> s1 AND s2 !~ '^err:');
  PERFORM pg_temp.as_user(b);
  DELETE FROM expense_settlements WHERE id = s1::uuid;
  r := pg_temp.val(format($q$(create_settlement(%L,%L,%L,1000,'EUR','cash',%L)).id$q$, h,b,a,k8));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('12 settlement replay after deletion is refused', r = 'err:HF003' AND (SELECT count(*) = 1 FROM expense_settlements WHERE id = s2::uuid), 'result='||r);

  -- ---------------- older clients and earlier fixes ----------------
  PERFORM pg_temp.as_user(a);
  SELECT count(*) INTO before_n FROM expenses WHERE household_id = h;
  PERFORM pg_temp.val(format($q$create_equal_split_expense(%L,'No key',100,'EUR',%L,array[%L]::uuid[])$q$, h,a,a));
  PERFORM pg_temp.val(format($q$create_equal_split_expense(%L,'No key',100,'EUR',%L,array[%L]::uuid[])$q$, h,a,a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('13 calls without a request id work as before (older clients), including both retries',
    (SELECT count(*) = before_n + 2 FROM expenses WHERE household_id = h)
    AND (SELECT count(*) = 0 FROM financial_operations WHERE household_id = h AND result_id IN (SELECT id FROM expenses WHERE title = 'No key')));
  PERFORM pg_temp.check('13b function signatures: one overload each, no ambiguity',
    (SELECT count(*) = 1 FROM pg_proc WHERE proname = 'create_equal_split_expense')
    AND (SELECT count(*) = 1 FROM pg_proc WHERE proname = 'create_settlement'));

  PERFORM pg_temp.as_user(u);
  PERFORM pg_temp.check('14 F3: a third party still cannot record a settlement, even with a key',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR',null,gen_random_uuid())).id$q$, h,a,b)) = 'err:HS007');
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('14b F3: a payment to a former member is still refused',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR',null,gen_random_uuid())).id$q$, h,a,c)) = 'err:HS008');
  PERFORM pg_temp.check('14c F3: a payment received from a former member is allowed',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,500,'EUR',null,gen_random_uuid())).id$q$, h,c,a)) !~ '^err:');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('14d refused settlements claimed no keys', (SELECT count(*) = 3 FROM financial_operations WHERE kind = 'settlement' AND actor_id IN (a,b,u)));

  PERFORM pg_temp.as_user(u);
  PERFORM pg_temp.check('15 F11: an unrelated member still cannot delete or rename an expense',
    pg_temp.rows(format($q$delete from expenses where household_id = %L and title = 'Coffee'$q$, h)) = '0'
    AND pg_temp.rows(format($q$update expenses set title = 'x' where household_id = %L and title = 'Coffee'$q$, h)) = '0');
  PERFORM pg_temp.as_admin();

  PERFORM pg_temp.check('existing expense and settlement rows are unchanged',
    (SELECT row(e.*)::text FROM expenses e WHERE title = 'Legacy' AND household_id = h) = legacy_exp
    AND (SELECT row(s.*)::text FROM expense_settlements s WHERE amount_cents = 300 AND household_id = h) = legacy_set);
END $$;

ROLLBACK;
