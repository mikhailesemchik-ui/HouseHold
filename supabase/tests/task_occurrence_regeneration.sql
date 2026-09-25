-- ============================================================
-- Task occurrence regeneration tests (TE-001)
-- Usage: docker exec -i supabase_db_HouseHold psql -U postgres -d postgres \
--          < supabase/tests/task_occurrence_regeneration.sql
-- All tests should produce only NOTICE lines (no WARNING).
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_user  uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  v_hh    uuid := 'cccccccc-bbbb-cccc-dddd-000000000001';
  v_task  uuid;
  v_new   timestamptz;
  v_open  int;
  v_done  int;
  v_match int;
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
  ELSE RAISE WARNING 'A FAIL: open=%, at new due=%', v_open, v_match; END IF;

  -- B: future -> later future still leaves exactly one occurrence
  v_new := now() + interval '3 hours';
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ B', v_user, v_user, now() + interval '1 hour') RETURNING id INTO v_task;
  UPDATE tasks SET due_at = v_new WHERE id = v_task;
  SELECT count(*), count(*) FILTER (WHERE scheduled_at = v_new)
    INTO v_open, v_match FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_open = 1 AND v_match = 1 THEN RAISE NOTICE 'B PASS: future edit leaves one occurrence';
  ELSE RAISE WARNING 'B FAIL: open=%, at new due=%', v_open, v_match; END IF;

  -- C: completed occurrence survives a due_at edit
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ C', v_user, v_user, now() - interval '2 hours') RETURNING id INTO v_task;
  UPDATE task_occurrences SET completed_at = now(), completed_by = v_user WHERE task_id = v_task;
  UPDATE tasks SET due_at = now() + interval '1 hour' WHERE id = v_task;
  SELECT count(*) FILTER (WHERE completed_at IS NULL), count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO v_open, v_done FROM task_occurrences WHERE task_id = v_task;
  IF v_open = 1 AND v_done = 1 THEN RAISE NOTICE 'C PASS: completed history preserved';
  ELSE RAISE WARNING 'C FAIL: open=%, completed=%', v_open, v_done; END IF;

  -- D: due_at cleared removes stale incomplete occurrences, keeps history
  INSERT INTO tasks (household_id, title, created_by, assigned_to, due_at)
  VALUES (v_hh, 'Occ D', v_user, v_user, now() - interval '1 hour') RETURNING id INTO v_task;
  UPDATE tasks SET due_at = NULL WHERE id = v_task;
  SELECT count(*) INTO v_open FROM task_occurrences WHERE task_id = v_task AND completed_at IS NULL;
  IF v_open = 0 THEN RAISE NOTICE 'D PASS: cleared due_at leaves no incomplete occurrence';
  ELSE RAISE WARNING 'D FAIL: open=%', v_open; END IF;
END $$;

ROLLBACK;
