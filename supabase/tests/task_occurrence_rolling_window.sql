-- ============================================================
-- Rolling recurrence window tests (migration 20261026000002)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/task_occurrence_rolling_window.sql
-- A failed check RAISEs an EXCEPTION; with ON_ERROR_STOP=1 psql exits nonzero.
-- "Time passing" is simulated by anchoring tasks in the past (now() is fixed
-- inside a transaction). Everything is rolled back.
-- Time zone: slots are timestamptz + interval in the SESSION time zone (UTC on
-- Supabase). Since 20261027000001 the recurrence functions pin timezone to UTC, so the
-- session zone no longer matters; the DST scenarios assert exactly that.
-- ============================================================

BEGIN;

CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN RAISE NOTICE '% PASS', p_name;
  ELSE RAISE EXCEPTION '% FAIL: %', p_name, p_detail; END IF;
END $$;

-- upcoming = rows at or after now(); off_lattice = rows not a whole step from the anchor;
-- pred_ok = the slot just before the earliest upcoming one is already past.
CREATE FUNCTION pg_temp.stats(p_task uuid, p_anchor timestamptz, p_step interval)
RETURNS TABLE (upcoming int, total int, off_lattice int, pred_ok boolean) LANGUAGE sql AS $$
  SELECT count(*) FILTER (WHERE scheduled_at >= now())::int,
         count(*)::int,
         count(*) FILTER (WHERE mod(extract(epoch FROM scheduled_at - p_anchor)::bigint,
                                    extract(epoch FROM p_step)::bigint) <> 0)::int,
         coalesce(min(scheduled_at) FILTER (WHERE scheduled_at >= now()) - p_step < now(), false)
  FROM task_occurrences WHERE task_id = p_task;
$$;

-- Models a recurring task that has been active since p_due (rows already exist): triggers
-- are bypassed so the activation boundary is the task's own start, then the generator
-- runs. Used to simulate "time has passed" since now() is fixed inside a transaction.
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

DO $$
DECLARE
  v_user uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  v_hh   uuid := 'eeeeeeee-bbbb-cccc-dddd-000000000001';
  v_task uuid; v_old uuid;
  v_anchor timestamptz;
  s record;
  v_ids_before uuid[]; v_ids_after uuid[];
  v_done_id uuid; v_done_at timestamptz;
  v_a int; v_b int; v_first int;
BEGIN
  INSERT INTO auth.users (id, email, role, aud, created_at, updated_at, is_anonymous)
  VALUES (v_user, 'rolling@test.local', 'authenticated', 'authenticated', now(), now(), true);
  INSERT INTO profiles (user_id, public_id, display_name) VALUES (v_user, 'rolling', 'Rolling');
  INSERT INTO households (id, name, created_by) VALUES (v_hh, 'Rolling HH', v_user);
  INSERT INTO household_members (household_id, user_id, role, status, joined_at)
  VALUES (v_hh, v_user, 'owner', 'active', now());
  INSERT INTO household_membership_periods (household_id, user_id, joined_at)
  VALUES (v_hh, v_user, now());
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- Q: daily, 35 days after start (past day 30). 09:00 UTC phase, gap not backfilled.
  v_anchor := date_trunc('day', now()) - interval '35 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'Q', v_user, v_anchor, 'daily');
  PERFORM refresh_my_recurring_occurrences();
  SELECT * INTO s FROM pg_temp.stats(v_task, v_anchor, interval '1 day');
  SELECT count(*) INTO v_a FROM task_occurrences WHERE task_id = v_task
    AND scheduled_at > v_anchor + interval '29 days' AND scheduled_at < now();
  PERFORM pg_temp.check('Q daily beyond day 30 keeps 30 upcoming on lattice',
    s.upcoming = 30 AND s.total = 60 AND s.off_lattice = 0 AND s.pred_ok AND v_a = 0,
    format('%s gap=%s', s, v_a));
  PERFORM pg_temp.check('Q daily keeps 09:00 phase',
    (SELECT count(*) FROM task_occurrences WHERE task_id = v_task
       AND extract(hour FROM scheduled_at) = 9 AND extract(minute FROM scheduled_at) = 0) = 60);

  -- R: daily, 65 days after start (past day 60).
  v_anchor := date_trunc('day', now()) - interval '65 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'R', v_user, v_anchor, 'daily');
  SELECT * INTO s FROM pg_temp.stats(v_task, v_anchor, interval '1 day');
  SELECT count(*) INTO v_a FROM task_occurrences WHERE task_id = v_task
    AND scheduled_at > v_anchor + interval '29 days' AND scheduled_at < now();
  PERFORM pg_temp.check('R daily beyond day 60: 30 upcoming, no gap backfill',
    s.upcoming = 30 AND s.total = 60 AND s.off_lattice = 0 AND s.pred_ok AND v_a = 0,
    format('%s gap=%s', s, v_a));

  -- S: weekly Monday 10:30 UTC, 14 weeks after start (past week 12).
  v_anchor := date_trunc('week', now()) - interval '14 weeks' + interval '10 hours 30 minutes';
  v_task := pg_temp.legacy_recurring(v_hh, 'S', v_user, v_anchor, 'weekly');
  SELECT * INTO s FROM pg_temp.stats(v_task, v_anchor, interval '1 week');
  PERFORM pg_temp.check('S weekly beyond week 12: 12 upcoming on lattice',
    s.upcoming = 12 AND s.total = 24 AND s.off_lattice = 0 AND s.pred_ok, format('%s', s));
  PERFORM pg_temp.check('S weekly keeps Monday 10:30',
    (SELECT count(*) FROM task_occurrences WHERE task_id = v_task
       AND extract(isodow FROM scheduled_at) = 1
       AND scheduled_at::time = time '10:30') = 24);

  -- T: weekly, 22 weeks after start (past week 20).
  v_anchor := date_trunc('week', now()) - interval '22 weeks' + interval '10 hours 30 minutes';
  v_task := pg_temp.legacy_recurring(v_hh, 'T', v_user, v_anchor, 'weekly');
  SELECT * INTO s FROM pg_temp.stats(v_task, v_anchor, interval '1 week');
  PERFORM pg_temp.check('T weekly beyond week 20: 12 upcoming on Mondays',
    s.upcoming = 12 AND s.total = 24 AND s.off_lattice = 0 AND s.pred_ok
    AND (SELECT count(*) FROM task_occurrences WHERE task_id = v_task
         AND extract(isodow FROM scheduled_at) = 1) = 24, format('%s', s));

  -- U: refresh extends the window, is idempotent, keeps ids, completed and overdue rows.
  v_anchor := date_trunc('day', now()) - interval '10 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'U', v_user, v_anchor, 'daily');
  UPDATE task_occurrences SET completed_at = now() - interval '1 day', completed_by = v_user
   WHERE task_id = v_task AND scheduled_at = v_anchor + interval '2 days'
   RETURNING id, completed_at INTO v_done_id, v_done_at;
  -- Simulate the pre-fix state: the window ends at original day 29.
  DELETE FROM task_occurrences
   WHERE task_id = v_task AND scheduled_at > v_anchor + interval '29 days';
  SELECT array_agg(id ORDER BY scheduled_at) INTO v_ids_before
    FROM task_occurrences WHERE task_id = v_task;
  SELECT count(*) INTO v_a FROM task_occurrences
    WHERE task_id = v_task AND completed_at IS NULL AND scheduled_at < now();
  v_first := ceil(extract(epoch FROM now() - v_anchor) / 86400)::int;
  PERFORM refresh_my_recurring_occurrences();
  PERFORM refresh_my_recurring_occurrences();
  SELECT array_agg(id ORDER BY scheduled_at) INTO v_ids_after
    FROM task_occurrences WHERE task_id = v_task;
  PERFORM pg_temp.check('U refresh extends window to 30 upcoming, no duplicates',
    -- slots 0..29 plus the rolling window 30 slots from index v_a_first
    (SELECT count(*) FROM task_occurrences WHERE task_id = v_task) = 30 + v_first
    AND (SELECT count(*) FROM task_occurrences
         WHERE task_id = v_task AND scheduled_at >= now()) = 30,
    format('first=%s', v_first));
  PERFORM pg_temp.check('U existing ids are stable', v_ids_before <@ v_ids_after);
  PERFORM pg_temp.check('U completed row unchanged',
    (SELECT id = v_done_id AND completed_at = v_done_at AND completed_by = v_user
       FROM task_occurrences WHERE task_id = v_task AND scheduled_at = v_anchor + interval '2 days'));
  PERFORM pg_temp.check('U overdue incomplete rows survive refresh',
    (SELECT count(*) FROM task_occurrences
       WHERE task_id = v_task AND completed_at IS NULL AND scheduled_at < now()) = v_a
    AND v_a >= 8, format('before=%s', v_a));
  SELECT array_agg(id ORDER BY scheduled_at) INTO v_ids_before
    FROM task_occurrences WHERE task_id = v_task;
  PERFORM refresh_my_recurring_occurrences();
  SELECT array_agg(id ORDER BY scheduled_at) INTO v_ids_after
    FROM task_occurrences WHERE task_id = v_task;
  PERFORM pg_temp.check('U further refresh is a no-op', v_ids_before = v_ids_after);

  -- V: future start. Only the 30 forward slots, none before the start.
  v_anchor := now() + interval '5 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'V', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  PERFORM refresh_my_recurring_occurrences();
  PERFORM pg_temp.check('V future start: 30 slots from start, none earlier',
    (SELECT count(*) = 30 AND min(scheduled_at) = v_anchor
       FROM task_occurrences WHERE task_id = v_task));

  -- W: schedule edit after recurrence has run for 35 days.
  v_anchor := date_trunc('day', now()) - interval '35 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'W', v_user, v_anchor, 'daily');
  SELECT count(*) INTO v_a FROM task_occurrences WHERE task_id = v_task AND scheduled_at < now();
  UPDATE tasks SET due_at = date_trunc('day', now()) + interval '1 day 7 hours' WHERE id = v_task;
  SELECT count(*) INTO v_b FROM task_occurrences WHERE task_id = v_task AND scheduled_at < now();
  PERFORM pg_temp.check('W schedule edit: old overdue kept, future replaced by new lattice',
    v_a = v_b
    AND (SELECT count(*) FROM task_occurrences
         WHERE task_id = v_task AND scheduled_at >= now()) = 30
    AND (SELECT count(*) FROM task_occurrences
         WHERE task_id = v_task AND scheduled_at >= now()
           AND extract(hour FROM scheduled_at) = 7) = 30,
    format('before=%s after=%s', v_a, v_b));

  -- X: one-off -> recurring; old date is a rolling-window slot of the earlier start: kept.
  v_anchor := date_trunc('day', now()) - interval '40 days' + interval '9 hours';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'X', v_user, v_user, v_anchor + interval '45 days') RETURNING id INTO v_task;
  SELECT id INTO v_old FROM task_occurrences WHERE task_id = v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_anchor WHERE id = v_task;
  PERFORM pg_temp.check('X conversion: old one-off on a window slot keeps its row',
    (SELECT id = v_old FROM task_occurrences
       WHERE task_id = v_task AND scheduled_at = v_anchor + interval '45 days'));

  -- Y: reassignment keeps completed history unchanged.
  v_anchor := date_trunc('day', now()) - interval '10 days' + interval '9 hours';
  v_task := pg_temp.legacy_recurring(v_hh, 'Y', v_user, v_anchor, 'daily');
  UPDATE task_occurrences SET completed_at = now() - interval '1 day', completed_by = v_user
   WHERE task_id = v_task AND scheduled_at = v_anchor + interval '2 days'
   RETURNING id, completed_at INTO v_done_id, v_done_at;
  SELECT count(*) INTO v_a FROM task_occurrences WHERE task_id = v_task;
  UPDATE tasks SET assigned_to = NULL WHERE id = v_task;
  PERFORM pg_temp.check('Y reassignment: no rows lost, completed row untouched',
    (SELECT count(*) FROM task_occurrences WHERE task_id = v_task) = v_a
    AND (SELECT assigned_to = v_user AND completed_at = v_done_at
         FROM task_occurrences WHERE id = v_done_id)
    AND (SELECT count(*) FROM task_occurrences WHERE task_id = v_task
         AND scheduled_at >= now() AND assigned_to IS NULL) = 30);
END $$;

-- DST. Fixed 2027 anchors make the original window (slots 0..29) independent of today.
DO $$
DECLARE
  v_user uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  v_hh   uuid := 'eeeeeeee-bbbb-cccc-dddd-000000000002';
  v_task uuid; v_anchor timestamptz;
BEGIN
  INSERT INTO households (id, name, created_by) VALUES (v_hh, 'Dst HH', v_user);

  -- Session zone America/New_York is ignored: slots stay a constant UTC time of day
  -- (2027-03-01 09:00 EST = 14:00 UTC) across the 2027-03-14 spring-forward.
  SET LOCAL TIME ZONE 'America/New_York';
  v_anchor := timestamptz '2027-03-01 09:00';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'DST-NY', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  PERFORM pg_temp.check('DST1 NY session ignored: constant 14:00 UTC over spring-forward',
    (SELECT count(*) = 30 AND count(*) FILTER (
              WHERE (scheduled_at AT TIME ZONE 'UTC')::time = time '14:00') = 30
       FROM task_occurrences WHERE task_id = v_task));

  -- Session zone UTC (Supabase): slots are exactly 24h apart, so the UTC time is constant
  -- and New York wall-clock shifts by an hour at the transition. Pre-existing behavior.
  SET LOCAL TIME ZONE 'UTC';
  v_anchor := timestamptz '2027-03-01 14:00+00';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'DST-UTC', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  PERFORM pg_temp.check('DST2 UTC session: constant 14:00 UTC (local hour shifts, unchanged)',
    (SELECT count(*) FROM task_occurrences WHERE task_id = v_task
       AND scheduled_at <= v_anchor + interval '29 days'
       AND scheduled_at::time = time '14:00') = 30);

  -- Rolling window under a DST session zone: first upcoming slot is exact, one UTC time of day.
  SET LOCAL TIME ZONE 'America/New_York';
  v_anchor := date_trunc('day', now()) - interval '40 days' + interval '9 hours';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at, recurrence_type)
  VALUES (v_hh, 'DST-ROLL', v_user, v_user, v_anchor, 'daily') RETURNING id INTO v_task;
  PERFORM pg_temp.check('DST3 NY session rolling window: 30 upcoming, one UTC time of day, exact start',
    (SELECT count(*) FILTER (WHERE scheduled_at >= now()) = 30
        AND min(scheduled_at) FILTER (WHERE scheduled_at >= now()) - interval '1 day' < now()
        AND count(DISTINCT (scheduled_at AT TIME ZONE 'UTC')::time) = 1
       FROM task_occurrences WHERE task_id = v_task));
END $$;

ROLLBACK;
