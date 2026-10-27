-- ============================================================
-- Audit remediation tests F2, F5, F6 (migration 20261027000001)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/task_occurrence_audit_fixes.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Everything runs inside one transaction and is rolled back.
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

-- Task that has been active since p_due, with its rows already generated (triggers bypassed).
CREATE FUNCTION pg_temp.legacy_recurring(
  p_hh uuid, p_title text, p_user uuid, p_assignee uuid, p_due timestamptz, p_type text
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE t tasks;
BEGIN
  SET LOCAL session_replication_role = replica;
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type,
                     recurrence_started_at)
  VALUES (p_hh, p_title, p_user, p_assignee, p_due, p_type, p_due) RETURNING * INTO t;
  SET LOCAL session_replication_role = origin;
  PERFORM _generate_occurrences_for_task(t);
  RETURN t.id;
END $$;

-- Logs every UPDATE of task_occurrences so no-op refreshes can be counted.
CREATE TEMP TABLE upd_log (id uuid);
CREATE FUNCTION public.audit_log_occurrence_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pg_temp.upd_log VALUES (new.id); RETURN NULL; END $$;
CREATE TRIGGER audit_log_occurrence_update AFTER UPDATE ON task_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_occurrence_update();
GRANT ALL ON upd_log TO PUBLIC;

DO $$
DECLARE
  u1 uuid := 'f1000000-0000-0000-0000-000000000001'; -- owner
  u2 uuid := 'f1000000-0000-0000-0000-000000000002'; -- member who leaves
  h  uuid; v_code text;
  t_one uuid; t_rec uuid; t_done uuid; t_legacy uuid; t_f5 uuid; t_tz uuid; t_tz2 uuid;
  v_anchor timestamptz; v_slot timestamptz; v_done_id uuid; v_done_at timestamptz;
  s_past_before int; ids_before uuid[]; v_n int; v_hash1 text; v_hash2 text; v_hash3 text;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'fix'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (u1,1),(u2,2)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'FIX-'||i,'Fix'||i FROM (VALUES (u1,1),(u2,2)) v(id,i);
  PERFORM pg_temp.as_user(u1); SELECT id INTO h FROM create_household('Fix HH');
  SELECT hi.code INTO v_code FROM create_household_invite(h) hi;
  PERFORM pg_temp.as_user(u2); PERFORM join_household_by_invite(v_code);
  PERFORM pg_temp.as_admin();

  -- ---------------- F2: voluntary leave ----------------
  PERFORM pg_temp.as_user(u1);
  INSERT INTO tasks (household_id,title,created_by,assigned_to,due_at)
  VALUES (h,'F2 one-off',u1,u2,now()+interval '2 days') RETURNING id INTO t_one;
  PERFORM pg_temp.as_admin();
  t_rec := pg_temp.legacy_recurring(h,'F2 daily',u1,u2,
    date_trunc('day',now()) - interval '10 days' + interval '9 hours','daily');
  UPDATE task_occurrences SET completed_at = now() - interval '1 day', completed_by = u2
   WHERE task_id = t_rec AND scheduled_at = date_trunc('day',now()) - interval '8 days' + interval '9 hours'
   RETURNING id, completed_at INTO v_done_id, v_done_at;
  SET LOCAL session_replication_role = replica;
  INSERT INTO tasks (household_id,title,created_by,assigned_to,completed_at,completed_by)
  VALUES (h,'F2 done',u1,u2,now(),u2) RETURNING id INTO t_done;
  SET LOCAL session_replication_role = origin;
  SELECT count(*), array_agg(id ORDER BY scheduled_at)
    INTO s_past_before, ids_before
    FROM task_occurrences WHERE task_id = t_rec AND scheduled_at < now();

  PERFORM pg_temp.as_user(u2); PERFORM leave_household(h); PERFORM pg_temp.as_admin();

  PERFORM pg_temp.check('F2 incomplete tasks of the leaver are unassigned',
    (SELECT count(*) FROM tasks WHERE id IN (t_one,t_rec) AND assigned_to IS NULL) = 2);
  PERFORM pg_temp.check('F2 completed task history keeps its assignee',
    (SELECT assigned_to = u2 FROM tasks WHERE id = t_done));
  PERFORM pg_temp.check('F2 future incomplete occurrences are unassigned',
    (SELECT count(*) FROM task_occurrences WHERE household_id = h AND assigned_to = u2
        AND completed_at IS NULL AND scheduled_at > now()) = 0);
  PERFORM pg_temp.check('F2 overdue rows keep ids and count; completed row untouched',
    (SELECT count(*) = s_past_before AND array_agg(id ORDER BY scheduled_at) = ids_before
       FROM task_occurrences WHERE task_id = t_rec AND scheduled_at < now())
    AND (SELECT completed_at = v_done_at AND completed_by = u2
           FROM task_occurrences WHERE id = v_done_id));

  PERFORM pg_temp.as_user(u1);
  UPDATE tasks SET title = 'F2 renamed' WHERE id = t_one;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM pg_temp.check('F2 other member can rename the task', v_n = 1);
  PERFORM refresh_my_recurring_occurrences();
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('F2 refresh creates nothing assigned to the leaver',
    (SELECT count(*) FROM task_occurrences WHERE household_id = h AND assigned_to = u2
        AND completed_at IS NULL AND scheduled_at > now()) = 0);

  -- a task stranded before the fix (assigned to a departed member) heals on regeneration
  SET LOCAL session_replication_role = replica;
  INSERT INTO tasks (household_id,title,created_by,assigned_to,due_at,recurrence_type,recurrence_started_at)
  VALUES (h,'F2 stranded',u1,u2,now()+interval '1 day','daily',now()) RETURNING id INTO t_legacy;
  SET LOCAL session_replication_role = origin;
  PERFORM _generate_occurrences_for_task(t) FROM tasks t WHERE t.id = t_legacy;
  PERFORM pg_temp.check('F2 generator never assigns to a non-member',
    (SELECT count(*) = 30 AND count(*) FILTER (WHERE assigned_to IS NULL) = 30
       FROM task_occurrences WHERE task_id = t_legacy));

  -- ---------------- F5: no-op refresh ----------------
  PERFORM pg_temp.as_user(u1);
  INSERT INTO tasks (household_id,title,created_by,assigned_to,due_at,recurrence_type)
  VALUES (h,'F5 daily',u1,u1,now()+interval '1 day','daily') RETURNING id INTO t_f5;
  PERFORM pg_temp.as_admin();
  TRUNCATE upd_log;
  PERFORM pg_temp.as_user(u1);
  PERFORM refresh_my_recurring_occurrences();
  PERFORM refresh_my_recurring_occurrences();
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('F5 no-op refresh issues no occurrence UPDATEs',
    (SELECT count(*) FROM upd_log) = 0, format('updates=%s', (SELECT count(*) FROM upd_log)));

  UPDATE task_occurrences SET completed_at = now(), completed_by = u1
   WHERE id = (SELECT id FROM task_occurrences WHERE task_id = t_f5 ORDER BY scheduled_at LIMIT 1)
   RETURNING id, completed_at INTO v_done_id, v_done_at;
  SELECT array_agg(id ORDER BY scheduled_at) INTO ids_before FROM task_occurrences WHERE task_id = t_f5;
  TRUNCATE upd_log;
  UPDATE tasks SET assigned_to = NULL WHERE id = t_f5;
  PERFORM pg_temp.check('F5 a real assignee change still updates only incomplete rows',
    (SELECT count(*) FROM upd_log) = 29
    AND (SELECT count(*) = 29 FROM task_occurrences WHERE task_id = t_f5 AND assigned_to IS NULL AND completed_at IS NULL)
    AND (SELECT assigned_to = u1 AND completed_at = v_done_at FROM task_occurrences WHERE id = v_done_id),
    format('updates=%s', (SELECT count(*) FROM upd_log)));
  PERFORM pg_temp.check('F5 ids stable after assignee change',
    (SELECT array_agg(id ORDER BY scheduled_at) = ids_before FROM task_occurrences WHERE task_id = t_f5));

  DELETE FROM task_occurrences WHERE task_id = t_f5 AND scheduled_at > now() + interval '10 days';
  TRUNCATE upd_log;
  PERFORM pg_temp.as_user(u1); PERFORM refresh_my_recurring_occurrences(); PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('F5 missing window rows are still regenerated, without touching others',
    (SELECT count(*) FROM task_occurrences WHERE task_id = t_f5) = 30
    AND (SELECT count(*) FROM upd_log) = 0);

  -- ---------------- F6: session time zone ----------------
  PERFORM pg_temp.check('F6 recurrence functions pin timezone to UTC',
    (SELECT count(*) FROM pg_proc WHERE proname IN
       ('_recurring_slots','_generate_occurrences_for_task','generate_task_occurrences',
        'refresh_my_recurring_occurrences')
       AND proconfig::text ILIKE '%timezone=utc%') = 4);

  v_anchor := timestamptz '2027-03-01 12:00+00';   -- window crosses the US spring-forward
  PERFORM pg_temp.as_admin();
  SET LOCAL TIME ZONE 'UTC';
  t_tz := pg_temp.legacy_recurring(h,'F6 utc',u1,u1,v_anchor,'daily');
  SELECT md5(string_agg((scheduled_at AT TIME ZONE 'UTC')::text, ',' ORDER BY scheduled_at)) INTO v_hash1
    FROM task_occurrences WHERE task_id = t_tz;

  SET LOCAL TIME ZONE 'America/New_York';
  t_tz2 := pg_temp.legacy_recurring(h,'F6 ny',u1,u1,v_anchor,'daily');
  SELECT md5(string_agg((scheduled_at AT TIME ZONE 'UTC')::text, ',' ORDER BY scheduled_at)) INTO v_hash2
    FROM task_occurrences WHERE task_id = t_tz2;
  PERFORM pg_temp.check('F6 same slots whether created under UTC or America/New_York',
    v_hash1 = v_hash2 AND (SELECT count(*) = 30 FROM task_occurrences WHERE task_id = t_tz2));

  -- a refresh under other session zones neither moves nor duplicates slots, even after a
  -- completion on a slot past the 2027-03-14 spring-forward
  SET LOCAL TIME ZONE 'UTC';
  v_slot := v_anchor + interval '20 days';
  UPDATE task_occurrences SET completed_at = now(), completed_by = u1
   WHERE task_id = t_tz AND scheduled_at = v_slot;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM pg_temp.check('F6 fixture completed exactly one slot', v_n = 1);
  FOREACH v_code IN ARRAY ARRAY['America/New_York','Pacific/Auckland','Asia/Kolkata'] LOOP
    PERFORM set_config('TimeZone', v_code, true);
    PERFORM pg_temp.as_user(u1);
    PERFORM refresh_my_recurring_occurrences();
    PERFORM pg_temp.as_admin();
    SELECT md5(string_agg((scheduled_at AT TIME ZONE 'UTC')::text, ',' ORDER BY scheduled_at)) INTO v_hash3
      FROM task_occurrences WHERE task_id = t_tz;
    PERFORM pg_temp.check('F6 refresh under ' || v_code || ' keeps the UTC slots', v_hash3 = v_hash1);
    PERFORM pg_temp.check('F6 no same-day duplicate beside the completed slot under ' || v_code,
      (SELECT count(*) FROM task_occurrences WHERE task_id = t_tz
         AND (scheduled_at AT TIME ZONE 'UTC')::date = (v_slot AT TIME ZONE 'UTC')::date) = 1);
  END LOOP;
END $$;

ROLLBACK;
