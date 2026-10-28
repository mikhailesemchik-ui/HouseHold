#!/usr/bin/env bash
# Real concurrent-session tests for the deletion-code attempt limiter.
# Run against the local, isolated test database only:
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/deletion_code_attempts_concurrency.sh
# Creates disposable users and limiter rows with real commits and removes them.
# Refuses to run unless the container name contains "hhsqltest".
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

A='fa100000-0000-0000-0000-00000000000a'
B='fa100000-0000-0000-0000-00000000000b'
C='fa100000-0000-0000-0000-00000000000c'
D='fa100000-0000-0000-0000-00000000000d'
TMP=$(mktemp -d)

cleanup() {
  psql_ <<SQL >/dev/null 2>&1 || true
delete from auth.users where id in ('$A','$B','$C','$D');
SQL
  rm -rf "$TMP"
}
trap cleanup EXIT

psql_ >/dev/null <<SQL
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','dcc1@test.local','authenticated','authenticated',now(),now(),false),
 ('$B','dcc2@test.local','authenticated','authenticated',now(),now(),false),
 ('$C','dcc3@test.local','authenticated','authenticated',now(),now(),false),
 ('$D','dcc4@test.local','authenticated','authenticated',now(),now(),false);
SQL

# One real session reserving one attempt as the service role; prints t or f.
reserve_session() { # user outfile
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -At -q <<SQL > "$2" 2>&1
set role service_role;
select allowed from reserve_deletion_code_attempt('$1');
SQL
}
count_of() { psql_ -c "select coalesce((select attempt_count from deletion_code_attempts where user_id = '$1'), 0)"; }
allowed_in() { cat "$TMP"/"$1"* 2>/dev/null | grep -c '^t$' || true; }
refused_in() { cat "$TMP"/"$1"* 2>/dev/null | grep -c '^f$' || true; }

echo "--- 12 simultaneous sessions for one user"
PIDS=()
for i in $(seq 1 12); do reserve_session "$A" "$TMP/a$i" & PIDS+=($!); done
wait "${PIDS[@]}"
[ "$(allowed_in a)" = 5 ] && [ "$(refused_in a)" = 7 ] || fail "expected 5 allowed and 7 refused, got $(allowed_in a)/$(refused_in a)"
[ "$(count_of "$A")" = 5 ] || fail "the stored count is $(count_of "$A")"
pass "12 simultaneous submissions for one user: exactly 5 allowed, 7 refused, stored count 5"

echo "--- simultaneous sessions for several users are limited independently"
PIDS=()
for u in b c d; do
  for i in $(seq 1 8); do reserve_session "$(eval echo \$"$(echo $u | tr a-z A-Z)")" "$TMP/$u$i" & PIDS+=($!); done
done
wait "${PIDS[@]}"
for u in b c d; do
  [ "$(allowed_in $u)" = 5 ] && [ "$(refused_in $u)" = 3 ] || fail "user $u: $(allowed_in $u) allowed / $(refused_in $u) refused"
done
[ "$(count_of "$A")" = 5 ] || fail "another user's traffic changed user A"
pass "3 users x 8 simultaneous submissions: each got exactly 5 allowed and 3 refused; user A untouched"

echo "--- an expired window reopens exactly once under a race"
psql_ -c "update deletion_code_attempts set window_started_at = now() - interval '20 minutes' where user_id = '$A'" >/dev/null
rm -f "$TMP"/a*
PIDS=()
for i in $(seq 1 10); do reserve_session "$A" "$TMP/a$i" & PIDS+=($!); done
wait "${PIDS[@]}"
[ "$(allowed_in a)" = 5 ] && [ "$(refused_in a)" = 5 ] || fail "after expiry: $(allowed_in a) allowed / $(refused_in a) refused"
[ "$(count_of "$A")" = 5 ] || fail "the stored count after the reopening race is $(count_of "$A")"
pass "10 simultaneous submissions on an expired window: the window reopened once, exactly 5 allowed"

echo "--- a refused burst leaves the stored state alone"
BEFORE=$(psql_ -c "select window_started_at::text || '/' || attempt_count from deletion_code_attempts where user_id = '$A'")
PIDS=()
for i in $(seq 1 6); do reserve_session "$A" "$TMP/x$i" & PIDS+=($!); done
wait "${PIDS[@]}"
AFTER=$(psql_ -c "select window_started_at::text || '/' || attempt_count from deletion_code_attempts where user_id = '$A'")
[ "$(refused_in x)" = 6 ] && [ "$BEFORE" = "$AFTER" ] || fail "a refused burst changed the row ($BEFORE -> $AFTER)"
pass "6 refused simultaneous submissions did not change the count or the window"
