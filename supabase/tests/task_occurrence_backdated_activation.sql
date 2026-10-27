-- ============================================================
-- Activation boundary tests (migration 20261026000003)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/task_occurrence_backdated_activation.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- Policy: a recurring schedule never gets occurrences for slots earlier than its
-- activation instant (tasks.recurrence_started_at), at creation or on any refresh.
-- Existing occurrences (completed or overdue) are never deleted by refresh.
-- Slot arithmetic is in the session time zone (UTC on Supabase). Everything is rolled back.
-- ============================================================

BEGIN;

CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN RAISE NOTICE '% PASS', p_name;
  ELSE RAISE EXCEPTION '% FAIL: %', p_name, p_detail; END IF;
END $$;

-- A recurring task that has been active since p_due (rows already exist): triggers are
-- bypassed so the boundary is the task's own start, then the generator runs. Simulates
-- "time has passed" because now() is fixed inside a transaction.
CREATE FUNCTION pg_temp.legacy_recurring(
  p_hh uuid, p_title text, p_user uuid, p_due timestamptz, p_type text
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE t tasks;
BEGIN
  SET LOCAL session_replication_role = replica;
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type,
                     recurrence_started_at)
  VALUES (p_hh, p_title, p_user, p_user, p_due, p_type, p_due) RETURNING * INTO t;
  SET LOCAL session_replication_role = origin;
  PERFORM _generate_occurrences_for_task(t);
  RETURN t.id;
END $$;

CREATE FUNCTION pg_temp.rows(p_task uuid) RETURNS TABLE (
  total int, past int, upcoming int, first_at timestamptz, ids uuid[]
) LANGUAGE sql AS $$
  SELECT count(*)::int,
         count(*) FILTER (WHERE scheduled_at < now())::int,
         count(*) FILTER (WHERE scheduled_at >= now())::int,
         min(scheduled_at),
         array_agg(id ORDER BY scheduled_at)
  FROM task_occurrences WHERE task_id = p_task;
$$;

DO $$
DECLARE
  v_user uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  v_hh   uuid := 'ffffffff-bbbb-cccc-dddd-000000000001';
  v_task uuid; v_other uuid;
  v_anchor timestamptz;
  s record; s2 record;
  v_done_id uuid; v_done_at timestamptz;
  v_n int;
BEGIN
  INSERT INTO auth.users (id, email, role, aud, created_at, updated_at, is_anonymous)
  VALUES (v_user, 'backdated@test.local', 'authenticated', 'authenticated', now(), now(), true);
  INSERT INTO profiles (user_id, public_id, display_name) VALUES (v_user, 'backdated', 'Backdated');
  INSERT INTO households (id, name, created_by) VALUES (v_hh, 'Backdated HH', v_user);
  INSERT INTO household_members (household_id, user_id, role, status, joined_at)
  VALUES (v_hh, v_user, 'owner', 'active', now());
  INSERT INTO household_membership_periods (household_id, user_id, joined_at)
  VALUES (v_hh, v_user, now());
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1/2/6: daily, start 40 days ago, today's slot already passed (1 hour ago).
  v_anchor := now() - interval '40 days' - interval '1 hour';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'B1', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('1 daily backdated 40d: no overdue rows, first slot tomorrow',
    s.total = 30 AND s.past = 0 AND s.first_at = v_anchor + interval '41 days',
    format('%s', s));
  PERFORM pg_temp.check('6 daily hour and interval kept',
    (SELECT count(*) = 30 AND bool_and(mod(extract(epoch FROM scheduled_at - v_anchor)::bigint, 86400) = 0)
       FROM task_occurrences WHERE task_id = v_task));

  -- 10/11: refresh does not resurrect skipped slots and is idempotent.
  PERFORM refresh_my_recurring_occurrences();
  PERFORM refresh_my_recurring_occurrences();
  SELECT * INTO s2 FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('10 refresh does not resurrect skipped past slots', s2.past = 0, format('%s', s2));
  PERFORM pg_temp.check('11 repeated refresh idempotent, ids stable', s2.ids = s.ids AND s2.total = 30);

  -- 12: reassignment creates no past rows and loses none.
  UPDATE tasks SET assigned_to = NULL WHERE id = v_task;
  SELECT * INTO s2 FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('12 reassignment adds no past rows', s2.past = 0 AND s2.ids = s.ids);

  -- 15: horizon keeps extending for an activated schedule without backfilling.
  DELETE FROM task_occurrences WHERE task_id = v_task AND scheduled_at > now() + interval '10 days';
  PERFORM refresh_my_recurring_occurrences();
  SELECT * INTO s2 FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('15 refresh restores 30 upcoming, still no past rows',
    s2.upcoming = 30 AND s2.past = 0 AND s2.total = 30, format('%s', s2));

  -- 3: today's slot still ahead (1 hour from now) is the first occurrence.
  v_anchor := now() - interval '40 days' + interval '1 hour';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'B3', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('3 daily: slot later today is the first occurrence',
    s.total = 30 AND s.past = 0 AND s.first_at = now() + interval '1 hour', format('%s', s));

  -- 4/5: weekly Monday 10:30, started 20 weeks ago.
  v_anchor := date_trunc('week', now()) - interval '20 weeks' + interval '10 hours 30 minutes';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'B4', v_user, v_user, v_anchor, 'weekly') RETURNING id INTO v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('4 weekly backdated: 12 upcoming, no overdue, first slot is next Monday slot',
    s.total = 12 AND s.past = 0 AND s.first_at >= now() AND s.first_at - interval '1 week' < now(),
    format('%s', s));
  PERFORM pg_temp.check('5 weekly keeps Monday 10:30',
    (SELECT count(*) = 12 FROM task_occurrences WHERE task_id = v_task
       AND extract(isodow FROM scheduled_at) = 1 AND scheduled_at::time = time '10:30'));

  -- 16: future start: all 30 slots from the start, boundary not after the start.
  v_anchor := now() + interval '5 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'B16', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('16 future start keeps all 30 slots from the start',
    s.total = 30 AND s.first_at = v_anchor
    AND (SELECT recurrence_started_at <= due_at FROM tasks WHERE id = v_task));

  -- 7: one-off (overdue) -> daily with a past start: stale one-off row removed, no backfill.
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'B7', v_user, v_user, now() - interval '2 days') RETURNING id INTO v_task;
  v_anchor := now() - interval '40 days' - interval '1 hour';
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_anchor WHERE id = v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('7 one-off to daily, past start: stale row gone, no past rows',
    s.total = 30 AND s.past = 0, format('%s', s));

  -- 8: one-off -> weekly with a past start.
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'B8', v_user, v_user, now() - interval '2 days') RETURNING id INTO v_task;
  UPDATE tasks SET recurrence_type = 'weekly',
    due_at = date_trunc('week', now()) - interval '30 weeks' + interval '8 hours' WHERE id = v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('8 one-off to weekly, past start: stale row gone, 12 upcoming',
    s.total = 12 AND s.past = 0 AND s.upcoming = 12, format('%s', s));

  -- 9: completed one-off history survives conversion unchanged.
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'B9', v_user, v_user, now() - interval '3 days') RETURNING id INTO v_task;
  UPDATE task_occurrences SET completed_at = now() - interval '2 days', completed_by = v_user
   WHERE task_id = v_task RETURNING id, completed_at INTO v_done_id, v_done_at;
  UPDATE tasks SET recurrence_type = 'daily', due_at = now() - interval '40 days' WHERE id = v_task;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('9 completed one-off survives conversion; only it is in the past',
    s.past = 1 AND s.upcoming = 30
    AND (SELECT id = v_done_id AND completed_at = v_done_at AND completed_by = v_user
           FROM task_occurrences WHERE id = v_done_id));

  -- 13/14: existing recurring task: genuine overdue rows and completed rows kept by refresh
  -- and reassignment, with ids and completion values intact.
  v_anchor := date_trunc('day', now()) - interval '10 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'B13', v_user, v_anchor, 'daily');
  UPDATE task_occurrences SET completed_at = now() - interval '1 day', completed_by = v_user
   WHERE task_id = v_task AND scheduled_at = v_anchor + interval '2 days'
   RETURNING id, completed_at INTO v_done_id, v_done_at;
  SELECT * INTO s FROM pg_temp.rows(v_task);
  PERFORM refresh_my_recurring_occurrences();
  UPDATE tasks SET assigned_to = NULL WHERE id = v_task;
  SELECT * INTO s2 FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('13 existing recurring task keeps its genuine overdue rows',
    s.past >= 9 AND s2.past = s.past AND s.ids <@ s2.ids, format('%s / %s', s, s2));
  PERFORM pg_temp.check('14 completed occurrence keeps id and completion values',
    (SELECT completed_at = v_done_at AND completed_by = v_user
       FROM task_occurrences WHERE id = v_done_id));

  -- 17: editing an existing recurring schedule keeps all history and creates no past rows;
  -- the edited schedule starts a new activation boundary.
  SELECT * INTO s FROM pg_temp.rows(v_task);
  UPDATE tasks SET due_at = now() - interval '5 days' - interval '1 hour' WHERE id = v_task;
  SELECT * INTO s2 FROM pg_temp.rows(v_task);
  PERFORM pg_temp.check('17 schedule edit keeps past history, adds no past rows, 30 upcoming',
    s2.past = s.past AND s2.upcoming = 30 AND s.ids[1:s.past] <@ s2.ids
    AND (SELECT recurrence_started_at = now() FROM tasks WHERE id = v_task),
    format('%s / %s', s, s2));

  -- boundary integrity: clients cannot set or move it; one-off tasks have none.
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type,
                     recurrence_started_at)
  VALUES (v_hh, 'B-guard', v_user, v_user, now() + interval '1 day', 'daily', timestamptz '2000-01-01')
  RETURNING id INTO v_other;
  PERFORM pg_temp.check('boundary: client value on insert is ignored',
    (SELECT recurrence_started_at = now() FROM tasks WHERE id = v_other));
  UPDATE tasks SET recurrence_started_at = timestamptz '2000-01-01', title = 'B-guard2'
   WHERE id = v_other;
  PERFORM pg_temp.check('boundary: client value on update is ignored',
    (SELECT recurrence_started_at = now() FROM tasks WHERE id = v_other));
  UPDATE tasks SET recurrence_type = 'none' WHERE id = v_other;
  PERFORM pg_temp.check('boundary: cleared for one-off tasks',
    (SELECT recurrence_started_at IS NULL FROM tasks WHERE id = v_other));

  -- 18: no duplicate occurrences anywhere in the fixture household.
  SELECT count(*) - count(DISTINCT (task_id, scheduled_at)) INTO v_n
    FROM task_occurrences WHERE household_id = v_hh;
  PERFORM pg_temp.check('18 no duplicate occurrences', v_n = 0, format('dups=%s', v_n));
END $$;

ROLLBACK;
