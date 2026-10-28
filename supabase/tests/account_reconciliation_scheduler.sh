#!/usr/bin/env bash
# Real pg_cron integration test for account reconciliation (F7B). Nothing calls
# reconcile_account_deletions() by hand: the scheduler must do it.
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/account_reconciliation_scheduler.sh
# Needs pg_cron installed and migration 20261107000002 applied. Isolated test
# database only (container name must contain "hhsqltest"). It pauses the
# production job for the duration of the test (so only the test jobs can act on
# the fixtures), restores it, and removes every test job and fixture.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
fail() { echo "FAIL: $1"; exit 1; }

JOB=account-deletion-reconcile
U1='f8000000-0000-0000-0000-000000000001'
U2='f8000000-0000-0000-0000-000000000002'
H='f8000000-0000-0000-0000-0000000000a1'

PAUSED=0
cleanup() {
  psql_ <<SQL >/dev/null 2>&1 || true
select cron.unschedule(jobname) from cron.job where jobname like 'account-deletion-reconcile-test%';
drop trigger if exists zz_fail_u2 on public.profiles;
drop function if exists public.zz_fail_u2();
drop table if exists public.zz_cron_probe;
delete from public.expenses where household_id = '$H';
delete from public.households where id = '$H';
delete from public.profiles where user_id in ('$U1','$U2');
SQL
  if [ "$PAUSED" = 1 ]; then
    psql_ -c "select cron.alter_job((select jobid from cron.job where jobname = '$JOB'), active := true)" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for() { # seconds sql-returning-t
  local i
  for i in $(seq 1 "$1"); do
    [ "$(psql_ -c "$2")" = t ] && return 0
    sleep 1
  done
  return 1
}

echo "--- production job: registered once, owned by the intended role"
[ "$(psql_ -c "select count(*) from cron.job where jobname = '$JOB'")" = 1 ] || fail "expected exactly one $JOB job"
[ "$(psql_ -c "select active and schedule = '*/5 * * * *' and username = 'postgres' and database = current_database() and command = 'select public.reconcile_account_deletions()' from cron.job where jobname = '$JOB'")" = t ] \
  || fail "the job is not active / scheduled / owned as intended"
HERE=$(cd "$(dirname "$0")/../migrations" && pwd)
ID1=$(psql_ -c "select jobid from cron.job where jobname = '$JOB'")
psql_ -1 < "$HERE/20261107000002_account_reconciliation_schedule.sql" >/dev/null
[ "$(psql_ -c "select count(*) from cron.job where jobname = '$JOB'")" = 1 ] || fail "re-registration created a duplicate"
[ "$(psql_ -c "select jobid from cron.job where jobname = '$JOB'")" = "$ID1" ] || fail "re-registration replaced the job id"
echo "PASS: one active */5 job running as postgres; re-applying the registration keeps exactly one (job id $ID1)"

echo "--- clients cannot schedule or read scheduler data"
for R in authenticated anon service_role; do
  OUT=$(psql_ <<SQL 2>&1 || true
set role $R;
select cron.schedule('zz-evil', '* * * * *', 'select 1');
SQL
)
  echo "$OUT" | grep -qi "permission denied" || fail "$R could call cron.schedule: $OUT"
  OUT=$(psql_ <<SQL 2>&1 || true
set role $R;
select count(*) from cron.job_run_details;
SQL
)
  echo "$OUT" | grep -qi "permission denied" || fail "$R could read cron.job_run_details: $OUT"
done
[ "$(psql_ -c "select count(*) from cron.job where jobname = 'zz-evil'")" = 0 ] || fail "a client job was created"
echo "PASS: authenticated, anon and service_role are denied cron.schedule and the run history"

echo "--- autonomous run: nobody calls reconcile_account_deletions()"
psql_ -c "select cron.alter_job((select jobid from cron.job where jobname = '$JOB'), active := false)" >/dev/null
PAUSED=1
psql_ <<SQL >/dev/null
create table public.zz_cron_probe (n integer, at timestamptz default now());
insert into public.profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  values ('$U1','SCH-1','Real Name','deleting',now());
insert into public.households (id,name,created_by) values ('$H','SCH H','$U1');
insert into public.expenses (household_id,title,amount_cents,currency,paid_by,paid_by_display_name,created_by)
  values ('$H','Late',700,'EUR','$U1','Late Name','$U1');
select cron.schedule('account-deletion-reconcile-test', '5 seconds',
  'insert into public.zz_cron_probe (n) select public.reconcile_account_deletions()');
SQL
wait_for 45 "select account_state = 'deleted' from public.profiles where user_id = '$U1'" \
  || fail "the scheduler did not finalize the account within 45 seconds"
[ "$(psql_ -c "select paid_by_display_name from public.expenses where household_id = '$H'")" = "Deleted member" ] \
  || fail "the final scrub pass did not run"
[ "$(psql_ -c "select sum(n) from public.zz_cron_probe")" = 1 ] || fail "the scheduled run did not report exactly one account"
[ "$(psql_ -c "select count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'account-deletion-reconcile-test' and d.status = 'succeeded'")" -ge 1 ] \
  || fail "no successful run in the scheduler history"
echo "PASS: the scheduler finalized the account and ran the scrub pass by itself; history shows succeeded runs"

echo "--- registering the same job name again does not duplicate it"
psql_ -c "select cron.schedule('account-deletion-reconcile-test', '10 seconds', 'select 1')" >/dev/null
[ "$(psql_ -c "select count(*) from cron.job where jobname = 'account-deletion-reconcile-test'")" = 1 ] || fail "duplicate job"
psql_ -c "select cron.schedule('account-deletion-reconcile-test', '5 seconds', 'insert into public.zz_cron_probe (n) select public.reconcile_account_deletions()')" >/dev/null
echo "PASS: same name, one job"

echo "--- error reporting"
psql_ -c "select cron.schedule('account-deletion-reconcile-test-fail', '5 seconds', 'select 1/0')" >/dev/null
wait_for 40 "select exists (select 1 from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'account-deletion-reconcile-test-fail' and d.status = 'failed' and d.return_message ilike '%division by zero%')" \
  || fail "a failing job is not visible in the run history"
psql_ <<SQL >/dev/null
create function public.zz_fail_u2() returns trigger language plpgsql as \$f\$
begin
  if new.user_id = '$U2' and new.account_state = 'deleted' then
    raise exception 'boom' using errcode = 'XX555';
  end if;
  return new;
end \$f\$;
create trigger zz_fail_u2 before update on public.profiles for each row execute function public.zz_fail_u2();
insert into public.profiles (user_id,public_id,display_name,account_state,deletion_requested_at)
  values ('$U2','SCH-2','Two','deleting',now());
SQL
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 14
docker logs --since "$SINCE" "$DB_CONTAINER" 2>&1 | grep -q "account reconciliation failed for $U2 (sqlstate XX555)" \
  || fail "the per-account failure was not logged"
[ "$(psql_ -c "select account_state from public.profiles where user_id = '$U2'")" = deleting ] || fail "the failing account changed state"
[ "$(psql_ -c "select count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'account-deletion-reconcile-test' and d.status = 'succeeded' and d.start_time > '$SINCE'")" -ge 1 ] \
  || fail "scheduled runs stopped succeeding because of one failing account"
echo "PASS: failing job -> status 'failed' with message; a failing account -> logged WARNING (id + sqlstate), run still succeeds"

echo "--- overlapping runs are not started"
psql_ -c "select cron.unschedule('account-deletion-reconcile-test-fail')" >/dev/null
psql_ -c "select cron.schedule('account-deletion-reconcile-test-slow', '5 seconds', 'select pg_sleep(12)')" >/dev/null
sleep 40
OVER=$(psql_ -c "select count(*) from (select d.start_time, lag(d.end_time) over (order by d.start_time) prev_end from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'account-deletion-reconcile-test-slow') s where start_time < prev_end")
RUNS=$(psql_ -c "select count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'account-deletion-reconcile-test-slow' and d.end_time is not null")
echo "completed runs=$RUNS overlapping=$OVER"
[ "$RUNS" -ge 2 ] && [ "$OVER" = 0 ] || fail "runs overlapped or did not repeat"
echo "PASS: a 12 s job on a 5 s schedule never overlapped itself"

echo "--- teardown: test jobs removed, production job restored"
cleanup
PAUSED=0
[ "$(psql_ -c "select count(*) from cron.job where jobname like 'account-deletion-reconcile-test%'")" = 0 ] || fail "a test job remains"
[ "$(psql_ -c "select count(*) from cron.job where jobname = '$JOB' and active")" = 1 ] || fail "the production job was not restored"
[ "$(psql_ -c "select count(*) from public.profiles where user_id in ('$U1','$U2')")" = 0 ] || fail "a fixture profile remains"
[ "$(psql_ -c "select count(*) from public.households where id = '$H'")" = 0 ] || fail "the fixture household remains"
echo "PASS: no temporary job or fixture remains; exactly one active $JOB"
