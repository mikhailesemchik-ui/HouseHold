-- ============================================================
-- Task and occurrence completion attribution tests (migration 20261030000001)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/task_completion_integrity.sql
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

-- Runs a statement and returns the affected row count, or 'err:<SQLSTATE>'.
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
  o  uuid := 'f4000000-0000-0000-0000-00000000000a'; -- owner
  m1 uuid := 'f4000000-0000-0000-0000-00000000000b';
  m2 uuid := 'f4000000-0000-0000-0000-00000000000c';
  fm uuid := 'f4000000-0000-0000-0000-00000000000d'; -- leaves later
  x  uuid := 'f4000000-0000-0000-0000-00000000000e'; -- outsider
  h uuid; hx uuid; v_code text;
  t1 uuid; t2 uuid; t_legacy uuid; t_rec uuid; occ uuid; occ_legacy uuid;
  r text; legacy_task text; legacy_occ text; first_at timestamptz;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'tc'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (o,1),(m1,2),(m2,3),(fm,4),(x,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'TC-'||i,'Tc'||i FROM (VALUES (o,1),(m1,2),(m2,3),(fm,4),(x,5)) v(id,i);
  PERFORM pg_temp.as_user(o); SELECT id INTO h FROM create_household('TC H');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(m1); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(m2); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(fm); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_user(x);  SELECT id INTO hx FROM create_household('TC OTHER');
  PERFORM pg_temp.as_admin();

  -- existing completed history that must stay untouched
  INSERT INTO tasks (household_id,title,created_by,completed_at,completed_by)
  VALUES (h,'legacy done',o,now()-interval '5 days',o) RETURNING id INTO t_legacy;
  SELECT row(t.*)::text INTO legacy_task FROM tasks t WHERE id = t_legacy;

  PERFORM pg_temp.as_user(m1);
  INSERT INTO tasks (household_id,title,created_by) VALUES (h,'one-off A',m1) RETURNING id INTO t1;
  INSERT INTO tasks (household_id,title,created_by) VALUES (h,'one-off B',m1) RETURNING id INTO t2;

  -- ---------------- one-off tasks ----------------
  PERFORM pg_temp.check('1 member completes an eligible task',
    pg_temp.rows(format($q$update tasks set completed_at=now()-interval '1 hour', completed_by=%L where id=%L$q$, m1, t1)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('2 completed_by is the authenticated actor',
    (SELECT completed_by = m1 FROM tasks WHERE id = t1));
  SELECT completed_at INTO first_at FROM tasks WHERE id = t1;

  PERFORM pg_temp.as_user(m2);
  PERFORM pg_temp.check('3 claiming another member completed it is denied',
    pg_temp.rows(format($q$update tasks set completed_at=now(), completed_by=%L where id=%L$q$, m1, t2)) = 'err:TK001');
  r := pg_temp.rows(format($q$update tasks set completed_by=%L where id=%L$q$, m2, t1));
  PERFORM pg_temp.check('4 rewriting completed_by on a completed task is denied', r = 'err:TK002', 'result='||r);
  r := pg_temp.rows(format($q$update tasks set completed_at=now() where id=%L$q$, t1));
  PERFORM pg_temp.check('5 rewriting completed_at on a completed task is denied', r = 'err:TK002', 'result='||r);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('4b attribution unchanged after the attempts',
    (SELECT completed_by = m1 AND completed_at = first_at FROM tasks WHERE id = t1));

  PERFORM pg_temp.as_user(m2);
  PERFORM pg_temp.check('9 editing the title keeps completion history',
    pg_temp.rows(format($q$update tasks set title='renamed' where id=%L$q$, t1)) = '1');
  PERFORM pg_temp.check('10 assigning a completed task keeps completion history',
    pg_temp.rows(format($q$update tasks set assigned_to=%L where id=%L$q$, m2, t1)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('9b completion untouched by title and assignment edits',
    (SELECT completed_by = m1 AND completed_at = first_at AND title = 'renamed' AND assigned_to = m2 FROM tasks WHERE id = t1));

  PERFORM pg_temp.as_user(m2);
  PERFORM pg_temp.check('6 reopening works',
    pg_temp.rows(format($q$update tasks set completed_at=null, completed_by=null where id=%L$q$, t1)) = '1');
  PERFORM pg_temp.check('7/8 recompletion records the new actor and time',
    pg_temp.rows(format($q$update tasks set completed_at=now(), completed_by=%L where id=%L$q$, m2, t1)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('7b new actor and a later timestamp are stored',
    (SELECT completed_by = m2 AND completed_at > first_at FROM tasks WHERE id = t1));

  -- ---------------- recurring task occurrences ----------------
  PERFORM pg_temp.as_user(m1);
  INSERT INTO tasks (household_id,title,created_by,assigned_to,due_at,recurrence_type)
  VALUES (h,'daily',m1,m1,now()+interval '1 hour','daily') RETURNING id INTO t_rec;
  PERFORM pg_temp.as_admin();
  SELECT id INTO occ FROM task_occurrences WHERE task_id = t_rec ORDER BY scheduled_at LIMIT 1;
  SELECT id INTO occ_legacy FROM task_occurrences WHERE task_id = t_rec ORDER BY scheduled_at OFFSET 1 LIMIT 1;
  UPDATE task_occurrences SET completed_at = now()-interval '2 hours', completed_by = o WHERE id = occ_legacy;
  SELECT row(x.*)::text INTO legacy_occ FROM task_occurrences x WHERE id = occ_legacy;

  PERFORM pg_temp.as_user(m1);
  PERFORM pg_temp.check('15a member completes an occurrence through the RPC',
    pg_temp.rows(format($q$select complete_occurrence(%L)$q$, occ)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15b occurrence records the actor',
    (SELECT completed_by = m1 AND completed_at IS NOT NULL FROM task_occurrences WHERE id = occ));
  PERFORM pg_temp.as_user(m2);
  PERFORM pg_temp.rows(format($q$select complete_occurrence(%L)$q$, occ));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15c a second completion does not take over attribution',
    (SELECT completed_by = m1 FROM task_occurrences WHERE id = occ));

  r := pg_temp.rows(format($q$update task_occurrences set completed_by=%L where id=%L$q$, m2, occ));
  PERFORM pg_temp.check('15d rewriting completed_by on a completed occurrence is denied (trigger)', r = 'err:TK004', 'result='||r);
  r := pg_temp.rows(format($q$update task_occurrences set completed_at=now()+interval '1 day' where id=%L$q$, occ));
  PERFORM pg_temp.check('15e rewriting completed_at on a completed occurrence is denied (trigger)', r = 'err:TK004', 'result='||r);
  PERFORM pg_temp.as_user(m2);
  r := pg_temp.rows(format($q$update task_occurrences set completed_by=%L where id=%L$q$, m2, occ));
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15f clients have no direct write access to occurrences', r = 'err:42501', 'result='||r);

  -- refresh and reassignment preserve completed occurrences
  PERFORM pg_temp.as_user(m2); PERFORM refresh_my_recurring_occurrences();
  UPDATE tasks SET assigned_to = m2 WHERE id = t_rec;
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('11 refresh and reassignment preserve completed occurrences',
    (SELECT completed_by = m1 FROM task_occurrences WHERE id = occ)
    AND (SELECT completed_by = o AND completed_at IS NOT NULL FROM task_occurrences WHERE id = occ_legacy));

  -- reopen and recomplete
  PERFORM pg_temp.as_user(m2);
  PERFORM pg_temp.check('15g reopening through the RPC works', pg_temp.rows(format($q$select reopen_occurrence(%L)$q$, occ)) = '1');
  PERFORM pg_temp.check('15h recompletion by another member', pg_temp.rows(format($q$select complete_occurrence(%L)$q$, occ)) = '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15i recompletion records the new actor', (SELECT completed_by = m2 FROM task_occurrences WHERE id = occ));

  -- ---------------- outsider and former member ----------------
  PERFORM pg_temp.as_user(x);
  PERFORM pg_temp.check('13a outsider cannot complete an occurrence',
    pg_temp.rows(format($q$select complete_occurrence(%L)$q$, occ_legacy)) = 'err:TK011');
  PERFORM pg_temp.check('13b outsider cannot forge task completion',
    pg_temp.rows(format($q$update tasks set completed_at=now(), completed_by=%L where id=%L$q$, x, t2)) <> '1');
  PERFORM pg_temp.as_user(fm); PERFORM leave_household(h);
  PERFORM pg_temp.check('14a former member cannot complete an occurrence',
    pg_temp.rows(format($q$select complete_occurrence(%L)$q$, occ_legacy)) = 'err:TK011');
  PERFORM pg_temp.check('14b former member cannot complete a task',
    pg_temp.rows(format($q$update tasks set completed_at=now(), completed_by=%L where id=%L$q$, fm, t2)) <> '1');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('13/14c nothing was completed by the denied users',
    (SELECT completed_at IS NULL FROM tasks WHERE id = t2));

  -- ---------------- existing history ----------------
  PERFORM pg_temp.check('12 existing completed task row is unchanged',
    (SELECT row(t.*)::text FROM tasks t WHERE id = t_legacy) = legacy_task);
  PERFORM pg_temp.check('12b existing completed occurrence row is unchanged',
    (SELECT row(x.*)::text FROM task_occurrences x WHERE id = occ_legacy) = legacy_occ);
END $$;

ROLLBACK;
