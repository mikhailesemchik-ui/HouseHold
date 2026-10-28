#!/usr/bin/env bash
# Real concurrent-session tests for push token ownership and outbox claiming.
# Run against the local, isolated test database only:
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/push_token_ownership_concurrency.sh
# Creates disposable users and rows with real commits and removes them. The
# outbox claim tests ROLL BACK their claims, so existing rows are never changed.
# Refuses to run unless the container name contains "hhsqltest".
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }

A='f9000000-0000-0000-0000-00000000000a'
B='f9000000-0000-0000-0000-00000000000b'
C='f9000000-0000-0000-0000-00000000000c'
D='f9000000-0000-0000-0000-00000000000d'
T1=$(printf 'conctoken1%.0sx' {1..4} | cut -c1-40)
T2=$(printf 'conctoken2%.0sx' {1..4} | cut -c1-40)
T3=$(printf 'conctoken3%.0sx' {1..4} | cut -c1-40)

claims() { echo "{\"sub\":\"$1\",\"role\":\"authenticated\"}"; }
as_user_sql() { # user statement sleep-after [end: commit|rollback]
  cat <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims "$1")', true) \g /dev/null
$2;
select pg_sleep($3) \g /dev/null
${4:-commit};
SQL
}
as_service_sql() { # statement sleep-after [end]
  cat <<SQL
begin;
set local role service_role;
$1;
select pg_sleep($2) \g /dev/null
${3:-commit};
SQL
}
fail() { echo "FAIL: $1"; exit 1; }
now_s() { date +%s; }

cleanup() {
  psql_ <<SQL >/dev/null 2>&1 || true
delete from notification_outbox where type = 'zz_conc';
delete from device_push_tokens where user_id in ('$A','$B','$C','$D');
delete from profiles where user_id in ('$A','$B','$C','$D');
delete from auth.users where id in ('$A','$B','$C','$D');
SQL
}
trap cleanup EXIT

psql_ >/dev/null <<SQL
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','pc1@test.local','authenticated','authenticated',now(),now(),true),
 ('$B','pc2@test.local','authenticated','authenticated',now(),now(),true),
 ('$C','pc3@test.local','authenticated','authenticated',now(),now(),true),
 ('$D','pc4@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values
 ('$A','PCON-1','Pc1'),('$B','PCON-2','Pc2'),('$C','PCON-3','Pc3'),('$D','PCON-4','Pc4');
SQL

owners() { psql_ -c "select coalesce(string_agg(right(user_id::text,1), ',' order by user_id), '-') from device_push_tokens where token = '$1'"; }

echo "--- test 1: two users claim the same token at once"
( as_user_sql "$A" "select register_device_push_token('$T1','android')" 3 | psql_ > /tmp/pc1_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(now_s)
as_user_sql "$B" "select register_device_push_token('$T1','android')" 0 | psql_ > /tmp/pc1_b.out 2>&1 || true
END=$(now_s)
wait $PID
grep -qi "error" /tmp/pc1_a.out /tmp/pc1_b.out && fail "a claim raised an error: $(cat /tmp/pc1_a.out /tmp/pc1_b.out)"
[ "$(owners "$T1")" = b ] || fail "expected exactly one owner (b), got $(owners "$T1")"
[ $((END-START)) -ge 1 ] || fail "the second claim did not wait for the first"
echo "PASS: the second claim waited, then took over; exactly one owner remains, no error, no duplicate"

echo "--- test 2: many parallel claims of one token by four users"
for i in 1 2; do
  for U in "$A" "$B" "$C" "$D"; do
    ( as_user_sql "$U" "select register_device_push_token('$T2','ios')" 0 | psql_ > /tmp/pc2_${U: -1}_$i.out 2>&1 ) &
  done
done
wait
grep -qi "error" /tmp/pc2_*.out && fail "a parallel claim raised an error: $(cat /tmp/pc2_*.out | head -3)"
[ "$(psql_ -c "select count(*) from device_push_tokens where token = '$T2'")" = 1 ] || fail "not exactly one row for the token"
echo "PASS: eight concurrent claims ended with exactly one owner ($(owners "$T2")) and no error"

echo "--- test 3: one user, two devices, registered concurrently"
( as_user_sql "$C" "select register_device_push_token('$T1','android')" 2 | psql_ > /tmp/pc3_a.out 2>&1 ) &
PID=$!
sleep 0.5
as_user_sql "$C" "select register_device_push_token('$T3','ios')" 0 | psql_ > /tmp/pc3_b.out 2>&1 || true
wait $PID
[ "$(psql_ -c "select count(*) from device_push_tokens where user_id = '$C' and token in ('$T1','$T3')")" = 2 ] \
  || fail "one device's registration removed the other's"
echo "PASS: two different tokens of one user are both kept"

echo "--- test 4: registering while the account is being deleted"
psql_ -c "delete from device_push_tokens where user_id = '$D'" >/dev/null
( as_user_sql "$D" "select register_device_push_token('$T3','android')" 3 | psql_ > /tmp/pc4_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(now_s)
as_service_sql "select begin_account_deletion('$D')" 0 | psql_ > /tmp/pc4_b.out 2>&1 || true
END=$(now_s)
wait $PID
grep -q "^deleting" /tmp/pc4_b.out || fail "the deletion did not complete: $(cat /tmp/pc4_b.out)"
[ $((END-START)) -ge 1 ] || fail "the deletion did not wait for the registration"
[ "$(psql_ -c "select count(*) from device_push_tokens where user_id = '$D'")" = 0 ] || fail "a token survived the deletion"
echo "PASS: the deletion waited for the registration and then removed it; no token is left for a deleting account"

echo "--- test 5: concurrent outbox claims never overlap"
psql_ >/dev/null <<SQL
insert into notification_outbox (recipient_user_id, type, title, body, created_at)
select '$A', 'zz_conc', 'x', 'x', now() + (g || ' seconds')::interval from generate_series(1,6) g;
SQL
( as_service_sql "select string_agg(id::text, ',' order by id) from claim_notification_outbox(3)" 3 rollback | psql_ > /tmp/pc5_a.out 2>&1 ) &
PID=$!
sleep 1
as_service_sql "select string_agg(id::text, ',' order by id) from claim_notification_outbox(3)" 0 rollback | psql_ > /tmp/pc5_b.out 2>&1 || true
wait $PID
IDS_A=$(grep -E '^[0-9a-f-]{36}' /tmp/pc5_a.out | tr ',' '\n' | sort -u)
IDS_B=$(grep -E '^[0-9a-f-]{36}' /tmp/pc5_b.out | tr ',' '\n' | sort -u)
[ -n "$IDS_A" ] || fail "the first worker claimed nothing"
OVERLAP=$(comm -12 <(echo "$IDS_A") <(echo "$IDS_B") | grep -c . || true)
[ "$OVERLAP" = 0 ] || fail "two workers claimed the same row ($OVERLAP)"
# Claims rolled back: nothing was changed for real.
[ "$(psql_ -c "select count(*) from notification_outbox where claimed_at is not null or attempt_count > 0")" = 0 ] \
  || fail "rolled-back claims left changes behind"
echo "PASS: the second worker skipped the first worker's locked rows (A: $(echo "$IDS_A" | grep -c .) rows, B: $(echo "$IDS_B" | grep -c .) rows, overlap 0); nothing persisted"
