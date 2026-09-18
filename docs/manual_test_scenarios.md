# Household OS — Manual Functional Test Scenarios

**Version:** 2026-08-31  
**Purpose:** Pre-UI-polish acceptance checklist. Covers every core product flow that automated tests cannot fully validate.  
**Automated baseline:** ~290 passing unit/widget tests.

---

## Standard test identities

| Identity | Role |
|----------|------|
| **User A** | Owner of `Home`; member of `Parents` |
| **User B** | Normal member of `Home` |
| **User C** | Optional third member of `Home` |

Households: **Home**, **Parents**

---

## Pending external setup (apply before testing)

1. `supabase db push` — four pending migrations:
   - `20260825000017_profile_updates.sql`
   - `20260831000001_fix_generate_invite_code.sql`
   - `20260831000002_create_settlements.sql`
   - `20260831000003_membership_activity_events.sql`
2. FCM credentials (`FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL`, `FCM_PRIVATE_KEY`) in Supabase Edge Function secrets
3. `google-services.json` for Android FCM token delivery
4. APNs key + `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` for iOS
5. Supabase Storage `avatars` bucket (public) with per-user RLS
6. Edge Function `process-notification-outbox` deployed and scheduled/triggered

---

## 1 — Startup and Anonymous Identity

### STARTUP-01 — First launch (no prior session)

**Preconditions**
- Fresh install, no saved session.
- Network available.

**Steps**
1. Launch app.

**Expected**
- No registration/sign-in screen appears.
- Loading indicator shown briefly.
- Main app opens directly to Today.
- Generated display name (e.g. `User-ZG49`) is visible in Profile.
- Public ID (e.g. `ZG49-UVV1`) is visible in Profile.

**History**
- One profile row created in `profiles` table.
- No duplicate anonymous users on repeated launches.

**Notifications**
- None.

**Verification**
- Automated coverage: Partial (`startup_screen_test.dart` covers loading/error UI; identity creation not fully mocked in tests)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### STARTUP-02 — Existing session persists across restart

**Preconditions**
- User A has launched the app at least once (anonymous identity created).

**Steps**
1. Note the current display name and public ID.
2. Force-close the app.
3. Relaunch.

**Expected**
- Same display name and public ID displayed.
- Same household memberships visible.
- No new anonymous account created.
- No sign-in prompt.

**History**
- Supabase auth session reused; no duplicate `profiles` row.

**Notifications**
- None.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### STARTUP-03 — Launch without network

**Preconditions**
- Device has no network access (airplane mode).

**Steps**
1. Enable airplane mode.
2. Launch app.

**Expected**
- Friendly error message shown (e.g. "Couldn't connect. Check your internet connection and try again.").
- No raw `SocketException`, `ClientException`, or stack trace.
- A Retry button is visible.

**History**
- No fake local identity created.

**Notifications**
- None.

**Verification**
- Automated coverage: Full (`startup_screen_test.dart` tests `startupFriendlyErrorMessage` for SocketException/ClientException)
- Manual device test: **Required** (to confirm error surface on actual device)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### STARTUP-04 — Retry after network restored

**Preconditions**
- Airplane mode caused STARTUP-03 state (Retry button visible).

**Steps**
1. Disable airplane mode.
2. Tap Retry.

**Expected**
- App loads successfully.
- Correct identity loaded.
- No duplicate session/profile created.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 2 — Profile

### PROFILE-01 — Edit display name

**Preconditions**
- User A is logged in.

**Steps**
1. Open Profile.
2. Tap edit icon next to display name.
3. Enter a new name (e.g. `Alice`).
4. Save.

**Expected**
- Display name updates in Profile immediately.
- No app restart needed.
- Public ID unchanged.

**History**
- `profiles.display_name` updated.
- Auth UID unchanged.

**Verification**
- Automated coverage: Partial (validation unit-tested in `profile_validation_test.dart`; repository call requires device)
- Manual device test: **Required**
- Backend/external setup: Required (migration `20260825000017`)

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-02 — Display name whitespace trimming and blank rejection

**Preconditions**
- Profile edit dialog is open.

**Steps**
1. Submit a name that is only spaces.
2. Submit a name with leading/trailing whitespace.

**Expected**
- Blank (spaces only) is rejected with an inline error message.
- Name with leading/trailing whitespace is trimmed before save.

**Verification**
- Automated coverage: Full (`profile_validation_test.dart`)
- Manual device test: Recommended (UI feedback)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-03 — Name change persists after restart

**Preconditions**
- User A has changed their name to `Alice`.

**Steps**
1. Force-close app.
2. Relaunch.

**Expected**
- Profile still shows `Alice`.
- Public ID unchanged.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Required (migration `20260825000017`)

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-04 — Name change visible to household member

**Preconditions**
- User A and User B are active members of Home.
- User B's device is online.

**Steps**
1. User A changes display name to `Alice`.
2. User B views Members or Activity in Home.

**Expected**
- User B sees `Alice` as the member name.
- Historical activity entries snapshot the name at event time (older entries may show the prior name).

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-05 — Add avatar

**Preconditions**
- User A has no avatar.

**Steps**
1. Tap avatar area in Profile.
2. Choose "Choose photo".
3. Confirm photo permission prompt (first time only).
4. Select a photo from gallery.

**Expected**
- Avatar uploads and appears in Profile.
- No raw URL/path shown to user.

**History**
- Avatar file stored in Supabase Storage `avatars/{userId}/avatar.{ext}`.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Required (Storage bucket + migration `20260825000017`)

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-06 — Replace avatar

**Preconditions**
- User A has an existing avatar.

**Steps**
1. Tap avatar.
2. Choose "Choose photo".
3. Select a different photo.

**Expected**
- New avatar replaces old one.
- Old file overwritten in Storage (upsert).

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-07 — Remove avatar

**Preconditions**
- User A has an existing avatar.

**Steps**
1. Tap avatar.
2. Choose "Remove photo".

**Expected**
- Avatar removed from profile.
- Storage files deleted (best-effort).
- Placeholder icon shown.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-08 — Photos permission requested only on avatar action

**Preconditions**
- Permission not yet granted.

**Steps**
1. Open app and navigate normally (Today, Homes, Tasks, Shopping).
2. Only when tapping avatar action, observe permission prompt.

**Expected**
- No photo permission prompt at launch.
- No photo permission prompt from any screen other than avatar action.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### PROFILE-09 — Public ID is stable and never exposes auth UUID

**Preconditions**
- User A is logged in.

**Steps**
1. Open Profile.
2. Inspect all visible text.
3. Copy public ID.

**Expected**
- Public ID format (e.g. `ZG49-UVV1`) visible and copyable.
- No raw Supabase UUID visible anywhere in the app.
- Public ID unchanged after name change.
- Public ID unchanged after restart.

**Verification**
- Automated coverage: Partial (public ID generation tested; UI inspection requires device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 3 — Multiple Households

### MULTI-01 — User A sees both households

**Preconditions**
- User A is owner of Home and member of Parents.

**Steps**
1. Open Homes.

**Expected**
- Both Home and Parents appear in the list.
- Correct names shown.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### MULTI-02 — Household data is isolated

**Preconditions**
- Home has tasks, shopping, expenses, members.
- Parents has separate data.

**Steps**
1. Open Home → Tasks. Note items.
2. Open Parents → Tasks. Note items.

**Expected**
- Tasks from Home do not appear in Parents.
- Shopping, Expenses, Members, Activity, Statistics are all isolated per household.

**Verification**
- Automated coverage: None (RLS enforced at DB; widget tests mock data)
- Manual device test: **Required**
- Backend/external setup: Not required (RLS)

**Status**
- [ ] Pass  — [ ] Fail

---

### MULTI-03 — Today aggregates across all active households

**Preconditions**
- User A has tasks assigned in both Home and Parents.

**Steps**
1. Open Today.

**Expected**
- Entries from both Home and Parents appear with correct household label.
- No entries from households A has left.

**Verification**
- Automated coverage: Partial (`today_test.dart` covers section rendering; cross-household requires device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 4 — Household Creation

### CREATE-01 — Create household

**Preconditions**
- User A is logged in.

**Steps**
1. Open Homes.
2. Tap "New home".
3. Enter name "Home".
4. Confirm.

**Expected**
- Home appears in Homes list.
- Opening Home shows the dashboard.
- User A is the active owner (visible in Members).
- Invite functionality is available.

**History**
- One `household_members` row with `role='owner'`, `status='active'`.
- One `household_membership_periods` row opened.

**Verification**
- Automated coverage: Partial (name validation unit-tested; creation RPC requires device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 5 — Invites and Join

### INVITE-01 — Valid invite: B joins Home

**Preconditions**
- User A is owner of Home with no other members.
- User B has the app installed and is anonymous.

**Steps**
1. User A opens Home → "Invite member".
2. Code is created (format: `XXXX-XXXX`).
3. A shares the code with B.
4. B opens Homes → "Join home".
5. B enters the code.
6. B confirms.

**Expected**
- B joins as `member`.
- B sees Home in their Homes list.
- A sees B in Members list.
- Both UIs update without restart.

**History**
- `household_members` row created for B with `role='member'`, `status='active'`.
- `household_membership_periods` row created.

**Notifications**
- A (and any other existing active members) may receive a push notification ("B joined Home") if Household updates is enabled.
- B does NOT receive a self-join push.

**Verification**
- Automated coverage: None (RPC requires real Supabase)
- Manual device test: **Required**
- Backend/external setup: Required (migration `20260831000001`)

**Status**
- [ ] Pass  — [ ] Fail

---

### INVITE-02 — Invalid invite code

**Preconditions**
- User B attempts to join.

**Steps**
1. B enters an invalid code (e.g. `AAAA-BBBB`).

**Expected**
- Clear user-facing error: code invalid, expired, or revoked.
- No crash.
- No raw Postgres exception shown.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### INVITE-03 — Revoked invite code

**Preconditions**
- User A created an invite and then revoked it.

**Steps**
1. B attempts to join with the revoked code.

**Expected**
- Clear error: code invalid/revoked.
- No join occurs.

**Verification**
- Automated coverage: Partial (`HouseholdInvite.isActive` unit-tested; revoke RPC requires device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### INVITE-04 — Already-active member attempts rejoin

**Preconditions**
- B is already an active member of Home.

**Steps**
1. B enters a valid invite code for Home.

**Expected**
- No duplicate membership row created.
- No duplicate membership period created.
- B's existing state is preserved.

**Verification**
- Automated coverage: None (RPC uses `on conflict do nothing` / idempotent logic)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### INVITE-05 — Former member rejoins

**Preconditions**
- B previously joined and left Home (status='left').
- A has created a new invite.

**Steps**
1. B enters the new invite code.

**Expected**
- B becomes active member again (same user identity).
- New membership period opened.
- Past tasks, expenses, history remain and are still attributed to B.
- B does NOT re-acquire owner role.

**History**
- Previous `household_membership_periods` row preserved with `left_at` set.
- New `household_membership_periods` row opened.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 6 — Leave Household

### LEAVE-01 — Normal member leaves

**Preconditions**
- B is an active member of Home.

**Steps**
1. B opens Home dashboard.
2. Taps "Leave home" from menu.
3. Confirms.

**Expected**
- Home disappears from B's Homes list.
- B disappears from A's Members view (active count).
- B loses access to Home content.

**History**
- `household_members.status = 'left'` for B.
- `household_membership_periods.left_at` set.
- Past tasks, expenses, activity remain intact.

**Notifications**
- None specified for member self-leave.

**Verification**
- Automated coverage: None (RPC requires real Supabase)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 7 — Sole-Owner Protection

### OWNER-01 — Only owner cannot leave without transferring

**Preconditions**
- User A is the only active owner of Home (no co-owner).

**Steps**
1. A opens Home.
2. Taps "Leave home".
3. Confirms.

**Expected**
- Operation blocked with a clear message: "You are the only owner. Assign another owner before leaving."
- Household still exists.
- A is still the owner.

**Verification**
- Automated coverage: None (error-code mapping tested in widget tests)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 8 — Ownership Transfer

### TRANSFER-01 — Transfer ownership from A to B

**Preconditions**
- A is owner; B is active member.

**Steps**
1. A opens Members in Home.
2. Initiates "Transfer ownership" to B.
3. Confirms.

**Expected**
- A's role changes to `member`.
- B's role changes to `owner`.
- Role labels update in Members list without restart.
- B gains owner-level actions (e.g. invite, remove member).
- A can now leave the household normally.

**History**
- Both `household_members` rows updated atomically.

**Notifications**
- B receives push: "You are now the owner of Home" (if Household updates enabled).

**Verification**
- Automated coverage: None (RPC requires real Supabase)
- Manual device test: **Required**
- Backend/external setup: Required (push requires FCM/APNs configured)

**Status**
- [ ] Pass  — [ ] Fail

---

## 9 — Remove Member

### REMOVE-01 — Owner removes B

**Preconditions**
- A is owner; B is active member with tasks assigned and expenses shared.

**Steps**
1. A opens Members.
2. Selects B → "Remove".
3. Confirms.

**Expected**
- B disappears from active Members on A's device.
- B loses access to Home dashboard and content.
- Membership period closes.
- Past task completions by B remain in history/statistics.
- Future incomplete tasks assigned to B are unassigned (no automatic reassignment).
- Completed historical occurrences for B remain unchanged.

**Notifications**
- B receives push: "You were removed from Home" (if Household updates enabled).
- Tapping push opens `/homes` (Homes list), NOT the inaccessible Home dashboard.

**Verification**
- Automated coverage: Partial (push routing to `/homes` tested in `remote_push_notification_service_test.dart`)
- Manual device test: **Required**
- Backend/external setup: Required (push)

**Status**
- [ ] Pass  — [ ] Fail

---

### REMOVE-02 — Push tap from removal leads to safe destination

**Preconditions**
- B has been removed and receives the push notification.

**Steps**
1. B taps the removal push notification.

**Expected**
- App opens to Homes list (`/homes`).
- No crash.
- Home that B was removed from is not in the list.
- No raw error shown.

**Verification**
- Automated coverage: Full (routing logic tested; end-to-end tap requires device)
- Manual device test: **Required**
- Backend/external setup: Required (push delivery)

**Status**
- [ ] Pass  — [ ] Fail

---

## 10 — Removed Member Rejoins

### REJOIN-01 — Removed member rejoins with new invite

**Preconditions**
- B was removed from Home.
- A creates a new invite.

**Steps**
1. B enters the new invite code.

**Expected**
- B joins as `member` (previous owner role NOT restored).
- New membership period opens.
- Historical tasks, expenses, statistics attributed to B remain visible.
- Past activity uses B's identity (not "Deleted member").

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 11 — Basic Tasks

### TASK-01 — Create unassigned task

**Preconditions**
- A is in Home → Tasks.

**Steps**
1. Create task "Buy milk" (no assignee, no due date).

**Expected**
- Task appears in Home Tasks list.
- Task does NOT appear in A's or B's Today.
- Realtime: B sees it appear without refresh.

**Verification**
- Automated coverage: Partial (`tasks_test.dart` covers widget; realtime requires device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TASK-02 — Create assigned task

**Preconditions**
- A and B are active members.

**Steps**
1. A creates "Buy milk" assigned to B.

**Expected**
- Task appears in Home Tasks on both devices.
- Task appears in B's Today.
- Task does NOT appear in A's Today.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TASK-03 — Edit title and description

**Preconditions**
- Task exists in Home.

**Steps**
1. Edit title and description.
2. Save.

**Expected**
- Updated title/description visible on both devices without refresh.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TASK-04 — Reassign / unassign

**Preconditions**
- Task assigned to B.

**Steps**
1. Reassign to A.
2. Later unassign.

**Expected**
- Reassign B→A: disappears from B's Today, appears in A's Today.
- Unassign: disappears from all personal Today views; remains in household Tasks.

**Verification**
- Automated coverage: Partial (`today_test.dart` covers Today rendering; realtime changes require device)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TASK-05 — Complete and reopen task

**Preconditions**
- Task assigned to B.

**Steps**
1. B completes the task.
2. A reopens it.

**Expected**
- Completion: task marked done on both devices; disappears from B's Today.
- Reopen: task becomes active again; reappears in B's Today.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TASK-06 — Delete task

**Preconditions**
- Task exists in Home.

**Steps**
1. Delete the task.

**Expected**
- Task disappears from Tasks list and Today on both devices.
- Realtime: other device sees deletion without refresh.
- Historical task events preserved in DB (activity may remain).

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 12 — Task Assignment / Today Behavior

### TODAY-ASSIGN-01 — Assignment appears only for correct member

*(See TASK-02.)*

### TODAY-ASSIGN-02 — Concurrent reassignment

**Preconditions**
- Task assigned to B. Both devices online.

**Steps**
1. A reassigns task to A.
2. Observe B's Today and A's Today.

**Expected**
- B's Today: task disappears.
- A's Today: task appears.
- No duplication.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 13 — Concurrent Task Edits

### CONCURRENT-01 — Last-write-wins on simultaneous edit

**Preconditions**
- A and B both have the task edit screen open simultaneously.

**Steps**
1. A and B both change the task title at nearly the same time.
2. Both save.

**Expected**
- No crash.
- No duplicate rows.
- One title wins; both devices eventually show the same title.
- No conflict-resolution UI required.

**Verification**
- Automated coverage: None
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 14 — Due Dates

### DUE-01 — Due date sections in Today

**Preconditions**
- Tasks assigned to A with varying due dates.

**Steps**
1. Create tasks: one overdue, one due today, one due tomorrow, one with no due date.

**Expected**
- Overdue → Overdue section.
- Due today → Today section.
- Due tomorrow → Upcoming section.
- No due date → Anytime section.

**Verification**
- Automated coverage: Full (`today_test.dart` covers section logic)
- Manual device test: Recommended (local clock behavior)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### DUE-02 — Midnight boundary

**Preconditions**
- Task due today approaching midnight.

**Steps**
1. Observe task in Today section just before midnight.
2. After midnight observe it again.

**Expected**
- After midnight the task moves to Overdue.
- Widget and Today refresh with the new state.

**Verification**
- Automated coverage: None
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### DUE-03 — Remove due date

**Preconditions**
- Task has a due date and is in Today section.

**Steps**
1. Remove the due date.

**Expected**
- Task moves to Anytime.

**Verification**
- Automated coverage: None
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 15 — Daily Recurring Task

### RECUR-DAILY-01 — Completing one occurrence does not affect others

**Preconditions**
- Task "Clean kitchen" with daily recurrence assigned to B.

**Steps**
1. Verify multiple future occurrences visible or exist in DB.
2. Complete today's occurrence.

**Expected**
- Today's occurrence marked complete.
- Tomorrow's occurrence still open and schedulable.
- No single row resets — each is a distinct occurrence.

**History**
- Concrete `task_occurrences` rows with individual `completed_at`.

**Verification**
- Automated coverage: Full (`task_occurrence_test.dart` covers occurrence logic)
- Manual device test: **Required** (verify daily generation in real Supabase)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 16 — Weekly Recurring Task

### RECUR-WEEKLY-01 — Weekly occurrence isolation

**Preconditions**
- Task "Take out trash" weekly on Monday, assigned to A.

**Steps**
1. Complete this week's occurrence.

**Expected**
- Only this week's occurrence is completed.
- Next week's occurrence remains open.

**Verification**
- Automated coverage: Full (occurrence logic tested)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 17 — Recurrence Editing

### RECUR-EDIT-01 — Change recurrence, due time, or assignee

**Preconditions**
- Task "Clean kitchen" daily, assigned to B, has future incomplete occurrences.

**Steps**
1. Change recurrence from daily to weekly.
2. Change due time.
3. Change assignee to A.

**Expected**
- Future incomplete occurrences regenerated/updated accordingly.
- Completed past occurrences unchanged.
- No duplicate occurrences created.

**Verification**
- Automated coverage: Partial (occurrence domain tested; regeneration RPC requires real Supabase)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 18 — Reopen Occurrence

### RECUR-REOPEN-01 — Reopen completed occurrence

**Preconditions**
- A completed daily occurrence of "Clean kitchen".

**Steps**
1. Reopen that occurrence.

**Expected**
- Occurrence becomes incomplete and actionable again.
- Appears in Today for assignee.
- Other future occurrences unaffected.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 19 — Rolling Occurrence Horizon

### RECUR-HORIZON-01 — Future generation is bounded and idempotent

**Preconditions**
- Daily task with completed history.

**Steps**
1. Inspect `task_occurrences` in DB for the task.
2. Trigger occurrence refresh (e.g. re-open app, background run of `refresh_recurring_occurrences`).

**Expected**
- New occurrences generated up to the horizon.
- No duplicate occurrences (unique constraint prevents them).
- Completed occurrences remain.
- No infinite generation.

**Verification**
- Automated coverage: None (DB inspection required)
- Manual device test: Not required
- Backend/external setup: **Required** (DB inspection)

**Status**
- [ ] Pass  — [ ] Fail

---

## 20 — Today

### TODAY-01 — Empty state

**Preconditions**
- User A has no assigned incomplete tasks.

**Steps**
1. Open Today.

**Expected**
- Empty state message shown (e.g. "Nothing assigned to you.").

**Verification**
- Automated coverage: Full (`today_test.dart`)
- Manual device test: Not required
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TODAY-02 — Multiple households sections in Today

*(See MULTI-03.)*

---

### TODAY-03 — Complete task from Today

**Preconditions**
- Task assigned to B appears in B's Today.

**Steps**
1. B completes task from Today.

**Expected**
- Task/occurrence completes.
- Disappears from Today.
- Household Tasks reflects completion on A's device without refresh.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### TODAY-04 — Membership loss during Today view

**Preconditions**
- B's Today has tasks from Home. A removes B from Home.

**Steps**
1. A removes B.
2. B observes Today (or refreshes).

**Expected**
- Home entries disappear from B's Today.
- No crash.
- No inaccessible data shown.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 21 — Shopping

### SHOP-01 — Add item and see realtime on another device

**Preconditions**
- A and B are active members; both have Shopping open.

**Steps**
1. A adds "Milk" with quantity "2 cartons".

**Expected**
- Appears on A's list immediately.
- Appears on B's list without manual refresh.

**Verification**
- Automated coverage: Partial (`shopping_test.dart`)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### SHOP-02 — Complete, reopen, delete, clear completed

**Preconditions**
- Shopping list has several items.

**Steps**
1. Complete one item. Observe other device.
2. Reopen it. Observe.
3. Delete an item.
4. Clear completed.

**Expected**
- All state changes propagate realtime.
- Clear completed removes only completed items.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### SHOP-03 — Shopping does not appear in Today

**Preconditions**
- Shopping list has items.

**Steps**
1. Open Today.

**Expected**
- No shopping items in Today.

**Verification**
- Automated coverage: Full (Today only reads task/occurrence data)
- Manual device test: Not required
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### SHOP-04 — Shopping changes do not trigger remote push

**Preconditions**
- B has Household updates enabled.

**Steps**
1. A adds an item to Shopping.
2. A completes an item.

**Expected**
- B receives NO push notification for shopping actions.

**Verification**
- Automated coverage: None (no shopping trigger in migration `20260825000016`)
- Manual device test: **Required**
- Backend/external setup: Required (push delivery)

**Status**
- [ ] Pass  — [ ] Fail

---

## 22 — Expenses

### EXPENSE-01 — Equal split among three members

**Preconditions**
- A, B, C are active in Home. All three are participants.

**Steps**
1. A pays €60. Participants: A, B, C.

**Expected**
- A: +€40 net (paid €60, owes €20).
- B: -€20.
- C: -€20.

**Verification**
- Automated coverage: Full (`expenses_test.dart` covers `calculateNetBalances`)
- Manual device test: Recommended (UI display)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### EXPENSE-02 — Payer excluded from participants

**Preconditions**
- A, B, C are active in Home.

**Steps**
1. A pays €40 for B and C only (A excluded from split).

**Expected**
- A: +€40 net.
- B: -€20.
- C: -€20.

**Verification**
- Automated coverage: Full
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### EXPENSE-03 — Integer-cent remainder handling

**Preconditions**
- Three equal participants.

**Steps**
1. Create expense of €10 / 3 participants.

**Expected**
- Shares: 333, 333, 334 cents (or similar deterministic allocation totalling exactly €10.00).
- No floating-point errors.
- Shares sum to exactly the expense total.

**Verification**
- Automated coverage: Full (integer math + remainder distribution tested)
- Manual device test: Not required
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### EXPENSE-04 — Delete expense and balance recalculation

**Preconditions**
- Expense exists affecting A and B.

**Steps**
1. Delete the expense.

**Expected**
- Balance resets (or changes) to reflect deletion.
- Expense row removed.
- Historical activity event remains.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### EXPENSE-05 — Member leaves but expenses remain

**Preconditions**
- B participated in an expense and then left Home.

**Steps**
1. Open Expenses in Home.

**Expected**
- Expense still listed.
- B's name shown (or "Deleted member" if account deleted).
- Balance calculation still valid.

**Verification**
- Automated coverage: Partial (soft delete/fallback tested)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 23 — Settlements

### SETTLE-01 — Record full settlement

**Preconditions**
- B owes A €20 (from existing expense).

**Steps**
1. B records a payment: B → A, €20.

**Expected**
- Net balance for B reaches €0 (or changes by +€20).
- Settlement appears in Expenses screen.
- Original expense row unchanged.

**Verification**
- Automated coverage: Full (`expenses_test.dart` covers `calculateNetBalances` with settlements)
- Manual device test: **Required** (UI flow and DB insert via RPC)
- Backend/external setup: Required (migration `20260831000002`)

**Status**
- [ ] Pass  — [ ] Fail

---

### SETTLE-02 — Record partial settlement

**Preconditions**
- B owes A €20.

**Steps**
1. B records payment: B → A, €5.

**Expected**
- Remaining debt: B owes A €15.

**Verification**
- Automated coverage: Full (math logic)
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

### SETTLE-03 — Settlement is never a negative expense

**Preconditions**
- Settlement has been recorded.

**Steps**
1. Inspect `expenses` table in Supabase.

**Expected**
- No negative-amount rows in `expenses` table corresponding to a settlement.
- Settlement exists only in `expense_settlements` table.

**Verification**
- Automated coverage: None (data model inspection)
- Manual device test: Not required
- Backend/external setup: **Required** (DB inspection)

**Status**
- [ ] Pass  — [ ] Fail

---

### SETTLE-04 — Settlement affects only the correct directional balance

**Preconditions**
- A owes B €30. C owes A €10.

**Steps**
1. A records payment to B: A → B, €30.

**Expected**
- A's debt to B: €0.
- C's debt to A: unchanged.

**Verification**
- Automated coverage: Full
- Manual device test: Recommended
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

## 24 — Household Activity

### ACTIVITY-01 — Meaningful events appear in Activity feed

**Preconditions**
- Home has several members and activity.

**Steps**
1. Perform each supported action once: create task, complete task, add shopping, complete shopping, add expense, delete expense, member join (via INVITE-01 scenario).
2. Open Activity screen.

**Expected**
- Each action produces exactly one activity entry.
- Newest events at top.
- Correct actor name displayed (not UUID).
- Correct title snapshot shown.

**Verification**
- Automated coverage: Full (`household_event_test.dart` covers `displayText` for all event types)
- Manual device test: **Required** (trigger chain requires real Supabase)
- Backend/external setup: Required (migrations `20260825000014` + `20260831000003`)

**Status**
- [ ] Pass  — [ ] Fail

---

### ACTIVITY-02 — Membership events in Activity

**Preconditions**
- B joins, then leaves, then is removed (in separate scenarios).

**Steps**
1. B joins Home → observe Activity.
2. B leaves → observe Activity.
3. A removes another member → observe Activity.
4. A transfers ownership to B → observe Activity.

**Expected**
- `member_joined`, `member_left`, `member_removed`, `ownership_transferred` each appear correctly.

**Verification**
- Automated coverage: Full (`household_event_test.dart` covers displayText; trigger requires Supabase)
- Manual device test: **Required**
- Backend/external setup: Required (migration `20260831000003`)

**Status**
- [ ] Pass  — [ ] Fail

---

### ACTIVITY-03 — Deleted member fallback in Activity

**Preconditions**
- B has performed actions. B's account identity is lost (session not recoverable, treating as "deleted" for test).

**Steps**
1. View Activity events that B created.

**Expected**
- B's name shows as `Deleted member` (snapshotted at event time for events created after their profile was removed, or displays snapshotted name for historical events).
- No UUID or email shown.

**Verification**
- Automated coverage: Partial (fallback logic in `HouseholdEvent.fromMap` tested)
- Manual device test: **Required** (requires actual account deletion or profile removal)
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 25 — Statistics

### STATS-01 — Correct period filters

**Preconditions**
- Household has chore completions spanning different date ranges.

**Steps**
1. Switch between Last 7 days / Last 30 days / All time.

**Expected**
- Counts change correctly per period.
- Only task completion events count.
- Create/edit/reopen/shopping/expenses do NOT count.

**Verification**
- Automated coverage: Full (`household_stats_test.dart` covers period math)
- Manual device test: **Required** (real Supabase data)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### STATS-02 — Zero activity does not crash

**Preconditions**
- Household has no completions.

**Steps**
1. Open Statistics.

**Expected**
- Statistics shows zero counts.
- No division-by-zero crash.
- Percentages: 0% or empty gracefully.

**Verification**
- Automated coverage: Full
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### STATS-03 — Former member history remains

**Preconditions**
- B completed tasks before leaving.

**Steps**
1. Open Statistics → All time.

**Expected**
- B's completions appear in history.
- B's name shows (or "Deleted member" if applicable).

**Verification**
- Automated coverage: Partial (fallback tested; real Supabase data required for full check)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 26 — Rotation Suggestions

### ROTATE-01 — No suggestion below threshold

**Preconditions**
- Task has fewer completions than minimum required, or distribution is fair.

**Steps**
1. Open task rotation suggestions for Home.

**Expected**
- No suggestion shown for this task.

**Verification**
- Automated coverage: Full (`task_rotation_suggestion_test.dart`)
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### ROTATE-02 — Suggestion appears when one member has >75% of recent completions

**Preconditions**
- Task "Clean kitchen" — A completed 7 of last 8 occurrences.

**Steps**
1. Open rotation suggestions.

**Expected**
- Suggestion appears proposing to assign next occurrence to B (fewest recent completions).
- Suggestion text is neutral (no "lazy"/"worst").

**Verification**
- Automated coverage: Full (suggestion logic unit-tested)
- Manual device test: **Required** (requires enough real history)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### ROTATE-03 — Former member not suggested

**Preconditions**
- C completed many occurrences then left.

**Steps**
1. View rotation suggestions.

**Expected**
- C is not suggested as target.
- Only active members are candidates.

**Verification**
- Automated coverage: Full
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### ROTATE-04 — Apply suggestion changes task and future occurrences

**Preconditions**
- Suggestion available; propose assigning to B.

**Steps**
1. Tap "Apply".

**Expected**
- Task template assignee changes to B.
- Future incomplete occurrences change to B.
- Completed past occurrences remain unchanged.
- Suggestion dismissed.

**Verification**
- Automated coverage: Partial (suggestion domain; RPC apply requires real Supabase)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### ROTATE-05 — Keep current dismisses suggestion

**Preconditions**
- Suggestion visible.

**Steps**
1. Tap "Keep current".

**Expected**
- Suggestion dismissed from current view.
- Task and occurrences unchanged.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### ROTATE-06 — Stale suggestion (target leaves before Apply)

**Preconditions**
- Suggestion targets B. B leaves before A taps Apply.

**Steps**
1. A taps Apply.

**Expected**
- Server rejects or handles gracefully.
- No crash.
- User sees a friendly error or no-op.

**Verification**
- Automated coverage: None
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 27 — Local Task Reminders

### REMIND-01 — No permission prompt at first launch

**Preconditions**
- Fresh install.

**Steps**
1. Launch app and navigate normally for 30 seconds.

**Expected**
- No notification permission prompt.

**Verification**
- Automated coverage: None (OS permission logic)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-02 — Permission requested when enabling Task reminders

**Preconditions**
- Task reminders setting is disabled.

**Steps**
1. Toggle Task reminders ON in Profile.

**Expected**
- OS permission prompt appears at that moment.
- If denied: setting remains off; friendly explanation shown; no repeated nag.
- If granted: reminders activated.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-03 — Future assigned occurrence is scheduled

**Preconditions**
- Task reminders enabled. Task due in 1 hour assigned to current user.

**Steps**
1. Observe the notification at the scheduled time (or inspect pending notifications via debug).

**Expected**
- Notification fires at due time.
- Title: household name or task title.
- Tap navigates to relevant Tasks screen.

**Verification**
- Automated coverage: Full (`reminder_coordinator_test.dart` covers scheduling logic)
- Manual device test: **Required** (OS scheduling requires real device)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-04 — Reminder cancelled on task completion

**Preconditions**
- Future reminder scheduled for a task.

**Steps**
1. Complete the task/occurrence.

**Expected**
- Pending reminder is cancelled.
- Notification does not fire at due time.

**Verification**
- Automated coverage: Full (`reminder_coordinator_test.dart`)
- Manual device test: **Required** (OS cancellation requires real device)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-05 — Reminder cancelled when unassigned

**Preconditions**
- Task with future reminder assigned to current user.

**Steps**
1. Unassign from current user.

**Expected**
- Reminder cancelled.

**Verification**
- Automated coverage: Full
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-06 — Reminder updated on due-time change

**Preconditions**
- Task scheduled for 3pm has a pending reminder.

**Steps**
1. Change due time to 5pm.

**Expected**
- 3pm notification cancelled.
- 5pm notification scheduled.

**Verification**
- Automated coverage: Full
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-07 — Reminder cancelled on task deletion

**Preconditions**
- Task with pending reminder exists.

**Steps**
1. Delete the task.

**Expected**
- Reminder cancelled.

**Verification**
- Automated coverage: Full
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### REMIND-08 — Recurring tasks use concrete occurrence notifications

**Preconditions**
- Weekly recurring task with reminders enabled.

**Steps**
1. Inspect scheduled notifications in debug or via system notification list.

**Expected**
- Each scheduled occurrence has its own notification.
- No single repeating OS schedule is created for the recurrence pattern.

**Verification**
- Automated coverage: Full (coordinator logic)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 28 — Remote Push Preference

### PUSH-PREF-01 — Household updates disabled by default

**Preconditions**
- Fresh install.

**Steps**
1. Open Profile.

**Expected**
- "Household updates" toggle is OFF.
- No device token registered in `device_push_tokens`.

**Verification**
- Automated coverage: Partial (preference store tested)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### PUSH-PREF-02 — Enable registers device token

**Preconditions**
- Household updates is OFF.

**Steps**
1. Toggle Household updates ON.

**Expected**
- OS permission prompt appears (if not previously granted).
- Push token obtained and registered in `device_push_tokens` for current user.
- Raw token never displayed in UI.

**Verification**
- Automated coverage: Partial (controller logic tested; OS token requires real device)
- Manual device test: **Required**
- Backend/external setup: Required (FCM/APNs configured)

**Status**
- [ ] Pass  — [ ] Fail

---

### PUSH-PREF-03 — Disable unregisters token

**Preconditions**
- Household updates is ON. Token registered.

**Steps**
1. Toggle Household updates OFF.

**Expected**
- Token removed/deactivated in `device_push_tokens`.

**Verification**
- Automated coverage: Partial
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

## 29 — Remote Task Assignment Push

### PUSH-TASK-01 — B receives push when A assigns task

**Preconditions**
- Both users have Household updates enabled.
- FCM/APNs configured.

**Steps**
1. A creates task and assigns it to B.

**Expected**
- B receives notification: Title `New task`, Body `A assigned you "Buy groceries"`.
- No UUID, email, or task description in visible notification.
- A receives NO notification.
- Tap → Home Tasks.

**Verification**
- Automated coverage: Partial (routing tested; delivery requires configured push)
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 30 — Remote Self-Assignment

### PUSH-SELF-01 — A assigns task to A — no remote push

**Preconditions**
- A's device has Household updates enabled.

**Steps**
1. A creates task and assigns it to A.

**Expected**
- A receives NO remote push notification.
- Local due reminder may still apply.

**Verification**
- Automated coverage: Full (trigger condition tested)
- Manual device test: **Required**
- Backend/external setup: Required

**Status**
- [ ] Pass  — [ ] Fail

---

## 31 — Member Joined Push

### PUSH-JOIN-01 — Existing members notified when B joins

**Preconditions**
- A has Household updates enabled.

**Steps**
1. B joins Home via invite.

**Expected**
- A receives: "B joined Home" (or "Someone joined Home").
- B does NOT receive self-join push.
- Tap → Home dashboard.

**Verification**
- Automated coverage: None (push delivery requires infrastructure)
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 32 — Removed Member Push

*(See REMOVE-01 and REMOVE-02 for complete scenario.)*

### PUSH-REMOVE-01 — B receives removal push with safe tap target

**Preconditions**
- B has Household updates enabled.

**Steps**
1. A removes B.
2. B taps the received push.

**Expected**
- Notification: "You were removed from Home".
- Tap → `/homes` (Homes list), NOT `/homes/<id>`.
- Home is no longer listed.

**Verification**
- Automated coverage: Full (routing to `/homes` for `member_removed` tested in `remote_push_notification_service_test.dart`)
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 33 — Ownership Transfer Push

### PUSH-TRANSFER-01 — B receives ownership transfer push

**Preconditions**
- B has Household updates enabled.

**Steps**
1. A transfers ownership to B.
2. B taps push.

**Expected**
- Notification: "You are now the owner of Home".
- Tap → Home dashboard (B still has access).

**Verification**
- Automated coverage: Partial (routing tested; delivery requires infrastructure)
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 34 — Remote Push App States

### PUSH-STATE-01 — Push behavior across app states

**Preconditions**
- Push infrastructure configured.

**Steps**
1. Test push receipt and tap behavior with app in: (a) foreground, (b) background, (c) terminated/cold launch.

**Expected**
- All three states: notification received and tap navigates correctly.
- No crash in any state.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 35 — Stale Push / Changed State

### PUSH-STALE-01 — Tap push for deleted task or inaccessible household

**Preconditions**
- Push notification sent referencing a task that was later deleted, or a household the user no longer belongs to.

**Steps**
1. Tap the push notification.

**Expected**
- App navigates to destination route.
- If task/household not found, "not found" state shown gracefully.
- No raw exception or crash.

**Verification**
- Automated coverage: Partial (household null state handled in `HouseholdDetailScreen`)
- Manual device test: **Required**
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 36 — Push Token Rotation / Multiple Devices

### PUSH-MULTI-01 — Multiple device tokens per user

**Preconditions**
- User A logged into two devices, both with Household updates enabled.

**Steps**
1. B assigns task to A.

**Expected**
- Both of A's devices receive the push notification.

**Verification**
- Automated coverage: None (data model supports multi-token; delivery requires two devices)
- Manual device test: **Required** (if two devices available) / Backend verification
- Backend/external setup: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

## 37 — Android Home-Screen Widget

### WIDGET-01 — Default privacy shows counts only

**Preconditions**
- Widget placed on home screen.
- Widget task details setting: OFF (default).

**Steps**
1. Inspect widget.

**Expected**
- Shows counts like "2 overdue · 3 today".
- No task names or household names visible.

**Verification**
- Automated coverage: Full (`widget_snapshot_test.dart` covers snapshot content)
- Manual device test: **Required** (physical widget rendering)
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### WIDGET-02 — Task names enabled in widget

**Preconditions**
- "Widget task details" enabled in Profile.

**Steps**
1. Inspect widget.

**Expected**
- Task names visible (overdue → today → upcoming priority).

**Verification**
- Automated coverage: Full (snapshot tested)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### WIDGET-03 — Widget updates after completion

**Preconditions**
- Widget shows 1 overdue task.

**Steps**
1. Complete that task inside the app.

**Expected**
- Widget updates to reflect new counts (after Today provider refreshes widget).

**Verification**
- Automated coverage: None (OS widget update mechanism)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### WIDGET-04 — Widget tap opens Today

**Preconditions**
- Widget is placed on home screen.

**Steps**
1. Tap widget.

**Expected**
- App opens to Today screen.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### WIDGET-05 — Widget stable without network

**Preconditions**
- Widget last updated when network was available. Device goes offline.

**Steps**
1. Enable airplane mode.
2. Inspect widget.

**Expected**
- Last snapshot remains shown.
- No crash or blank widget.

**Verification**
- Automated coverage: None
- Manual device test: Recommended
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 38 — Permissions

### PERM-01 — No unnecessary permissions on first launch

**Preconditions**
- Fresh install.

**Steps**
1. Launch app.
2. Navigate through Today, Homes, Shopping for 2 minutes without triggering any specific feature.

**Expected**
- No notification permission prompt.
- No photo/camera permission prompt.
- No location permission prompt.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### PERM-02 — Camera permission not requested

**Steps**
1. Use the app fully (all features).

**Expected**
- Camera permission never requested (QR scanning not implemented in MVP).

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### PERM-03 — Location permission never requested

**Steps**
1. Use the app fully.

**Expected**
- Location permission never requested.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 39 — Network Failures

### NET-01 — Task creation failure is surfaced

**Preconditions**
- Device loses network mid-session.

**Steps**
1. Attempt to create a task with no network.

**Expected**
- Friendly error shown.
- No fake persisted success.
- No raw exception text.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

### NET-02 — Shopping mutation failure surfaced

*(Same expectations as NET-01 for shopping add/edit/complete.)*

**Verification**
- Automated coverage: None
- Manual device test: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

### NET-03 — Expense mutation failure surfaced

*(Same expectations as NET-01 for expense add/delete.)*

**Verification**
- Automated coverage: None
- Manual device test: **Required**

**Status**
- [ ] Pass  — [ ] Fail

---

### NET-04 — Realtime reconnect restores state

**Preconditions**
- Two devices, realtime active.

**Steps**
1. Temporarily cut network on one device for ~30 seconds.
2. Restore network.

**Expected**
- Realtime subscription reconnects.
- Changes made during outage eventually become visible.
- No crash.

**Verification**
- Automated coverage: None
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 40 — Historical Identity Scenario

### HISTORY-01 — Leave, rejoin; history continuous

**Preconditions**
- B has completed 5 chores, participated in 2 expenses, appeared in 10 activity events.

**Steps**
1. B leaves Home.
2. Verify history still visible (stats, activity, expenses show B's past contributions).
3. A creates new invite.
4. B rejoins.
5. Verify B's historical records still attributed correctly.
6. B completes new chores.

**Expected**
- B's historical stats accumulate across both membership periods.
- No identity reset.
- B is not treated as a new unrelated user.

**Verification**
- Automated coverage: None (requires real Supabase data across membership periods)
- Manual device test: **Required**
- Backend/external setup: Not required

**Status**
- [ ] Pass  — [ ] Fail

---

## 41 — Cross-Household Isolation (Security)

### ISOLATE-01 — Actions in Home do not affect Parents

**Preconditions**
- A is owner of Home and member of Parents with separate data.

**Steps**
1. Add task in Home.
2. Add shopping item in Home.
3. Add expense in Home.

**Expected**
- Parents → Tasks, Shopping, Expenses unchanged.
- No data from Home appears in Parents.

**Verification**
- Automated coverage: None (RLS enforced at DB; widget tests mock data)
- Manual device test: **Required**
- Backend/external setup: Not required (RLS)

**Status**
- [ ] Pass  — [ ] Fail

---

### ISOLATE-02 — RLS prevents cross-household data access

**Steps**
1. Inspect DB queries. Verify that reads for one household cannot return rows of another (e.g. using Supabase RLS policies).

**Expected**
- `is_active_household_member(household_id)` correctly gates all household-scoped tables.
- An inactive member cannot read current household content.

**Verification**
- Automated coverage: None (RLS inspection)
- Manual device test: Not required
- Backend/external setup: **Required** (DB inspection)

**Status**
- [ ] Pass  — [ ] Fail

---

## 42 — Golden Two-User Acceptance Flow

### GOLDEN-01 — End-to-end two-user functional acceptance

**Preconditions**
- Two physical devices (or emulators) available.
- Network available.
- All pending migrations applied.
- Push infrastructure configured (mark this sub-step separately if not yet configured).

**Steps**
1. Device A: fresh install, launch → anonymous identity created, no registration.
2. Device B: fresh install, launch → separate anonymous identity, no registration.
3. A: edit display name to "Alice".
4. A: create household "Home".
5. A: create invite code.
6. B: join Home with invite code.
7. A: verify B appears in Members.
8. B: verify Home appears in Homes.
9. A: create recurring daily task "Clean kitchen" assigned to B.
10. B: verify task appears in Home → Tasks and in B's Today (realtime, no refresh).
11. B: complete today's occurrence from Today.
12. A: verify completion visible realtime in Tasks.
13. A: add shopping item "Milk".
14. B: verify item appears realtime.
15. B: complete "Milk".
16. A: verify completion realtime.
17. A: create expense "Groceries" €60, participants A+B.
18. Both: verify balances — A: +€30, B: -€30.
19. B: record settlement B→A €30.
20. Both: verify balance reaches €0.
21. Open Activity: verify relevant events present with correct actor names.
22. Open Statistics: verify B's completions counted.
23. (With enough recurring history) Open rotation suggestions: verify deterministic suggestion appears.
24. A: transfer ownership to B.
25. B: verify B now shown as owner; A as member.
26. A: leave Home.
27. B: verify A gone from Members; A's past history intact.
28. A: rejoin with new invite.
29. Both: verify seamless rejoin, history intact.

**Expected**
- Entire flow works without:
  - mandatory registration
  - manual refresh for realtime features
  - raw exceptions
  - history loss
  - crashes

**Notifications**
- B receives task assignment push (step 9) if push configured.
- A receives "B joined" push (step 6) if push configured.
- B receives ownership push (step 24) if push configured.

**Verification**
- Automated coverage: None (full end-to-end)
- Manual device test: **Required**
- Backend/external setup: **Required** (migrations + optionally push)

**Status**
- [ ] Pass  — [ ] Fail

---

## UI Polish Gate

UI/UX redesign may begin only when all of the following are true:

1. **P0 functional blockers = 0.**
2. **Core P1 blockers = 0.**
3. **Pending database migrations applied** to the target environment:
   - `20260825000017_profile_updates.sql`
   - `20260831000001_fix_generate_invite_code.sql`
   - `20260831000002_create_settlements.sql`
   - `20260831000003_membership_activity_events.sql`
4. **GOLDEN-01 passes manually** on real devices.
5. **Critical realtime cross-device behavior passes** (tasks, shopping, membership changes propagate without refresh).
6. **Profile editing works on device** (display name + avatar add/remove).
7. **Expense + settlement flow passes** on device with real Supabase.
8. **Historical leave/rejoin behavior passes** (identity and data preserved).
9. **No major raw technical exceptions** leak to users during normal product flows.

Remote FCM/APNs delivery may remain an external integration item — its application-level logic is complete and isolated — but this must be explicitly documented in release notes before UI polish begins.

---

### P0 — Security, data-correctness, core-flow blockers

*Based on current repository inspection: no P0 blockers identified.*

All critical security controls (RLS, server-derived membership, no client-supplied identity escalation) are implemented. No known data corruption paths.

> This assessment is based on automated tests and code inspection. Manual device validation is required to confirm.

---

### P1 — Important MVP functionality

*Based on current repository inspection: no P1 blockers remaining in code.*

| Item | Status |
|------|--------|
| Anonymous-first identity | Implemented |
| Profile display name + avatar | Implemented |
| Invite code generation (fixed) | Implemented + migration pending |
| Expense settlements | Implemented + migration pending |
| Membership activity events | Implemented + migration pending |
| member_removed push tap safe destination | Implemented |
| Local reminder reconciliation | Implemented |

---

### External / Manual Verification Required

| Item | Blocker for Golden-01 |
|------|-----------------------|
| Apply 4 pending migrations via `supabase db push` | Yes |
| FCM credentials in Edge Function secrets | Only for push tests |
| APNs credentials in Edge Function secrets | Only for iOS push |
| `google-services.json` in Android project | Only for Android push |
| `avatars` Storage bucket configured with RLS | Yes (for avatar tests) |
| Edge Function `process-notification-outbox` deployed + triggered | Only for push tests |

---

### P2 / Future

| Feature | Notes |
|---------|-------|
| Account deletion | User-facing flow not yet implemented |
| Account recovery (email / Google / Apple) | Preserving same auth UID; not blocking MVP |
| iOS WidgetKit widget | Android widget complete; iOS is P2 |
| Monthly / custom recurrence | Daily + weekly implemented; monthly is P2 |
| Expense/settlement push notifications | Not in MVP push matrix |
| Full offline-first mutation sync | Not required for MVP |
| QR code invite scanning | Camera permission tied to this; P2 |
| Advanced push types | Per-completion notifications etc. |
