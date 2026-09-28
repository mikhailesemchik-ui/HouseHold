-- ============================================================
-- Shopping item household_events regression (MU-003)
-- Usage: docker exec -i supabase_db_HouseHold psql -U postgres -d postgres \
--          < supabase/tests/household_events_shopping_regression.sql
-- All tests should produce only NOTICE lines (no WARNING).
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_user  uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  v_hh    uuid := 'dddddddd-bbbb-cccc-dddd-000000000001';
  v_item  uuid;
  v_count int;
BEGIN
  INSERT INTO auth.users (id, email, role, aud, created_at, updated_at, is_anonymous)
  VALUES (v_user, 'mu003@test.local', 'authenticated', 'authenticated', now(), now(), true);
  INSERT INTO profiles (user_id, public_id, display_name)
  VALUES (v_user, 'mu003-user', 'MU003 User');
  INSERT INTO households (id, name, created_by) VALUES (v_hh, 'MU003 HH', v_user);
  INSERT INTO household_members (household_id, user_id, role, status, joined_at)
  VALUES (v_hh, v_user, 'owner', 'active', now());
  INSERT INTO household_membership_periods (household_id, user_id, joined_at)
  VALUES (v_hh, v_user, now());

  -- A: insert logs shopping_item_added
  INSERT INTO shopping_items (id, household_id, name, created_by)
  VALUES (gen_random_uuid(), v_hh, 'Avocados', v_user) RETURNING id INTO v_item;
  SELECT count(*) INTO v_count FROM household_events
    WHERE entity_id = v_item AND event_type = 'shopping_item_added';
  IF v_count = 1 THEN RAISE NOTICE 'A PASS: shopping_item_added emitted once';
  ELSE RAISE WARNING 'A FAIL: shopping_item_added count=%', v_count; END IF;

  -- B: complete emits shopping_item_completed. completed_by must be the
  -- authenticated user (see 20260825000012), so run as v_user via role/JWT,
  -- matching rls_regression.sql's pattern.
  EXECUTE format('SET LOCAL role = %L', 'authenticated');
  EXECUTE format(
    'SET LOCAL "request.jwt.claims" = %L',
    json_build_object('sub', v_user, 'role', 'authenticated')::text
  );
  UPDATE shopping_items SET completed_at = now(), completed_by = v_user WHERE id = v_item;
  RESET role; RESET "request.jwt.claims";
  SELECT count(*) INTO v_count FROM household_events
    WHERE entity_id = v_item AND event_type = 'shopping_item_completed';
  IF v_count = 1 THEN RAISE NOTICE 'B PASS: shopping_item_completed emitted once';
  ELSE RAISE WARNING 'B FAIL: shopping_item_completed count=%', v_count; END IF;

  -- C: reopen emits shopping_item_reopened (the MU-003 fix)
  EXECUTE format('SET LOCAL role = %L', 'authenticated');
  EXECUTE format(
    'SET LOCAL "request.jwt.claims" = %L',
    json_build_object('sub', v_user, 'role', 'authenticated')::text
  );
  UPDATE shopping_items SET completed_at = NULL, completed_by = NULL WHERE id = v_item;
  RESET role; RESET "request.jwt.claims";
  SELECT count(*) INTO v_count FROM household_events
    WHERE entity_id = v_item AND event_type = 'shopping_item_reopened';
  IF v_count = 1 THEN RAISE NOTICE 'C PASS: shopping_item_reopened emitted once';
  ELSE RAISE WARNING 'C FAIL: shopping_item_reopened count=%', v_count; END IF;

  -- D: an unrelated update (name change) does not emit a duplicate event
  SELECT count(*) INTO v_count FROM household_events WHERE entity_id = v_item;
  UPDATE shopping_items SET name = 'Avocados (ripe)' WHERE id = v_item;
  IF (SELECT count(*) FROM household_events WHERE entity_id = v_item) = v_count THEN
    RAISE NOTICE 'D PASS: a name-only update emits no new event';
  ELSE
    RAISE WARNING 'D FAIL: name-only update emitted an event';
  END IF;
END $$;

ROLLBACK;
