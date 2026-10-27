#!/usr/bin/env bash
# Two-session concurrency tests for begin_account_deletion (F7B).
#
# Usage (local test database only):
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/account_deletion_concurrency.sh
#
# Opens real parallel psql sessions against committed disposable data, then
# removes it. Refuses to run unless the container name contains "hhsqltest".
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac

psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }

O='f6400000-0000-0000-0000-00000000000a'
A='f6400000-0000-0000-0000-00000000000b'
A2='f6400000-0000-0000-0000-00000000000c'
A3='f6400000-0000-0000-0000-00000000000d'
claims() { echo "{\"sub\":\"$1\",\"role\":\"authenticated\"}"; }

as_user_sql() { # user statement sleep-after
  cat <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims "$1")', true) \g /dev/null
$2;
select pg_sleep($3) \g /dev/null
commit;
SQL
}

cleanup() {
  for H in $(psql_ -c "select id from households where name like 'ACCCONC %'"); do
    as_user_sql "$(psql_ -c "select user_id from household_members where household_id = '$H' and role = 'owner' and status = 'active' limit 1")" \
      "select delete_household('$H')" 0 | psql_ >/dev/null 2>&1 || true
  done
  psql_ <<SQL >/dev/null 2>&1 || true
delete from households where name like 'ACCCONC %';
delete from household_members where user_id in ('$O','$A','$A2','$A3');
delete from household_membership_periods where user_id in ('$O','$A','$A2','$A3');
delete from device_push_tokens where user_id in ('$O','$A','$A2','$A3');
delete from notification_outbox where recipient_user_id in ('$O','$A','$A2','$A3');
delete from financial_operations where actor_id in ('$O','$A','$A2','$A3');
delete from profiles where user_id in ('$O','$A','$A2','$A3');
delete from auth.users where id in ('$O','$A','$A2','$A3');
SQL
}
trap cleanup EXIT

psql_ <<SQL >/dev/null
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$O','ac1@test.local','authenticated','authenticated',now(),now(),true),
 ('$A','ac2@test.local','authenticated','authenticated',now(),now(),true),
 ('$A2','ac3@test.local','authenticated','authenticated',now(),now(),true),
 ('$A3','ac4@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values
 ('$O','ACNC-1','Ac1'),('$A','ACNC-2','Ac2'),('$A2','ACNC-3','Ac3'),('$A3','ACNC-4','Ac4');
SQL

new_household() { # name member... -> prints household id; members are active
  as_user_sql "$O" "select create_household('$1')" 0 | psql_ >/dev/null
  local h
  h=$(psql_ -c "select id from households where name = '$1'")
  shift
  for m in "$@"; do
    psql_ <<SQL >/dev/null
insert into household_members (household_id,user_id,role,status) values ('$h','$m','member','active');
insert into household_membership_periods (household_id,user_id) values ('$h','$m');
SQL
  done
  echo "$h"
}

fail() { echo "FAIL: $1"; exit 1; }

echo "--- test 1: two concurrent deletion requests for the same account"
H=$(new_household 'ACCCONC 1' "$A")
( as_user_sql "$A" "select 'first:' || begin_account_deletion()" 3 | psql_ > /tmp/ac1_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A" "select 'second:' || begin_account_deletion()" 0 | psql_ > /tmp/ac1_b.out 2>&1 || true
wait $PID
grep -q "^first:deleting" /tmp/ac1_a.out && grep -q "^second:deleting" /tmp/ac1_b.out || fail "the requests did not both finish cleanly"
ROWS=$(psql_ -c "select count(*) from household_members where user_id = '$A' and status = 'active'")
STATE=$(psql_ -c "select account_state from profiles where user_id = '$A'")
[ "$ROWS" = 0 ] && [ "$STATE" = deleting ] || fail "inconsistent state after concurrent requests"
echo "PASS: both requests finished, one cleanup, state=deleting, no active memberships"

echo "--- test 2: an invitation join racing the deletion"
H=$(new_household 'ACCCONC 2' "$A2")
CODE=$(as_user_sql "$O" "select (create_household_invite('$H')).code" 0 | psql_ | grep -E '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | head -1)
H2=$(new_household 'ACCCONC 2b')
CODE2=$(as_user_sql "$O" "select (create_household_invite('$H2')).code" 0 | psql_ | grep -E '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | head -1)
( as_user_sql "$A2" "select 'deleted:' || begin_account_deletion()" 3 | psql_ > /tmp/ac2_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A2" "select join_household_by_invite('$CODE2')" 0 | psql_ > /tmp/ac2_b.out 2>&1 || true
wait $PID
JOINED=$(psql_ -c "select count(*) from household_members where user_id = '$A2' and household_id = '$H2'")
grep -q "^deleted:deleting" /tmp/ac2_a.out && [ "$JOINED" = 0 ] && grep -q "not active" /tmp/ac2_b.out \
  || fail "a join slipped past the deletion"
echo "PASS: the join waited, then was refused; the deleting account has no new membership"

echo "--- test 3: ownership transfer to the account that is being deleted"
H=$(new_household 'ACCCONC 3' "$A3")
( as_user_sql "$O" "select transfer_household_ownership('$H','$A3')" 3 | psql_ > /tmp/ac3_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A3" "select begin_account_deletion()" 0 | psql_ > /tmp/ac3_b.out 2>&1 || true
wait $PID
STATE=$(psql_ -c "select account_state from profiles where user_id = '$A3'")
ROLE=$(psql_ -c "select role || ':' || status from household_members where household_id = '$H' and user_id = '$A3'")
echo "state=$STATE membership=$ROLE"
[ "$STATE" = active ] && [ "$ROLE" = owner:active ] && grep -q "Transfer ownership" /tmp/ac3_b.out \
  || fail "the account was deleted while it had just become an owner"
echo "PASS: the deletion waited for the transfer, saw the new ownership and refused"

echo "--- test 4: an expense in flight while the account is deleted"
# The expense row references the payer's profile (foreign key), which takes a
# FOR KEY SHARE lock on that profile row until the expense commits.
# begin_account_deletion() locks the same row FOR UPDATE, so it must WAIT for
# the expense and then scrub it. This asserts exactly that: the deletion is
# delayed, and the name is already scrubbed before finalization, i.e. without
# relying on finalize_account_deletion()'s second scrub pass.
H=$(new_household 'ACCCONC 4' "$A")
psql_ -c "update profiles set account_state = 'active', display_name = 'Ac2' where user_id = '$A'" >/dev/null
( as_user_sql "$A" "select create_equal_split_expense('$H','Race',1000,'EUR','$A',array['$A']::uuid[])" 3 | psql_ > /tmp/ac4_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(date +%s)
as_user_sql "$A" "select 'deleted:' || begin_account_deletion()" 0 | psql_ > /tmp/ac4_b.out 2>&1 || true
END=$(date +%s)
wait $PID
grep -q "^deleted:deleting" /tmp/ac4_b.out || fail "the deletion did not complete"
[ $((END-START)) -ge 1 ] || fail "the deletion did not wait for the in-flight expense (waited $((END-START))s)"
BEFORE=$(psql_ -c "select paid_by_display_name from expenses where household_id = '$H' and title = 'Race'")
[ "$BEFORE" = "Deleted member" ] || fail "the in-flight expense kept the personal name before finalization ('$BEFORE')"
psql_ -c "delete from auth.users where id = '$A'" >/dev/null
psql_ -c "select finalize_account_deletion('$A')" >/dev/null
AFTER=$(psql_ -c "select paid_by_display_name from expenses where household_id = '$H' and title = 'Race'")
STATE=$(psql_ -c "select account_state from profiles where user_id = '$A'")
echo "waited=$((END-START))s before_finalize='$BEFORE' after_finalize='$AFTER' state=$STATE"
[ "$AFTER" = "Deleted member" ] && [ "$STATE" = deleted ] || fail "the account was not finalized cleanly"
echo "PASS: the deletion waited on the profile row lock and scrubbed the in-flight expense itself"
