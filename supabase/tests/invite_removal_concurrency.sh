#!/usr/bin/env bash
# Two-session concurrency test for invite joins racing a member removal (F8).
#
# Usage (local test database only):
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/invite_removal_concurrency.sh
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

A='f6200000-0000-0000-0000-00000000000a'
B='f6200000-0000-0000-0000-00000000000b'
D1='f6200000-0000-0000-0000-00000000000d'
D2='f6200000-0000-0000-0000-00000000000e'
claims() { echo "{\"sub\":\"$1\",\"role\":\"authenticated\"}"; }

cleanup() {
  psql_ <<SQL >/dev/null
begin;
delete from notification_outbox where household_id in (select id from households where name = 'INVITE CONC');
delete from household_invites where household_id in (select id from households where name = 'INVITE CONC');
delete from household_events where household_id in (select id from households where name = 'INVITE CONC');
delete from household_membership_periods where household_id in (select id from households where name = 'INVITE CONC');
delete from household_members where household_id in (select id from households where name = 'INVITE CONC');
delete from households where name = 'INVITE CONC';
delete from profiles where user_id in ('$A','$B','$D1','$D2');
delete from auth.users where id in ('$A','$B','$D1','$D2');
commit;
SQL
}
trap cleanup EXIT

psql_ <<SQL >/dev/null
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','ic1@test.local','authenticated','authenticated',now(),now(),true),
 ('$B','ic2@test.local','authenticated','authenticated',now(),now(),true),
 ('$D1','ic3@test.local','authenticated','authenticated',now(),now(),true),
 ('$D2','ic4@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values
 ('$A','ICNC-1','Ic1'),('$B','ICNC-2','Ic2'),('$D1','ICNC-3','Ic3'),('$D2','ICNC-4','Ic4');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims $A)', true);
select create_household('INVITE CONC');
commit;
SQL
H=$(psql_ -c "select id from households where name = 'INVITE CONC'")

new_code() {
  psql_ <<SQL | grep -E '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | head -1
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims $A)', true) \g /dev/null
select (create_household_invite('$H')).code;
commit;
SQL
}

join_sql() { # user code sleep-after
  cat <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims "$1")', true) \g /dev/null
select 'joined:' || (join_household_by_invite('$2')).id;
select pg_sleep($3) \g /dev/null
commit;
SQL
}

remove_sql() { # sleep-after
  cat <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims $A)', true) \g /dev/null
select remove_household_member('$H', '$B') \g /dev/null
select pg_sleep($1) \g /dev/null
select 'removed';
commit;
SQL
}

add_member_b() {
  psql_ <<SQL >/dev/null
insert into household_members (household_id,user_id,role,status) values ('$H','$B','member','active')
 on conflict (household_id,user_id) do update set status = 'active', left_at = null;
insert into household_membership_periods (household_id,user_id) values ('$H','$B') on conflict do nothing;
SQL
}

echo "--- test 1: a join that already holds the invite lock finishes first; removal waits, no deadlock"
add_member_b
C1=$(new_code)
( join_sql "$D1" "$C1" 3 | psql_ > /tmp/inv_j1.out 2>&1 ) &
PJ=$!
sleep 1.2
START=$(date +%s)
remove_sql 0 | psql_ > /tmp/inv_r1.out 2>&1
END=$(date +%s)
wait $PJ
J=$(grep -c "^joined:$H" /tmp/inv_j1.out || true)
R=$(grep -c '^removed' /tmp/inv_r1.out || true)
REVOKED=$(psql_ -c "select count(*) from household_invites where code = '$C1' and revoked_at is not null")
DST=$(psql_ -c "select status from household_members where household_id = '$H' and user_id = '$D1'")
BST=$(psql_ -c "select status from household_members where household_id = '$H' and user_id = '$B'")
echo "joined=$J removed=$R waited=$((END-START))s revoked=$REVOKED d1=$DST b=$BST"
[ "$J" = 1 ] && [ "$R" = 1 ] && [ "$REVOKED" = 1 ] && [ "$DST" = active ] && [ "$BST" = left ] && [ $((END-START)) -ge 1 ] \
  || { echo "FAIL: join/removal did not serialize cleanly"; cat /tmp/inv_j1.out /tmp/inv_r1.out; exit 1; }
echo "PASS: join completed, removal waited and revoked the code, no deadlock"

echo "--- test 2: removal holds its transaction open; a join with the same code must be refused afterwards"
add_member_b
C2=$(new_code)
( remove_sql 3 | psql_ > /tmp/inv_r2.out 2>&1 ) &
PR=$!
sleep 1.2
START=$(date +%s)
join_sql "$D2" "$C2" 0 | psql_ > /tmp/inv_j2.out 2>&1 || true
END=$(date +%s)
wait $PR
J=$(grep -c "^joined:" /tmp/inv_j2.out || true)
REJECT=$(grep -c "invalid, expired, or revoked" /tmp/inv_j2.out || true)
D2ST=$(psql_ -c "select count(*) from household_members where household_id = '$H' and user_id = '$D2'")
echo "joined=$J rejected=$REJECT waited=$((END-START))s d2_rows=$D2ST"
[ "$J" = 0 ] && [ "$REJECT" -ge 1 ] && [ "$D2ST" = 0 ] && [ $((END-START)) -ge 1 ] \
  || { echo "FAIL: a join slipped past a concurrent removal"; cat /tmp/inv_j2.out; exit 1; }
echo "PASS: join waited for the removal and was refused with the revoked code"
