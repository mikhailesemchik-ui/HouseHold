-- ============================================================
-- WS-4: Restrict SECURITY DEFINER function access.
-- The functions below run as the postgres role. Anon (unauthenticated)
-- callers must not be able to invoke them; they rely on auth.uid()
-- for authorisation, but defence-in-depth requires the grant to be
-- removed so the function is unreachable before any internal check.
-- ============================================================

-- Remove both the implicit PUBLIC grant and the explicit anon grant,
-- then re-grant to explicit roles only.
revoke execute on function complete_occurrence(uuid)             from public, anon;
grant  execute on function complete_occurrence(uuid)             to authenticated;
grant  execute on function complete_occurrence(uuid)             to service_role;

revoke execute on function reopen_occurrence(uuid)               from public, anon;
grant  execute on function reopen_occurrence(uuid)               to authenticated;
grant  execute on function reopen_occurrence(uuid)               to service_role;

revoke execute on function _generate_occurrences_for_task(tasks) from public, anon;
grant  execute on function _generate_occurrences_for_task(tasks) to service_role;

revoke execute on function refresh_my_recurring_occurrences()    from public, anon;
grant  execute on function refresh_my_recurring_occurrences()    to authenticated;
grant  execute on function refresh_my_recurring_occurrences()    to service_role;

-- generate_invite_code is a helper called by create_household_invite.
-- It is not an RPC entry-point; anon and public access are unneeded.
revoke execute on function generate_invite_code() from public;
grant  execute on function generate_invite_code() to authenticated;
grant  execute on function generate_invite_code() to service_role;
