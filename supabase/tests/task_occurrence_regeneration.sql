-- ============================================================
-- Task occurrence regeneration tests (TE-001, TE-002)
-- Usage: docker exec -i supabase_db_HouseHold psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/task_occurrence_regeneration.sql
-- A failed check RAISEs an EXCEPTION. Run with -v ON_ERROR_STOP=1 so psql exits
-- nonzero on failure; the BEGIN is then rolled back when the session ends.
-- ============================================================

BEGIN;

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
  v_user  uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  v_hh    uuid := 'cccccccc-bbbb-cccc-dddd-000000000001';
  v_task  uuid;
  v_new   timestamptz;
  v_open  int;
  v_done  int;
  v_match int;
  v_start timestamptz;
  v_total int;
  v_before int;
  v_id    uuid;
  v_id2   uuid;
BEGIN
  INSERT INTO auth.users (id, email, role, aud, created_at, updated_at, is_anonymous)
  VALUES (v_user, 'occ_regen@test.local', 'authenticated', 'authenticated', now(), now(), true);
  INSERT INTO profiles (user_id, public_id, display_name)
  VALUES (v_user, 'occ-regen', 'Occ Regen');
  INSERT INTO households (id, name, created_by) VALUES (v_hh, 'Occ HH', v_user);
  INSERT INTO household_members (household_id, user_id, role, status, joined_at)
  VALUES (v_hh, v_user, 'owner', 'active', now());
  INSERT INTO household_membership_periods (household_id, user_id, joined_at)
  VALUES (v_hh, v_user, now());

  -- A: past-due incomplete -> future due leaves exactly one occurrence (TE-001)
  v_new := now() + interval '1 hour';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ A', v_user, v_user, now() - interval '1 hour') RETURNING id INTO v_task;
  UPDATE tasks SET due_at = v_new WHERE id = v_task;
  SELECT count(*), count(*) FILTER (WHERE scheduled_at = v_new)
    INTO v_open, v_match FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_open = 1 AND v_match = 1 THEN RAISE NOTICE 'A PASS: past-due edit leaves one occurrence';
  ELSE RAISE EXCEPTION 'A FAIL: open=%, at new due=%', v_open, v_match; END IF;

  -- B: future -> later future still leaves exactly one occurrence
  v_new := now() + interval '3 hours';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ B', v_user, v_user, now() + interval '1 hour') RETURNING id INTO v_task;
  UPDATE tasks SET due_at = v_new WHERE id = v_task;
  SELECT count(*), count(*) FILTER (WHERE scheduled_at = v_new)
    INTO v_open, v_match FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_open = 1 AND v_match = 1 THEN RAISE NOTICE 'B PASS: future edit leaves one occurrence';
  ELSE RAISE EXCEPTION 'B FAIL: open=%, at new due=%', v_open, v_match; END IF;

  -- C: completed occurrence survives a due_at edit
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ C', v_user, v_user, now() - interval '2 hours') RETURNING id INTO v_task;
  UPDATE task_occurrences SET completed_at = now(), completed_by = v_user WHERE task_id = v_task;
  UPDATE tasks SET due_at = now() + interval '1 hour' WHERE id = v_task;
  SELECT count(*) FILTER (WHERE completed_at IS NULL), count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO v_open, v_done FROM task_occurrences WHERE task_id = v_task;
  IF v_open = 1 AND v_done = 1 THEN RAISE NOTICE 'C PASS: completed history preserved';
  ELSE RAISE EXCEPTION 'C FAIL: open=%, completed=%', v_open, v_done; END IF;

  -- D: due_at cleared removes stale incomplete occurrences, keeps history
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ D', v_user, v_user, now() - interval '1 hour') RETURNING id INTO v_task;
  UPDATE tasks SET due_at = NULL WHERE id = v_task;
  SELECT count(*) INTO v_open FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_open = 0 THEN RAISE NOTICE 'D PASS: cleared due_at leaves no incomplete occurrence';
  ELSE RAISE EXCEPTION 'D FAIL: open=%', v_open; END IF;

  -- ----------------------------------------------------------------------
  -- TE-002: one-off -> recurring conversion (20261026000001)
  -- ----------------------------------------------------------------------

  -- E: overdue incomplete one-off -> Daily with a later start: the old
  --    occurrence is removed, the 30-day schedule starts at the new due_at.
  v_start := now() + interval '2 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ E', v_user, v_user, now() - interval '6 days') RETURNING id INTO v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*), count(*) FILTER (WHERE scheduled_at < v_start)
    INTO v_total, v_before FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_total = 30 AND v_before = 0 THEN RAISE NOTICE 'E PASS: stale overdue one-off occurrence removed';
  ELSE RAISE EXCEPTION 'E FAIL: open=%, before start=%', v_total, v_before; END IF;

  -- F: future incomplete one-off -> Daily with a later start: obsolete
  --    old occurrence removed.
  v_start := now() + interval '3 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ F', v_user, v_user, now() + interval '1 day') RETURNING id INTO v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*), count(*) FILTER (WHERE scheduled_at < v_start)
    INTO v_total, v_before FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_total = 30 AND v_before = 0 THEN RAISE NOTICE 'F PASS: obsolete future one-off occurrence removed';
  ELSE RAISE EXCEPTION 'F FAIL: open=%, before start=%', v_total, v_before; END IF;

  -- G: completed one-off occurrence survives the conversion.
  v_start := now() + interval '2 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ G', v_user, v_user, now() - interval '6 days') RETURNING id INTO v_task;
  UPDATE task_occurrences SET completed_at = now(), completed_by = v_user WHERE task_id = v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*) FILTER (WHERE completed_at IS NULL), count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO v_open, v_done FROM task_occurrences WHERE task_id = v_task;
  IF v_open = 30 AND v_done = 1 THEN RAISE NOTICE 'G PASS: completed one-off history preserved';
  ELSE RAISE EXCEPTION 'G FAIL: open=%, completed=%', v_open, v_done; END IF;

  -- H: regenerating again is idempotent (no duplicates, same row count).
  --    refresh_my_recurring_occurrences calls the generator exactly like this.
  PERFORM _generate_occurrences_for_task(t) FROM tasks t WHERE t.id = v_task;
  PERFORM _generate_occurrences_for_task(t) FROM tasks t WHERE t.id = v_task;
  SELECT count(*) FILTER (WHERE completed_at IS NULL), count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO v_open, v_done FROM task_occurrences WHERE task_id = v_task;
  IF v_open = 30 AND v_done = 1 THEN RAISE NOTICE 'H PASS: repeated regeneration is idempotent';
  ELSE RAISE EXCEPTION 'H FAIL: open=%, completed=%', v_open, v_done; END IF;

  -- I: an existing Daily task's missed (overdue) occurrences survive an
  --    ordinary refresh.
  v_task := pg_temp.legacy_recurring(v_hh, 'Occ I', v_user, now() - interval '3 days', 'daily');
  SELECT count(*) INTO v_before FROM task_occurrences
    WHERE task_id = v_task AND completed_at IS NULL AND scheduled_at < now();
  PERFORM _generate_occurrences_for_task(t) FROM tasks t WHERE t.id = v_task;
  SELECT count(*) INTO v_open FROM task_occurrences
    WHERE task_id = v_task AND completed_at IS NULL AND scheduled_at < now();
  IF v_before >= 3 AND v_open = v_before THEN RAISE NOTICE 'I PASS: overdue recurring occurrences kept on refresh';
  ELSE RAISE EXCEPTION 'I FAIL: overdue before=%, after=%', v_before, v_open; END IF;

  -- J: editing a recurring task's own start date. Pins the CURRENT, unchanged
  --    semantics: past incomplete occurrences stay (still overdue), future
  --    ones outside the new window go. Not an endorsement; changing it is a
  --    separate product decision.
  v_task := pg_temp.legacy_recurring(v_hh, 'Occ J', v_user, now() - interval '3 days', 'daily');
  SELECT count(*) INTO v_before FROM task_occurrences
    WHERE task_id = v_task AND completed_at IS NULL AND scheduled_at < now();
  v_start := now() + interval '1 day';
  UPDATE tasks SET due_at = v_start WHERE id = v_task;
  SELECT count(*) FILTER (WHERE scheduled_at < now()),
         count(*) FILTER (WHERE scheduled_at >= v_start)
    INTO v_open, v_total FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_before >= 3 AND v_open = v_before AND v_total = 30 THEN
    RAISE NOTICE 'J PASS: recurring start-date edit semantics unchanged';
  ELSE RAISE EXCEPTION 'J FAIL: past before=%, past after=%, from new start=%', v_before, v_open, v_total; END IF;

  -- K: conversion that keeps the same due_at must not delete and recreate
  --    the first occurrence (identity preserved).
  v_start := now() + interval '1 day';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ K', v_user, v_user, v_start) RETURNING id INTO v_task;
  SELECT id INTO v_id FROM task_occurrences WHERE task_id = v_task;
  UPDATE tasks SET recurrence_type = 'daily' WHERE id = v_task;
  SELECT id INTO v_id2 FROM task_occurrences WHERE task_id = v_task AND scheduled_at = v_start;
  SELECT count(*) INTO v_total FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_id = v_id2 AND v_total = 30 THEN RAISE NOTICE 'K PASS: same-start conversion keeps first occurrence';
  ELSE RAISE EXCEPTION 'K FAIL: id kept=%, open=%', v_id = v_id2, v_total; END IF;

  -- L: the old one-off occurrence lands on a slot of the new schedule: it is
  --    kept (same row), not deleted and recreated.
  v_start := now() + interval '1 day';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ L', v_user, v_user, v_start + interval '1 day') RETURNING id INTO v_task;
  SELECT id INTO v_id FROM task_occurrences WHERE task_id = v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT id INTO v_id2 FROM task_occurrences
    WHERE task_id = v_task AND scheduled_at = v_start + interval '1 day';
  SELECT count(*) INTO v_total FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_id = v_id2 AND v_total = 30 THEN RAISE NOTICE 'L PASS: old occurrence on a new slot is kept';
  ELSE RAISE EXCEPTION 'L FAIL: id kept=%, open=%', v_id = v_id2, v_total; END IF;

  -- M: conversion to an EARLIER start where the old one-off occurrence is not
  --    one of the new slots (past, between slots): it is removed, and the
  --    new window's own overdue slots remain.
  v_start := now() - interval '10 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ M', v_user, v_user, now() - interval '5 days' + interval '3 hours')
  RETURNING id INTO v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*) FILTER (WHERE scheduled_at = now() - interval '5 days' + interval '3 hours'),
         count(*)
    INTO v_before, v_total FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  -- Activation boundary: only slots from now on exist, no past backfill.
  IF v_before = 0 AND v_total = 30 THEN RAISE NOTICE 'M PASS: earlier-start conversion removes off-slot old occurrence';
  ELSE RAISE EXCEPTION 'M FAIL: old row left=%, open=%', v_before, v_total; END IF;

  -- N: earlier start where the old date coincides with a slot BEYOND the
  --    30-day window (slot index 40): not part of the generated window, past
  --    so the generator would never delete it -> the trigger must.
  v_start := now() - interval '50 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ N', v_user, v_user, v_start + interval '40 days') RETURNING id INTO v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*) FILTER (WHERE scheduled_at = v_start + interval '40 days'),
         count(*)
    INTO v_before, v_total FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_before = 0 AND v_total = 30 THEN RAISE NOTICE 'N PASS: old occurrence beyond the new window removed';
  ELSE RAISE EXCEPTION 'N FAIL: old row left=%, open=%', v_before, v_total; END IF;

  -- O: earlier-start conversion of an already COMPLETED one-off keeps it.
  v_start := now() - interval '10 days';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ O', v_user, v_user, now() - interval '5 days' + interval '3 hours')
  RETURNING id INTO v_task;
  UPDATE task_occurrences SET completed_at = now(), completed_by = v_user WHERE task_id = v_task;
  UPDATE tasks SET recurrence_type = 'daily', due_at = v_start WHERE id = v_task;
  SELECT count(*) FILTER (WHERE completed_at IS NOT NULL), count(*) FILTER (WHERE completed_at IS NULL)
    INTO v_done, v_open FROM task_occurrences WHERE task_id = v_task;
  IF v_done = 1 AND v_open = 30 THEN RAISE NOTICE 'O PASS: completed one-off kept on earlier-start conversion';
  ELSE RAISE EXCEPTION 'O FAIL: completed=%, open=%', v_done, v_open; END IF;

  -- P: an assignee-only edit on a one-off never takes the conversion branch.
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ P', v_user, v_user, now() - interval '2 days') RETURNING id INTO v_task;
  SELECT id INTO v_id FROM task_occurrences WHERE task_id = v_task;
  UPDATE tasks SET assigned_to = NULL WHERE id = v_task;
  SELECT id INTO v_id2 FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_id = v_id2 THEN RAISE NOTICE 'P PASS: assignee edit keeps the one-off occurrence';
  ELSE RAISE EXCEPTION 'P FAIL: occurrence replaced or lost'; END IF;
END $$;

ROLLBACK;
