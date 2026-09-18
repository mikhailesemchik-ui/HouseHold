-- Replace auto_expose_new_tables implicit grants with precise per-table,
-- per-role privileges following least privilege.
--
-- auto_expose_new_tables = true was granting ALL privileges on ALL tables
-- to anon and authenticated implicitly. This migration makes grants explicit
-- and narrows them to only what the application requires.
-- Applies cleanly on a fresh db/reset and is also safe on an existing db
-- (revokes first, then re-grants precisely).

-- -------------------------------------------------------
-- 1. Revoke all implicit broad grants.
--    After auto_expose_new_tables = false, new tables will
--    not receive auto-grants. Explicit revoke here ensures
--    existing databases are also cleaned up correctly.
-- -------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

-- -------------------------------------------------------
-- 2. service_role: full access on all tables.
--    service_role bypasses RLS by design and is required
--    by edge functions and Supabase internal tooling.
-- -------------------------------------------------------
grant all on all tables in schema public to service_role;

-- -------------------------------------------------------
-- 3. authenticated: precise per-table privileges.
--
-- Rules applied:
--   - Only operations the app performs directly via PostgREST.
--   - Operations routed through SECURITY DEFINER RPCs do not
--     require the calling role to hold table INSERT/UPDATE.
--   - Server-only tables (notification_outbox) receive no grant.
--   - RLS remains the primary row-level enforcement layer.
-- -------------------------------------------------------

-- Own-profile create/read/edit; read co-members' display names
grant select, insert, update on profiles to authenticated;

-- Read own households; creation is via create_household() RPC
grant select on households to authenticated;

-- Read household membership; all mutations via RPCs
grant select on household_members to authenticated;

-- Read membership-period history; server-managed writes
grant select on household_membership_periods to authenticated;

-- Owners read own household's invites; create/revoke via RPCs
grant select on household_invites to authenticated;

-- Full CRUD on tasks; RLS enforces household-membership scope
grant select, insert, update, delete on tasks to authenticated;

-- Read + Realtime subscribe; complete/reopen go through RPCs
grant select on task_occurrences to authenticated;

-- Read-only activity on tasks; triggers write these rows
grant select on task_events to authenticated;

-- Full CRUD on shopping items; RLS enforces household scope
grant select, insert, update, delete on shopping_items to authenticated;

-- Read stream; update title directly; delete; insert via RPC
grant select, update, delete on expenses to authenticated;

-- Read-only; create_equal_split_expense() RPC manages writes
grant select on expense_participants to authenticated;

-- Read stream; delete own settlement; insert via RPC
grant select, delete on expense_settlements to authenticated;

-- Read-only unified activity feed; triggers write these rows
grant select on household_events to authenticated;

-- Own push token management; RLS enforces own-token-only
grant select, insert, update, delete on device_push_tokens to authenticated;

-- notification_outbox: intentionally no grant to authenticated or anon.
-- Accessible only via service_role (used by the edge function).
