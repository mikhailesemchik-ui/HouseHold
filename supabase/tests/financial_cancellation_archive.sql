-- ============================================================
-- Financial cancellation archive tests (migration 20261102000001, finding F4)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/financial_cancellation_archive.sql
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

DO $$
DECLARE
  a  uuid := 'f9000000-0000-0000-0000-00000000000a'; -- owner
  b  uuid := 'f9000000-0000-0000-0000-00000000000b'; -- payer / sender
  c  uuid := 'f9000000-0000-0000-0000-00000000000c'; -- participant / recipient
  d  uuid := 'f9000000-0000-0000-0000-00000000000d'; -- unrelated member
  x  uuid := 'f9000000-0000-0000-0000-00000000000e'; -- other household
  h uuid; hx uuid; v_code text;
  e1 uuid; e2 uuid; e3 uuid; e4 uuid; e5 uuid; s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid;
  k1 uuid := 'dddddddd-0000-4000-8000-000000000001';
  k2 uuid := 'dddddddd-0000-4000-8000-000000000002';
  r text; before_other text; snap_s text; arch financial_archive;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'arc'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(d,4),(x,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'ARC-'||i,'Arc'||i FROM (VALUES (a,1),(b,2),(c,3),(d,4),(x,5)) v(id,i);
  PERFORM pg_temp.as_user(a); SELECT id INTO h FROM create_household('ARC H');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(d); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(x); SELECT id INTO hx FROM create_household('ARC X');

  -- b creates and pays; a (owner) creates one paid by c; settlements
  PERFORM pg_temp.as_user(b);
  e1 := (create_equal_split_expense(h,'Dinner',1001,'EUR',b,array[b,c],k1));
  PERFORM pg_temp.as_user(a);
  e2 := (create_equal_split_expense(h,'Rent',3000,'EUR',c,array[a,b,c]));
  PERFORM pg_temp.as_user(c);
  e3 := (create_equal_split_expense(h,'Owner target',500,'EUR',c,array[b,c]));
  e4 := (create_equal_split_expense(h,'Payer test',700,'EUR',c,array[b,c]));
  e5 := (create_equal_split_expense(h,'Unrelated',900,'EUR',c,array[b,c]));
  PERFORM pg_temp.as_user(c); s1 := (create_settlement(h,c,b,400,'EUR',null,k2)).id;
  PERFORM pg_temp.as_user(b); s2 := (create_settlement(h,b,c,300,'EUR')).id;
  PERFORM pg_temp.as_user(c); s3 := (create_settlement(h,c,a,200,'EUR')).id;
  PERFORM pg_temp.as_user(c); s5 := (create_settlement(h,c,b,150,'EUR')).id;
  PERFORM pg_temp.as_admin();
  -- legacy third-party settlement: created_by is neither sender nor recipient
  INSERT INTO expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by)
  VALUES (h,b,'Arc2',c,'Arc3',100,'EUR',d) RETURNING id INTO s4;

  PERFORM pg_temp.check('00 setup: no archive rows yet', (SELECT count(*) FROM financial_archive WHERE household_id = h) = 0);
  PERFORM pg_temp.check('00b archive table is not in any client write grant',
    NOT has_table_privilege('authenticated','financial_archive','INSERT')
    AND NOT has_table_privilege('authenticated','financial_archive','UPDATE')
    AND NOT has_table_privilege('authenticated','financial_archive','DELETE')
    AND has_table_privilege('authenticated','financial_archive','SELECT'));

  -- Expense cancellation: authorization
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('04 an unrelated member cannot cancel an expense',
    pg_temp.val(format('(cancel_expense(%L)).id', e5)) = 'err:HC002'
    AND (SELECT count(*) FROM expenses WHERE id = e5) = 1);
  PERFORM pg_temp.check('04b an unrelated member cannot directly DELETE an expense',
    pg_temp.rows(format('delete from expenses where id = %L', e5)) = '0');
  PERFORM pg_temp.as_user(x);
  PERFORM pg_temp.check('16 another household cannot cancel or read anything',
    pg_temp.val(format('(cancel_expense(%L)).id', e5)) = 'err:HC001'
    AND pg_temp.val(format('(cancel_settlement(%L)).id', s5)) = 'err:HC001');

  PERFORM pg_temp.as_user(b);
  arch := cancel_expense(e1, '  typo in amount  ');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('01 the expense creator can cancel; a full snapshot is archived',
    arch.kind = 'expense' AND arch.record_id = e1 AND arch.household_id = h
    AND arch.canceled_by = b AND arch.reason = 'typo in amount'
    AND (arch.snapshot->>'title') = 'Dinner' AND (arch.snapshot->>'amount_cents') = '1001'
    AND (arch.snapshot->>'currency') = 'EUR' AND (arch.snapshot->>'paid_by') = b::text
    AND (arch.snapshot->>'created_by') = b::text
    AND jsonb_array_length(arch.snapshot->'participants') = 2
    AND (SELECT sum((p->>'share_cents')::int) FROM jsonb_array_elements(arch.snapshot->'participants') p) = 1001
    AND NOT EXISTS (SELECT 1 FROM expenses WHERE id = e1));
  PERFORM pg_temp.check('10 participant snapshot keeps each member and share',
    (SELECT count(*) FROM jsonb_array_elements(arch.snapshot->'participants') p
       WHERE (p->>'user_id') IN (b::text, c::text)) = 2);
  PERFORM pg_temp.check('12 the actor name and database time are recorded',
    arch.canceled_by_name = 'Arc2' AND arch.canceled_at BETWEEN now() - interval '1 minute' AND now() + interval '1 minute');

  -- payer (c) of an expense created by someone else (a)
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('02 the payer who did not create the expense can cancel it',
    pg_temp.val(format('(cancel_expense(%L)).canceled_by', e2)) = c::text);
  -- owner (a) cancels an expense created and paid by c
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('03 the household owner can cancel any expense',
    pg_temp.val(format('(cancel_expense(%L)).canceled_by', e3)) = a::text);
  PERFORM pg_temp.as_admin();

  -- Settlements: sender, recipient, owner, legacy creator, unrelated
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('09 an unrelated member cannot cancel a settlement',
    pg_temp.val(format('(cancel_settlement(%L)).id', s5)) = 'err:HC002'
    AND pg_temp.rows(format('delete from expense_settlements where id = %L', s5)) = '0');
  PERFORM pg_temp.check('08 the creator of a legacy third-party settlement can cancel it',
    pg_temp.val(format('(cancel_settlement(%L, %L)).canceled_by', s4, 'recorded by mistake')) = d::text);
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('05 the sender can cancel their settlement',
    pg_temp.val(format('(cancel_settlement(%L)).canceled_by', s1)) = c::text);
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('06 the recipient can cancel a settlement',
    pg_temp.val(format('(cancel_settlement(%L)).canceled_by', s2)) = c::text);
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('07 the owner can cancel a settlement between other members',
    pg_temp.val(format('(cancel_settlement(%L)).canceled_by', s5)) = a::text);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('11 the settlement snapshot keeps parties, amount, currency and author',
    (SELECT snapshot->>'from_user_id' = c::text AND snapshot->>'to_user_id' = b::text
       AND snapshot->>'amount_cents' = '150' AND snapshot->>'currency' = 'EUR'
       AND snapshot->>'created_by' = c::text AND reason IS NULL
     FROM financial_archive WHERE kind = 'settlement' AND record_id = s5));
  PERFORM pg_temp.check('13 a given reason is stored, and no reason stays null',
    (SELECT reason FROM financial_archive WHERE record_id = s4) = 'recorded by mistake'
    AND (SELECT reason IS NULL FROM financial_archive WHERE record_id = s5));

  -- 20/21: cancelling one record never cancels another
  PERFORM pg_temp.check('20 cancelling an expense leaves every other settlement in place',
    (SELECT count(*) FROM expense_settlements WHERE id = s3) = 1);
  PERFORM pg_temp.check('21 cancelling settlements leaves their related expenses in place',
    (SELECT count(*) FROM expenses WHERE id IN (e4, e5)) = 2);

  -- 14: old-client direct DELETE still deletes and archives; no forged reason
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('14 a direct DELETE by an authorized old client still deletes the row',
    pg_temp.rows(format('delete from expenses where id = %L', e4)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('14b ... and archives it with the real actor and no reason',
    (SELECT canceled_by = c AND reason IS NULL AND kind = 'expense'
            AND jsonb_array_length(snapshot->'participants') = 2
     FROM financial_archive WHERE record_id = e4));
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('14c a direct DELETE of a settlement by its sender archives it',
    pg_temp.rows(format('delete from expense_settlements where id = %L', s3)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('14d ... with the real actor and no reason',
    (SELECT canceled_by = c AND reason IS NULL FROM financial_archive WHERE record_id = s3));

  -- 15: archive is immutable and not client-writable
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('15 clients cannot insert, update or delete archive rows',
    pg_temp.rows(format($q$insert into financial_archive(kind,record_id,household_id,snapshot,canceled_by_name) values ('expense',%L,%L,'{}','x')$q$, gen_random_uuid(), h)) = 'err:42501'
    AND pg_temp.rows($q$update financial_archive set reason = 'x'$q$) = 'err:42501'
    AND pg_temp.rows($q$delete from financial_archive$q$) = 'err:42501');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15b even an administrator cannot update, delete or truncate archive rows',
    pg_temp.rows($q$update financial_archive set reason = 'x'$q$) = 'err:HC003'
    AND pg_temp.rows($q$delete from financial_archive$q$) = 'err:HC003'
    AND pg_temp.rows($q$truncate financial_archive$q$) = 'err:HC003');

  -- 16/17: isolation and former-member behaviour
  PERFORM pg_temp.as_user(x);
  PERFORM pg_temp.check('16b another household sees no archive rows',
    (SELECT count(*) FROM financial_archive) = 0);
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('16c every active member sees their household archive',
    (SELECT count(*) FROM financial_archive WHERE household_id = h) = 9);
  PERFORM pg_temp.as_user(a); PERFORM remove_household_member(h, d);
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('17 a former member can no longer read the archive or cancel',
    (SELECT count(*) FROM financial_archive) = 0
    AND pg_temp.val(format('(cancel_settlement(%L)).id', s5)) = 'err:HC001');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17b the former member remains the recorded actor of their cancellation',
    (SELECT canceled_by = d AND canceled_by_name = 'Arc4' FROM financial_archive WHERE record_id = s4));

  -- 18/19: repeat cancellation
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('18 repeating a cancel returns the original result unchanged',
    (SELECT (cancel_expense(e1, 'different reason')).canceled_by) = b);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('18b ... without a second row, new reason or new actor',
    (SELECT count(*) FROM financial_archive WHERE record_id = e1) = 1
    AND (SELECT reason FROM financial_archive WHERE record_id = e1) = 'typo in amount');
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('18c a different active member repeating it sees the original actor',
    (SELECT (cancel_expense(e1)).canceled_by) = b);
  PERFORM pg_temp.check('19 a refused cancel raises and leaves no archive row',
    pg_temp.val(format('(cancel_expense(%L)).id', gen_random_uuid())) = 'err:HC001'
    AND pg_temp.val(format('(cancel_expense(%L, %L)).id', e5, repeat('x', 201))) = 'err:HC004');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('19b ... and the target still exists',
    (SELECT count(*) FROM expenses WHERE id = e5) = 1
    AND NOT EXISTS (SELECT 1 FROM financial_archive WHERE record_id = e5));

  -- 22/23: F13 keys
  PERFORM pg_temp.check('22 the original request keys stay reserved after cancellation',
    (SELECT count(*) FROM financial_operations WHERE request_id IN (k1, k2)) = 2);
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('23 replaying the cancelled expense request returns HF003 and creates nothing',
    pg_temp.val(format($q$(create_equal_split_expense(%L,'Dinner',1001,'EUR',%L,array[%L,%L]::uuid[],%L))$q$, h,b,b,c,k1)) = 'err:HF003'
    AND (SELECT count(*) FROM expenses WHERE title = 'Dinner') = 0);
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('23b replaying the cancelled settlement request returns HF003',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,400,'EUR',null,%L)).id$q$, h,c,b,k2)) = 'err:HF003');

  -- 24: previous restrictions
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('24 F3 and F12 limits still hold',
    pg_temp.val(format($q$(create_settlement(%L,%L,%L,100,'EUR')).id$q$, h,c,a)) LIKE 'err:HS%'
    AND pg_temp.val(format($q$(create_equal_split_expense(%L,'Big',100000001,'EUR',%L,array[%L]::uuid[]))$q$, h,b,b)) = 'err:HE009'
    AND pg_temp.val(format($q$(create_equal_split_expense(%L,'USD',100,'USD',%L,array[%L]::uuid[]))$q$, h,b,b)) = 'err:HE008');

  -- 27/25: events and unrelated rows
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('27 each cancelled expense logs exactly one deleted event; retries add none',
    (SELECT count(*) FROM household_events WHERE entity_id = e1 AND event_type = 'expense_deleted') = 1);
  PERFORM pg_temp.check('25 no unrelated record changed',
    (SELECT count(*) FROM expenses WHERE household_id = h) = 1
    AND (SELECT count(*) FROM expense_settlements WHERE household_id = h) = 0
    AND (SELECT count(*) FROM expense_participants WHERE expense_id = e5) = 2);

  -- 26/28: cascades are not archived; live tables hold only active rows
  PERFORM pg_temp.check('26 a cascading delete is not archived (and cannot be blocked by the archive)',
    pg_temp.rows(format('delete from expense_participants where expense_id = %L', e5)) = '2'
    AND (SELECT count(*) FROM financial_archive WHERE record_id = e5) = 0);
  PERFORM pg_temp.check('28 the live tables contain only active rows (balances = remaining rows)',
    (SELECT count(*) FROM expenses WHERE id IN (e1,e2,e3,e4)) = 0
    AND (SELECT count(*) FROM expense_settlements WHERE id IN (s1,s2,s3,s4,s5)) = 0);
END $$;

ROLLBACK;
