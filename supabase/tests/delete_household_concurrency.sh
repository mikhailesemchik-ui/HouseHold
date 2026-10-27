#!/usr/bin/env bash
# Two-session concurrency tests for delete_household (F7A).
#
# Usage (local test database only):
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/delete_household_concurrency.sh
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

A='f6300000-0000-0000-0000-00000000000a'
B='f6300000-0000-0000-0000-00000000000b'
D='f6300000-0000-0000-0000-00000000000d'
claims() { echo "{\"sub\":\"$1\",\"role\":\"authenticated\"}"; }

# Runs one statement as a user inside a transaction that stays open for $3 s.
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
  for H in $(psql_ -c "select id from households where name like 'DELCONC %'"); do
    OWNER=$(psql_ -c "select user_id from household_members where household_id = '$H' and role = 'owner' and status = 'active' limit 1")
    if [ -n "$OWNER" ]; then
      as_user_sql "$OWNER" "select delete_household('$H')" 0 | psql_ >/dev/null 2>&1 || true
    fi
  done
  psql_ <<SQL >/dev/null 2>&1 || true
delete from households where name like 'DELCONC %';
delete from profiles where user_id in ('$A','$B','$D');
delete from auth.users where id in ('$A','$B','$D');
SQL
}
trap cleanup EXIT

psql_ <<SQL >/dev/null
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','dc1@test.local','authenticated','authenticated',now(),now(),true),
 ('$B','dc2@test.local','authenticated','authenticated',now(),now(),true),
 ('$D','dc3@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values ('$A','DCNC-1','Dc1'),('$B','DCNC-2','Dc2'),('$D','DCNC-3','Dc3');
SQL

new_household() { # name -> prints household id; B is an active member
  as_user_sql "$A" "select create_household('$1')" 0 | psql_ >/dev/null
  local h
  h=$(psql_ -c "select id from households where name = '$1'")
  psql_ <<SQL >/dev/null
insert into household_members (household_id,user_id,role,status) values ('$h','$B','member','active');
insert into household_membership_periods (household_id,user_id) values ('$h','$B');
SQL
  echo "$h"
}

left_rows() { # household id
  psql_ -c "select (select count(*) from households where id = '$1') + (select count(*) from expenses where household_id = '$1') + (select count(*) from household_members where household_id = '$1') + (select count(*) from household_invites where household_id = '$1')"
}

fail() { echo "FAIL: $1"; exit 1; }

echo "--- test 1: two concurrent deletions"
H=$(new_household 'DELCONC 1')
( as_user_sql "$A" "select 'deleted:' || delete_household('$H')" 3 | psql_ > /tmp/dc1_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A" "select delete_household('$H')" 0 | psql_ > /tmp/dc1_b.out 2>&1 || true
wait $PID
OK=$(grep -c "^deleted" /tmp/dc1_a.out || true)
DENIED=$(grep -c "Only the household owner" /tmp/dc1_b.out || true)
LEFT=$(left_rows "$H")
echo "first_ok=$OK second_denied=$DENIED left=$LEFT"
[ "$OK" = 1 ] && [ "$DENIED" = 1 ] && [ "$LEFT" = 0 ] || fail "concurrent deletions did not resolve to one deletion"
echo "PASS: one deletion succeeded, the other found nothing to delete"

echo "--- test 2a: deletion holds the lock while an expense is created"
H=$(new_household 'DELCONC 2')
( as_user_sql "$A" "select 'deleted:' || delete_household('$H')" 3 | psql_ > /tmp/dc2_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A" "select create_equal_split_expense('$H','Race',1000,'EUR','$A',array['$A']::uuid[])" 0 | psql_ > /tmp/dc2_b.out 2>&1 || true
wait $PID
LEFT=$(left_rows "$H")
ORPHANS=$(psql_ -c "select count(*) from expenses where household_id = '$H'")
echo "left=$LEFT orphan_expenses=$ORPHANS"
[ "$LEFT" = 0 ] && [ "$ORPHANS" = 0 ] && grep -q "ERROR" /tmp/dc2_b.out || fail "an expense survived or was accepted during deletion"
echo "PASS: the concurrent expense was refused and no orphan remains"

echo "--- test 2b: an expense insert is in flight when the deletion starts"
H=$(new_household 'DELCONC 3')
( as_user_sql "$A" "select create_equal_split_expense('$H','Race',1000,'EUR','$A',array['$A']::uuid[])" 3 | psql_ > /tmp/dc3_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A" "select delete_household('$H')" 0 | psql_ > /tmp/dc3_b.out 2>&1 || true
wait $PID
LEFT=$(left_rows "$H")
ARCH=$(psql_ -c "select count(*) from financial_archive where household_id = '$H'")
echo "left=$LEFT archive=$ARCH"
[ "$LEFT" = 0 ] && [ "$ARCH" = 0 ] || fail "the in-flight expense was left behind"
echo "PASS: the deletion waited for the expense and removed it too"

echo "--- test 3: deletion against an invitation join"
H=$(new_household 'DELCONC 4')
CODE=$(as_user_sql "$A" "select (create_household_invite('$H')).code" 0 | psql_ | grep -E '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | head -1)
( as_user_sql "$A" "select 'deleted:' || delete_household('$H')" 3 | psql_ > /tmp/dc4_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$D" "select join_household_by_invite('$CODE')" 0 | psql_ > /tmp/dc4_b.out 2>&1 || true
wait $PID
LEFT=$(left_rows "$H")
JOINED=$(psql_ -c "select count(*) from household_members where user_id = '$D'")
echo "left=$LEFT outsider_memberships=$JOINED"
[ "$LEFT" = 0 ] && [ "$JOINED" = 0 ] || fail "a join slipped past the deletion"
echo "PASS: the join was refused and no membership remains"

echo "--- test 4: deletion against an ownership transfer"
H=$(new_household 'DELCONC 5')
( as_user_sql "$A" "select transfer_household_ownership('$H','$B')" 3 | psql_ > /tmp/dc5_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_user_sql "$A" "select delete_household('$H')" 0 | psql_ > /tmp/dc5_b.out 2>&1 || true
wait $PID
EXISTS=$(psql_ -c "select count(*) from households where id = '$H'")
NEWOWNER=$(psql_ -c "select user_id from household_members where household_id = '$H' and role = 'owner' and status = 'active'")
echo "household_exists=$EXISTS owner=$NEWOWNER"
[ "$EXISTS" = 1 ] && [ "$NEWOWNER" = "$B" ] && grep -q "Only the household owner" /tmp/dc5_b.out \
  || fail "the former owner was able to delete after transferring ownership"
echo "PASS: the delete re-checked ownership after the lock and was refused"
