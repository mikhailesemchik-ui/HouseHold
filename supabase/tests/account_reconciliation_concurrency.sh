#!/usr/bin/env bash
# Two-session concurrency tests for reconcile_account_deletions (F7B).
# Run against the local, isolated test database only:
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/account_reconciliation_concurrency.sh
# Creates disposable profiles (no Auth users) with real commits and removes
# them. Refuses to run unless the container name contains "hhsqltest". Pause
# the pg_cron job first (cron.alter_job(..., active := false)) so the schedule
# cannot take the fixtures between steps.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }

X() { printf 'f7000000-0000-0000-0000-0000000000%02d' "$1"; }

as_service_sql() { # statement sleep-after (the trusted backend role)
  cat <<SQL
begin;
set local role service_role;
$1;
select pg_sleep($2) \g /dev/null
commit;
SQL
}

cleanup() {
  psql_ -c "delete from profiles where user_id::text like 'f7000000-%'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $1"; exit 1; }

mk() { # index state
  psql_ -c "insert into profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
            values ('$(X "$1")','RC-$1','Real $1','$2',now())" >/dev/null
}
state() { psql_ -c "select account_state from profiles where user_id = '$(X "$1")'"; }
now_s() { date +%s; }

[ "$(psql_ -c "select count(*) from profiles p where account_state='deleting' and not exists (select 1 from auth.users u where u.id = p.user_id)")" = 0 ] \
  || fail "unrelated finalizable accounts exist; refusing to run"

echo "--- test 1: two overlapping reconciliations"
mk 1 deleting; mk 2 deleting; mk 3 deleting
( as_service_sql "select 'first:' || reconcile_account_deletions()" 3 | psql_ > /tmp/rc1_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(now_s)
as_service_sql "select 'second:' || reconcile_account_deletions()" 0 | psql_ > /tmp/rc1_b.out 2>&1 || true
END=$(now_s)
wait $PID
grep -q "^first:3" /tmp/rc1_a.out || fail "the first run did not finalize all three"
grep -q "^second:0" /tmp/rc1_b.out || fail "the overlapping run did not skip the locked accounts"
[ $((END-START)) -le 1 ] || fail "the overlapping run waited instead of skipping ($((END-START))s)"
[ "$(state 1)$(state 2)$(state 3)" = deleteddeleteddeleted ] || fail "not all accounts were finalized"
echo "PASS: the second run skipped the locked rows without waiting; each account was finalized once"

echo "--- test 2: manual finalization racing reconciliation"
mk 4 deleting
( as_service_sql "select 'recon:' || reconcile_account_deletions()" 3 | psql_ > /tmp/rc2_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(now_s)
as_service_sql "select 'fin:' || finalize_account_deletion('$(X 4)')" 0 | psql_ > /tmp/rc2_b.out 2>&1 || true
END=$(now_s)
wait $PID
grep -q "^recon:1" /tmp/rc2_a.out || fail "reconciliation did not finalize the account"
grep -q "^fin:deleted" /tmp/rc2_b.out || fail "the manual finalize did not end in 'deleted'"
[ $((END-START)) -ge 1 ] || fail "the manual finalize did not wait for the row lock"
[ "$(state 4)" = deleted ] || fail "wrong final state"
echo "PASS: finalize waited for reconciliation, then returned 'deleted' idempotently"

echo "--- test 3: a retried begin_account_deletion racing reconciliation"
mk 5 deleting
( as_service_sql "select 'begin:' || begin_account_deletion('$(X 5)')" 3 | psql_ > /tmp/rc3_a.out 2>&1 ) &
PID=$!
sleep 1.2
START=$(now_s)
as_service_sql "select 'recon:' || reconcile_account_deletions()" 0 | psql_ > /tmp/rc3_b.out 2>&1 || true
END=$(now_s)
wait $PID
grep -q "^begin:deleting" /tmp/rc3_a.out || fail "begin did not complete"
grep -q "^recon:0" /tmp/rc3_b.out && [ $((END-START)) -le 1 ] || fail "reconciliation did not skip the account being retried"
[ "$(state 5)" = deleting ] || fail "state changed under the running begin"
as_service_sql "select 'later:' || reconcile_account_deletions()" 0 | psql_ > /tmp/rc3_c.out 2>&1
grep -q "^later:1" /tmp/rc3_c.out && [ "$(state 5)" = deleted ] || fail "the next run did not finish the account"
echo "PASS: the running retry was skipped, the next run finished the account"

echo "--- test 4: begin_account_deletion on an active account racing reconciliation"
mk 6 active
( as_service_sql "select 'begin:' || begin_account_deletion('$(X 6)')" 3 | psql_ > /tmp/rc4_a.out 2>&1 ) &
PID=$!
sleep 1.2
as_service_sql "select 'recon:' || reconcile_account_deletions()" 0 | psql_ > /tmp/rc4_b.out 2>&1 || true
wait $PID
grep -q "^begin:deleting" /tmp/rc4_a.out || fail "begin did not complete"
grep -q "^recon:0" /tmp/rc4_b.out || fail "reconciliation touched an account that was still active when it started"
[ "$(state 6)" = deleting ] || fail "state after the race is not 'deleting'"
as_service_sql "select 'later:' || reconcile_account_deletions()" 0 | psql_ > /tmp/rc4_c.out 2>&1
grep -q "^later:1" /tmp/rc4_c.out && [ "$(state 6)" = deleted ] || fail "the next run did not finish the account"
echo "PASS: an active account was never finalized early; the next run closed it once it was deleting"
