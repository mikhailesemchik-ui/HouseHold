-- ============================================================
-- Settlement authorization tests (migration 20261028000001, finding F3)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/settlement_authorization.sql
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

-- Runs a statement; returns the SQLSTATE of the failure, or 'ok'.
CREATE FUNCTION pg_temp.outcome(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

CREATE FUNCTION pg_temp.net(p_hh uuid, p_user uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce((SELECT sum(amount_cents) FROM expenses WHERE household_id = p_hh AND paid_by = p_user), 0)
       - coalesce((SELECT sum(ep.share_cents) FROM expense_participants ep
                   JOIN expenses e ON e.id = ep.expense_id
                   WHERE e.household_id = p_hh AND ep.user_id = p_user), 0)
       + coalesce((SELECT sum(amount_cents) FROM expense_settlements WHERE household_id = p_hh AND from_user_id = p_user), 0)
       - coalesce((SELECT sum(amount_cents) FROM expense_settlements WHERE household_id = p_hh AND to_user_id = p_user), 0);
$$;

DO $$
DECLARE
  a uuid := 'f2000000-0000-0000-0000-00000000000a'; -- owner
  b uuid := 'f2000000-0000-0000-0000-00000000000b'; -- member
  c uuid := 'f2000000-0000-0000-0000-00000000000c'; -- member, later leaves
  d uuid := 'f2000000-0000-0000-0000-00000000000d'; -- outsider (other household)
  h1 uuid; h2 uuid; v_code text; legacy uuid; legacy_before text; s text;
  net_a bigint; net_b bigint; n_before int;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'st'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(d,4)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'ST-'||i,'St'||i FROM (VALUES (a,1),(b,2),(c,3),(d,4)) v(id,i);
  PERFORM pg_temp.as_user(a); SELECT id INTO h1 FROM create_household('ST H1');
  SELECT hi.code INTO v_code FROM create_household_invite(h1) hi;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(d); SELECT id INTO h2 FROM create_household('ST H2');
  PERFORM pg_temp.as_admin();

  -- a settlement recorded before the fix by an unrelated member must stay untouched
  INSERT INTO expense_settlements (household_id,from_user_id,from_name,to_user_id,to_name,amount_cents,currency,created_by)
  VALUES (h1,b,'St2',c,'St3',700,'EUR',a) RETURNING id INTO legacy;
  SELECT row(es.*)::text INTO legacy_before FROM expense_settlements es WHERE id = legacy;

  -- Dinner: a paid 90.00, split a,b,c => net a=+6000, b=-3000, c=-3000 (before settlements, ignoring legacy 700)
  PERFORM pg_temp.as_user(a);
  PERFORM create_equal_split_expense(h1,'Dinner',9000,'EUR',a,array[a,b,c]);
  PERFORM pg_temp.as_admin();
  net_a := pg_temp.net(h1,a); net_b := pg_temp.net(h1,b);

  -- sender records
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('sender b records b->a 1000',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,1000,'EUR')$q$, h1,b,a)) = 'ok');
  -- recipient records
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('recipient a records c->a 500',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,500,'EUR')$q$, h1,c,a)) = 'ok');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('balances move by exactly the recorded amounts',
    pg_temp.net(h1,a) = net_a - 1000 - 500 AND pg_temp.net(h1,b) = net_b + 1000,
    format('a=%s b=%s', pg_temp.net(h1,a), pg_temp.net(h1,b)));

  -- unrelated third member
  PERFORM pg_temp.as_user(c); SELECT count(*) INTO n_before FROM expense_settlements WHERE household_id = h1;
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,5000,'EUR','forged')$q$, h1,a,b));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('unrelated member c cannot record a->b', s <> 'ok' AND
    (SELECT count(*) FROM expense_settlements WHERE household_id = h1) = n_before, 'sqlstate='||s);

  -- owner cannot fabricate a payment between two others
  PERFORM pg_temp.as_user(a);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,5000,'EUR')$q$, h1,b,c));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('owner a cannot record b->c', s <> 'ok', 'sqlstate='||s);

  -- outsider
  PERFORM pg_temp.as_user(d);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,d,a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('outsider d cannot record into h1', s <> 'ok', 'sqlstate='||s);

  -- cross-household party: caller is active in h1 but the other party is not a member of h1
  PERFORM pg_temp.as_user(a);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,a,d));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('party from another household is rejected', s <> 'ok', 'sqlstate='||s);
  PERFORM pg_temp.as_user(d);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h2,d,a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('caller cannot use own household with a foreign party', s <> 'ok', 'sqlstate='||s);

  -- c leaves; debts stay, and the active party can still record a real payment with c
  PERFORM pg_temp.as_user(c); PERFORM leave_household(h1);
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('active a records a payment from former member c',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,200,'EUR')$q$, h1,c,a)) = 'ok');
  PERFORM pg_temp.check('active a records a payment to former member c',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,a,c)) = 'ok');
  -- a former member cannot initiate
  PERFORM pg_temp.as_user(c);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,c,a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('former member c cannot record a new settlement', s <> 'ok', 'sqlstate='||s);
  -- an active member still cannot book between a former member and a third person
  PERFORM pg_temp.as_user(b);
  s := pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,c,a));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('unrelated b cannot record c->a even though c is a former member', s <> 'ok', 'sqlstate='||s);

  -- validation unchanged
  PERFORM pg_temp.as_user(a);
  PERFORM pg_temp.check('same sender and receiver still rejected',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'EUR')$q$, h1,a,a)) <> 'ok');
  PERFORM pg_temp.check('non-positive amount still rejected',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,0,'EUR')$q$, h1,a,b)) <> 'ok');
  PERFORM pg_temp.check('bad currency still rejected',
    pg_temp.outcome(format($q$select create_settlement(%L,%L,%L,100,'eur')$q$, h1,a,b)) <> 'ok');
  PERFORM pg_temp.as_admin();

  PERFORM pg_temp.check('the earlier third-party settlement record is unchanged',
    (SELECT row(es.*)::text FROM expense_settlements es WHERE id = legacy) = legacy_before);
  PERFORM pg_temp.check('recorded settlement keeps sender, receiver, snapshot names and creator',
    (SELECT count(*) = 1 FROM expense_settlements WHERE household_id = h1 AND from_user_id = b AND to_user_id = a
       AND amount_cents = 1000 AND from_name = 'St2' AND to_name = 'St1' AND created_by = b));
END $$;

ROLLBACK;
