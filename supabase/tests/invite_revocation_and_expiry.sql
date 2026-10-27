-- ============================================================
-- Invitation revocation and expiry tests (migration 20261103000001, finding F8)
-- Usage: docker exec -i <local db container> psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
--          < supabase/tests/invite_revocation_and_expiry.sql
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

CREATE FUNCTION pg_temp.val(p_expr text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE 'select (' || p_expr || ')::text' INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN 'err:' || SQLSTATE;
END $$;

DO $$
DECLARE
  a  uuid := 'fa000000-0000-0000-0000-00000000000a'; -- owner
  b  uuid := 'fa000000-0000-0000-0000-00000000000b'; -- member that gets removed
  c  uuid := 'fa000000-0000-0000-0000-00000000000c'; -- member that stays
  d  uuid := 'fa000000-0000-0000-0000-00000000000d'; -- outsider
  x  uuid := 'fa000000-0000-0000-0000-00000000000e'; -- owner of another household
  h uuid; hx uuid;
  code1 text; code2 text; code3 text; codex text; code_new text; code_exp text; code_old text;
  code_rev text; inv1 uuid;
BEGIN
  INSERT INTO auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
  SELECT id,'inv'||i||'@test.local','authenticated','authenticated',now(),now(),true
  FROM (VALUES (a,1),(b,2),(c,3),(d,4),(x,5)) v(id,i);
  INSERT INTO profiles (user_id,public_id,display_name)
  SELECT id,'INV-'||i,'Inv'||i FROM (VALUES (a,1),(b,2),(c,3),(d,4),(x,5)) v(id,i);

  PERFORM pg_temp.as_user(a); SELECT id INTO h FROM create_household('INV H');
  code1 := (create_household_invite(h)).code;
  code2 := (create_household_invite(h)).code;
  PERFORM pg_temp.as_user(x); SELECT id INTO hx FROM create_household('INV X');
  codex := (create_household_invite(hx)).code;
  PERFORM pg_temp.as_user(b); PERFORM join_household_by_invite(code1);
  PERFORM pg_temp.as_user(c); PERFORM join_household_by_invite(code2);
  PERFORM pg_temp.as_admin();

  PERFORM pg_temp.check('01 a new code expires seven days after creation',
    (SELECT bool_and(expires_at BETWEEN now() + interval '7 days' - interval '1 minute'
                                    AND now() + interval '7 days' + interval '1 minute')
     FROM household_invites WHERE household_id = h));
  INSERT INTO household_invites (household_id, code, created_by) VALUES (h, 'TEST-0001', a);
  PERFORM pg_temp.check('02 the expiry is filled by the database for any other insert path',
    (SELECT expires_at > now() + interval '6 days' FROM household_invites WHERE code = 'TEST-0001'));
  DELETE FROM household_invites WHERE code = 'TEST-0001';
  PERFORM pg_temp.check('03 a valid code works before expiry (b and c joined)',
    (SELECT count(*) FROM household_members WHERE household_id = h AND status = 'active') = 3);

  -- expired / revoked codes
  PERFORM pg_temp.as_user(a); code_exp := (create_household_invite(h)).code; PERFORM pg_temp.as_admin();
  UPDATE household_invites SET expires_at = now() - interval '1 second' WHERE code = code_exp;
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('04 an expired code is rejected with HO004',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code_exp)) = 'err:HO004');
  PERFORM pg_temp.as_user(a);
  code_rev := (create_household_invite(h)).code;
  PERFORM revoke_household_invite((SELECT id FROM household_invites WHERE code = code_rev));
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('05 a revoked code is rejected with HO004',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code_rev)) = 'err:HO004');
  PERFORM pg_temp.check('05b an outsider is not a member after the failed attempts',
    NOT EXISTS (SELECT 1 FROM household_members WHERE household_id = h AND user_id = d AND status = 'active'));

  -- authorization
  PERFORM pg_temp.as_admin();
  SELECT id INTO inv1 FROM household_invites WHERE code = code1;
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('06 a non-owner member cannot remove members',
    pg_temp.val(format('remove_household_member(%L,%L)', h, b)) = 'err:HO002');
  PERFORM pg_temp.check('06b a non-owner member cannot revoke an invite',
    pg_temp.val(format('revoke_household_invite(%L)', inv1)) = 'err:HO002');
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('07 an outsider cannot remove members or read the invites',
    pg_temp.val(format('remove_household_member(%L,%L)', h, b)) = 'err:HO002'
    AND (SELECT count(*) FROM household_invites) = 0);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('07b ... and no invite was revoked by those attempts',
    (SELECT count(*) FROM household_invites WHERE household_id = h AND revoked_at IS NULL AND code IN (code1, code2)) = 2);

  -- legacy invites: NULL expiry, expired, explicitly short
  ALTER TABLE household_invites DISABLE TRIGGER household_invites_default_expiry;
  INSERT INTO household_invites (household_id, code, created_by, expires_at) VALUES
    (h, 'LEGA-0001', a, NULL), (h, 'LEGA-0002', a, now() - interval '2 days'), (h, 'LEGA-0003', a, now() + interval '1 hour');
  INSERT INTO household_invites (household_id, code, created_by, expires_at, revoked_at)
    VALUES (h, 'LEGA-0004', a, NULL, now() - interval '1 day');
  ALTER TABLE household_invites ENABLE TRIGGER household_invites_default_expiry;
  -- the migration's transition statement
  UPDATE household_invites SET expires_at = now() + interval '7 days'
  WHERE expires_at IS NULL AND revoked_at IS NULL;
  PERFORM pg_temp.check('08 a legacy non-expiring active code gets a seven-day window',
    (SELECT expires_at BETWEEN now() + interval '6 days' AND now() + interval '7 days' + interval '1 minute'
     FROM household_invites WHERE code = 'LEGA-0001'));
  PERFORM pg_temp.check('09 expired, short-lived and revoked legacy codes are not reactivated',
    (SELECT expires_at < now() FROM household_invites WHERE code = 'LEGA-0002')
    AND (SELECT expires_at < now() + interval '2 hours' FROM household_invites WHERE code = 'LEGA-0003')
    AND (SELECT expires_at IS NULL AND revoked_at IS NOT NULL FROM household_invites WHERE code = 'LEGA-0004'));

  -- removal
  PERFORM pg_temp.as_user(a);
  PERFORM remove_household_member(h, b);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('10 removing a member revokes every active code of that household',
    NOT EXISTS (SELECT 1 FROM household_invites
                WHERE household_id = h AND revoked_at IS NULL
                  AND (expires_at IS NULL OR expires_at > now())));
  PERFORM pg_temp.check('10b ... but already expired codes are left as they were',
    (SELECT bool_and(revoked_at IS NULL) FROM household_invites WHERE code IN (code_exp, 'LEGA-0002')));
  PERFORM pg_temp.check('11 other households keep their valid code',
    (SELECT revoked_at IS NULL AND expires_at > now() FROM household_invites WHERE code = codex));
  PERFORM pg_temp.check('12 other active members stay active and keep their roles',
    (SELECT count(*) FROM household_members WHERE household_id = h AND status = 'active' AND role = 'owner' AND user_id = a) = 1
    AND (SELECT count(*) FROM household_members WHERE household_id = h AND status = 'active' AND role = 'member' AND user_id = c) = 1
    AND (SELECT status FROM household_members WHERE household_id = h AND user_id = b) = 'left');
  PERFORM pg_temp.as_user(b);
  PERFORM pg_temp.check('13 the removed member cannot rejoin with the old codes',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code1)) = 'err:HO004'
    AND pg_temp.val(format('(join_household_by_invite(%L)).id', code2)) = 'err:HO004'
    AND pg_temp.val(format('(join_household_by_invite(%L)).id', 'LEGA-0001')) = 'err:HO004');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('13b ... and is still a former member',
    (SELECT status FROM household_members WHERE household_id = h AND user_id = b) = 'left');
  PERFORM pg_temp.as_user(a);
  code_new := (create_household_invite(h)).code;
  PERFORM pg_temp.as_user(d);
  PERFORM pg_temp.check('14 the owner can create a fresh code and a new person can use it',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code_new)) = h::text);

  -- failed removal leaves invites untouched
  PERFORM pg_temp.as_user(a);
  code3 := (create_household_invite(h)).code;
  PERFORM pg_temp.check('15 a refused removal does not revoke anything',
    pg_temp.val(format('remove_household_member(%L,%L)', h, b)) = 'err:HO005'
    AND pg_temp.val(format('remove_household_member(%L,%L)', h, a)) = 'err:HO007');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('15b ... the code is still valid',
    (SELECT revoked_at IS NULL FROM household_invites WHERE code = code3));

  -- another household's owner cannot affect this household
  PERFORM pg_temp.as_user(x);
  PERFORM pg_temp.check('16 another household owner cannot remove members here',
    pg_temp.val(format('remove_household_member(%L,%L)', h, c)) = 'err:HO002');
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('16b ... nor revoke codes here',
    (SELECT revoked_at IS NULL FROM household_invites WHERE code = code3));

  -- voluntary leave does not rotate codes
  PERFORM pg_temp.as_user(d); PERFORM leave_household(h);
  PERFORM pg_temp.as_admin();
  PERFORM pg_temp.check('17 leaving voluntarily leaves the invite codes alone',
    (SELECT revoked_at IS NULL FROM household_invites WHERE code IN (code_new)));

  -- join RPC protections intact
  PERFORM pg_temp.as_user(c);
  PERFORM pg_temp.check('18 an existing member joining again is a no-op and keeps the role',
    pg_temp.val(format('(join_household_by_invite(%L)).id', code3)) = h::text);
  PERFORM pg_temp.check('19 anonymous callers are refused',
    (SELECT has_function_privilege('anon', 'join_household_by_invite(text)', 'EXECUTE')) = false
    AND (SELECT has_function_privilege('anon', 'remove_household_member(uuid,uuid)', 'EXECUTE')) = false);
END $$;

ROLLBACK;
