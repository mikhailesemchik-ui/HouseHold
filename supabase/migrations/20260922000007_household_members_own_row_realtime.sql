-- FLOW-001: a removed member's running client never learned it lost access.
-- After removal the user can no longer read household events or member rows
-- (both require an active membership), and household_members was not in the
-- realtime publication, so no signal reached them.
--
-- 1. Let a user read their OWN membership rows regardless of status. The row
--    holds only household_id, user_id, role, status, joined_at, left_at — that
--    user's own membership metadata; nothing about other members. Additive:
--    the existing active-member policy is unchanged.
-- 2. Publish household_members so the client can subscribe to its own rows
--    (filtered by user_id). Default replica identity is enough: UPDATE events
--    carry the full new row, and only INSERT/UPDATE are consumed.
create policy "household_members_select_own"
  on household_members for select
  to authenticated
  using (user_id = auth.uid());

alter publication supabase_realtime add table household_members;
