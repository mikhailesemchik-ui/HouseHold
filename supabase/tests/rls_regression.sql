-- ============================================================
-- RLS Regression Tests
-- Run after supabase db reset to verify immutability fixes.
-- Usage: docker exec supabase_db_HouseHold psql -U postgres -d postgres \
--          -f /tmp/rls_regression.sql
-- All tests should produce only NOTICE lines (no WARNING).
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_user_a uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_user_b uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  v_hh_a   uuid := 'aaaaaaaa-bbbb-cccc-dddd-000000000001';
  v_hh_b   uuid := 'aaaaaaaa-bbbb-cccc-dddd-000000000002';
  v_task_id       uuid;
  v_item_id       uuid;
  v_exp_id        uuid;
  v_caught        bool;
BEGIN
  -- Setup
  INSERT INTO auth.users (id, email, role, aud, created_at, updated_at, is_anonymous)
  VALUES
    (v_user_a, 'reg_a@test.local', 'authenticated', 'authenticated', now(), now(), true),
    (v_user_b, 'reg_b@test.local', 'authenticated', 'authenticated', now(), now(), true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO profiles (user_id, public_id, display_name) VALUES
    (v_user_a, 'reg-user-a', 'Reg A'), (v_user_b, 'reg-user-b', 'Reg B')
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO households (id, name, created_by) VALUES
    (v_hh_a, 'Reg HH A', v_user_a), (v_hh_b, 'Reg HH B', v_user_b)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO household_members (household_id, user_id, role, status, joined_at) VALUES
    (v_hh_a, v_user_a, 'owner',  'active', now()),
    (v_hh_b, v_user_b, 'owner',  'active', now()),
    (v_hh_b, v_user_a, 'member', 'active', now())
  ON CONFLICT (household_id, user_id) DO NOTHING;

  INSERT INTO household_membership_periods (household_id, user_id, joined_at) VALUES
    (v_hh_a, v_user_a, now()), (v_hh_b, v_user_b, now()), (v_hh_b, v_user_a, now())
  ON CONFLICT DO NOTHING;

  INSERT INTO tasks (id, household_id, title, created_by)
  VALUES (gen_random_uuid(), v_hh_a, 'Reg Task', v_user_a) RETURNING id INTO v_task_id;

  INSERT INTO shopping_items (id, household_id, name, created_by)
  VALUES (gen_random_uuid(), v_hh_a, 'Reg Item', v_user_a) RETURNING id INTO v_item_id;

  INSERT INTO expenses (id, household_id, title, amount_cents, currency, paid_by, paid_by_display_name, created_by)
  VALUES (gen_random_uuid(), v_hh_b, 'Reg Expense', 5000, 'EUR', v_user_a, 'Reg A', v_user_a)
  RETURNING id INTO v_exp_id;

  -- R1: tasks.household_id immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}';
  BEGIN
    UPDATE tasks SET household_id = v_hh_b WHERE id = v_task_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R1 PASS: tasks.household_id is immutable';
  ELSE RAISE WARNING 'R1 FAIL: tasks.household_id was changed'; END IF;

  -- R2: tasks.created_by immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}';
  BEGIN
    UPDATE tasks SET created_by = v_user_b WHERE id = v_task_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R2 PASS: tasks.created_by is immutable';
  ELSE RAISE WARNING 'R2 FAIL: tasks.created_by was changed'; END IF;

  -- R3: shopping_items.household_id immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}';
  BEGIN
    UPDATE shopping_items SET household_id = v_hh_b WHERE id = v_item_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R3 PASS: shopping_items.household_id is immutable';
  ELSE RAISE WARNING 'R3 FAIL: shopping_items.household_id was changed'; END IF;

  -- R4: expenses.amount_cents immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}';
  BEGIN
    UPDATE expenses SET amount_cents = 1 WHERE id = v_exp_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R4 PASS: expenses.amount_cents is immutable';
  ELSE RAISE WARNING 'R4 FAIL: expenses.amount_cents was changed'; END IF;

  -- R5: expenses.paid_by immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}';
  BEGIN
    UPDATE expenses SET paid_by = v_user_b WHERE id = v_exp_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R5 PASS: expenses.paid_by is immutable';
  ELSE RAISE WARNING 'R5 FAIL: expenses.paid_by was changed'; END IF;

  -- R6: expenses.created_by immutable
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}';
  BEGIN
    UPDATE expenses SET created_by = v_user_b WHERE id = v_exp_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF v_caught THEN RAISE NOTICE 'R6 PASS: expenses.created_by is immutable';
  ELSE RAISE WARNING 'R6 FAIL: expenses.created_by was changed'; END IF;

  -- R7: expenses.title is still mutable (sanity check)
  v_caught := false;
  SET LOCAL role = 'authenticated';
  SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}';
  BEGIN
    UPDATE expenses SET title = 'Updated Title' WHERE id = v_exp_id;
  EXCEPTION WHEN others THEN v_caught := true; END;
  RESET role; RESET "request.jwt.claims";
  IF NOT v_caught THEN RAISE NOTICE 'R7 PASS: expenses.title is mutable (expected)';
  ELSE RAISE WARNING 'R7 FAIL: expenses.title update was unexpectedly blocked'; END IF;

  -- R8: anon cannot call complete_occurrence
  v_caught := false;
  SET LOCAL role = 'anon';
  BEGIN
    PERFORM complete_occurrence('00000000-0000-0000-0000-000000000000'::uuid);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  RESET role;
  IF v_caught THEN RAISE NOTICE 'R8 PASS: complete_occurrence not callable by anon';
  ELSE RAISE WARNING 'R8 FAIL: complete_occurrence callable by anon (WS-4 fix may not have applied)'; END IF;

  -- R9: anon cannot call reopen_occurrence
  v_caught := false;
  SET LOCAL role = 'anon';
  BEGIN
    PERFORM reopen_occurrence('00000000-0000-0000-0000-000000000000'::uuid);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  RESET role;
  IF v_caught THEN RAISE NOTICE 'R9 PASS: reopen_occurrence not callable by anon';
  ELSE RAISE WARNING 'R9 FAIL: reopen_occurrence callable by anon'; END IF;

  -- Cleanup
  RESET role; RESET "request.jwt.claims";
  DELETE FROM expenses WHERE id = v_exp_id;
  DELETE FROM tasks WHERE id = v_task_id;
  DELETE FROM shopping_items WHERE id = v_item_id;
  DELETE FROM household_membership_periods WHERE household_id IN (v_hh_a, v_hh_b);
  DELETE FROM household_members WHERE household_id IN (v_hh_a, v_hh_b);
  DELETE FROM households WHERE id IN (v_hh_a, v_hh_b);
  DELETE FROM profiles WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users WHERE id IN (v_user_a, v_user_b);
END $$;

ROLLBACK;
