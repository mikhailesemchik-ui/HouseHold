-- ============================================================
-- Expense permission and shopping attribution tests (migration 20261029000001, finding F11)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/expense_shopping_integrity.sql
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

-- Runs a DML statement and returns the affected row count as text, or 'err:<SQLSTATE>'.
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
  o uuid := 'f3000000-0000-0000-0000-00000000000a'; -- household owner
  c uuid := 'f3000000-0000-0000-0000-00000000000b'; -- expense creator
  p uuid := 'f3000000-0000-0000-0000-00000000000c'; -- payer
  q uuid := 'f3000000-0000-0000-0000-00000000000d'; -- participant only
  u uuid := 'f3000000-0000-0000-0000-00000000000e'; -- unrelated active member
  x uuid := 'f3000000-0000-0000-0000-00000000000f'; -- outsider (other household)
  h1 uuid; h2 uuid; v_code text;
  e uuid; e_del_c uuid; e_del_p uuid; e_del_o uuid; e_keep uuid; e_legacy uuid;
  s1 uuid; s_legacy uuid; legacy_exp text; legacy_item text; r text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'ex'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (o,1),(c,2),(p,3),(q,4),(u,5),(x,6)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'EX-'||i,'Ex'||i FROM (VALUES (o,1),(c,2),(p,3),(q,4),(u,5),(x,6)) v(id,i);
  PERFORM pg_temp.as_user(o); SELECT id INTO h1 FROM create_household('EX H1');
  SELECT hi.code INTO v_code FROM create_household_invite(h1) hi;
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(p); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(q); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(u); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(x); SELECT id INTO h2 FROM create_household('EX H2');

  -- creator c records expenses paid by p, shared by p and q (c and o are not participants)
  PERFORM pg_temp.as_user(c);
  PERFORM create_equal_split_expense(h1,'Groceries',3000,'EUR',p,array[p,q]);
  PERFORM create_equal_split_expense(h1,'Del by creator',1000,'EUR',p,array[p,q]);
  PERFORM create_equal_split_expense(h1,'Del by payer',1000,'EUR',p,array[p,q]);
  PERFORM create_equal_split_expense(h1,'Del by owner',1000,'EUR',p,array[p,q]);
  PERFORM create_equal_split_expense(h1,'Keep',1000,'EUR',p,array[p,q]);
  PERFORM pg_temp.as_admin();
  SELECT id INTO e FROM expenses WHERE household_id=h1 AND title='Groceries';
  SELECT id INTO e_del_c FROM expenses WHERE household_id=h1 AND title='Del by creator';
  SELECT id INTO e_del_p FROM expenses WHERE household_id=h1 AND title='Del by payer';
  SELECT id INTO e_del_o FROM expenses WHERE household_id=h1 AND title='Del by owner';
  SELECT id INTO e_keep FROM expenses WHERE household_id=h1 AND title='Keep';

  PERFORM pg_temp.check('creation stays collaborative: created_by and paid_by are distinct',
    (SELECT created_by = c AND paid_by = p FROM expenses WHERE id = e));

  -- a legacy expense and shopping item that must stay untouched
  INSERT INTO expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
  VALUES (h1,'Legacy',777,'EUR',o,'Ex1',o) RETURNING id INTO e_legacy;
  SELECT row(x.*)::text INTO legacy_exp FROM expenses x WHERE id = e_legacy;

  -- ---------------- title edit ----------------
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('1 creator edits title', pg_temp.rows(format($q$update expenses set title='by creator' where id=%L$q$, e)) = '1');
  PERFORM pg_temp.as_user(p);
  PERFORM pg_temp.check('2 payer edits title', pg_temp.rows(format($q$update expenses set title='by payer' where id=%L$q$, e)) = '1');
  PERFORM pg_temp.as_user(q);
  PERFORM pg_temp.check('3 participant edits title', pg_temp.rows(format($q$update expenses set title='by participant' where id=%L$q$, e)) = '1');
  PERFORM pg_temp.as_user(o);
  PERFORM pg_temp.check('4 owner edits title', pg_temp.rows(format($q$update expenses set title='by owner' where id=%L$q$, e)) = '1');
  PERFORM pg_temp.as_user(u);
  r := pg_temp.rows(format($q$update expenses set title='hijacked' where id=%L$q$, e));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('5 unrelated active member cannot edit title',
    r <> '1' AND (SELECT title FROM expenses WHERE id = e) = 'by owner', 'result='||r);
  PERFORM pg_temp.as_user(x);
  r := pg_temp.rows(format($q$update expenses set title='hijacked' where id=%L$q$, e));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('6 outsider cannot edit title', r <> '1' AND (SELECT title FROM expenses WHERE id = e) = 'by owner', 'result='||r);

  -- ---------------- delete ----------------
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('7 creator deletes', pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_del_c)) = '1');
  PERFORM pg_temp.as_user(p);
  PERFORM pg_temp.check('8 payer deletes', pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_del_p)) = '1');
  PERFORM pg_temp.as_user(o);
  PERFORM pg_temp.check('9 owner deletes', pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_del_o)) = '1');
  PERFORM pg_temp.as_user(u);
  r := pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_keep));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('10 unrelated active member cannot delete', r <> '1' AND EXISTS (SELECT 1 FROM expenses WHERE id = e_keep), 'result='||r);
  PERFORM pg_temp.as_user(q);
  r := pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_keep));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('10b participant (not creator/payer/owner) cannot delete', r <> '1' AND EXISTS (SELECT 1 FROM expenses WHERE id = e_keep), 'result='||r);
  PERFORM pg_temp.as_user(x);
  r := pg_temp.rows(format($q$delete from expenses where id=%L$q$, e_keep));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('11 cross-household user cannot delete', r <> '1' AND EXISTS (SELECT 1 FROM expenses WHERE id = e_keep), 'result='||r);
  -- an owner of another household has no power here either
  PERFORM pg_temp.as_user(x);
  r := pg_temp.rows(format($q$update expenses set title='x' where id=%L$q$, e_keep));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('11b other household owner cannot edit', r <> '1', 'result='||r);

  -- ---------------- immutable fields (authorized user, direct PostgREST-style update) ----------------
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('12a amount_cents immutable', pg_temp.rows(format($q$update expenses set amount_cents=1 where id=%L$q$, e)) LIKE 'err:%');
  PERFORM pg_temp.check('12b currency immutable', pg_temp.rows(format($q$update expenses set currency='USD' where id=%L$q$, e)) LIKE 'err:%');
  PERFORM pg_temp.check('12c paid_by immutable', pg_temp.rows(format($q$update expenses set paid_by=%L where id=%L$q$, c, e)) LIKE 'err:%');
  PERFORM pg_temp.check('12d created_by immutable', pg_temp.rows(format($q$update expenses set created_by=%L where id=%L$q$, p, e)) LIKE 'err:%');
  PERFORM pg_temp.check('13 paid_by_display_name immutable',
    pg_temp.rows(format($q$update expenses set paid_by_display_name='Someone Else' where id=%L$q$, e)) LIKE 'err:%');
  PERFORM pg_temp.as_admin();
  -- second layer: the guard trigger also stops writers that have column privileges (e.g. an admin session)
  PERFORM pg_temp.check('13b guard trigger pins paid_by_display_name',
    pg_temp.rows(format($q$update expenses set paid_by_display_name='Someone Else' where id=%L$q$, e)) = 'err:HO029');
  PERFORM pg_temp.check('12e guard trigger pins amount_cents',
    pg_temp.rows(format($q$update expenses set amount_cents=1 where id=%L$q$, e)) = 'err:HO025');
  PERFORM pg_temp.check('12f amounts and identities really unchanged',
    (SELECT amount_cents = 3000 AND currency = 'EUR' AND paid_by = p AND created_by = c AND paid_by_display_name = 'Ex3'
       FROM expenses WHERE id = e));

  -- ---------------- shopping completion attribution ----------------
  PERFORM pg_temp.as_user(c);
  INSERT INTO shopping_items (household_id,name,created_by) VALUES (h1,'milk',c) RETURNING id INTO s1;
  PERFORM pg_temp.as_admin();
  INSERT INTO shopping_items (household_id,name,created_by,completed_at,completed_by)
  VALUES (h1,'legacy done',o,now()-interval '3 days',o) RETURNING id INTO s_legacy;
  SELECT row(i.*)::text INTO legacy_item FROM shopping_items i WHERE id = s_legacy;

  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('14 normal completion by the actor',
    pg_temp.rows(format($q$update shopping_items set completed_at=now(), completed_by=%L where id=%L$q$, c, s1)) = '1');
  PERFORM pg_temp.as_user(u);
  r := pg_temp.rows(format($q$update shopping_items set completed_by=%L where id=%L$q$, u, s1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17 spoofing completed_by on a completed item is denied',
    r = 'err:SH003' AND (SELECT completed_by = c FROM shopping_items WHERE id = s1), 'result='||r);
  PERFORM pg_temp.as_user(u);
  r := pg_temp.rows(format($q$update shopping_items set completed_at=now()+interval '1 day' where id=%L$q$, s1));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17b rewriting completed_at on a completed item is denied', r = 'err:SH003', 'result='||r);
  PERFORM pg_temp.as_user(u);
  PERFORM pg_temp.check('17c renaming a completed item still works',
    pg_temp.rows(format($q$update shopping_items set name='oat milk' where id=%L$q$, s1)) = '1');
  PERFORM pg_temp.check('15 normal reopening by any member',
    pg_temp.rows(format($q$update shopping_items set completed_at=null, completed_by=null where id=%L$q$, s1)) = '1');
  PERFORM pg_temp.check('17d completing on behalf of someone else is denied',
    pg_temp.rows(format($q$update shopping_items set completed_at=now(), completed_by=%L where id=%L$q$, c, s1)) = 'err:SH001');
  PERFORM pg_temp.check('16 recompletion by a different member',
    pg_temp.rows(format($q$update shopping_items set completed_at=now(), completed_by=%L where id=%L$q$, u, s1)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('16b recompletion is attributed to the new actor',
    (SELECT completed_by = u FROM shopping_items WHERE id = s1));

  -- ---------------- existing records preserved ----------------
  PERFORM pg_temp.check('18 legacy expense row unchanged', (SELECT row(x.*)::text FROM expenses x WHERE id = e_legacy) = legacy_exp);
  PERFORM pg_temp.check('18b legacy completed shopping row unchanged', (SELECT row(i.*)::text FROM shopping_items i WHERE id = s_legacy) = legacy_item);
  PERFORM pg_temp.check('18c participants and amounts of the edited expense preserved',
    (SELECT count(*) = 2 AND sum(share_cents) = 3000 FROM expense_participants WHERE expense_id = e));
END $$;

ROLLBACK;
