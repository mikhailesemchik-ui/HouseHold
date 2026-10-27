#!/usr/bin/env bash
# Two-session concurrency test for financial cancellations (F4).
#
# Usage (local test database only):
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/financial_cancellation_concurrency.sh
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

A='f6100000-0000-0000-0000-00000000000a'
CLAIMS="{\"sub\":\"$A\",\"role\":\"authenticated\"}"

cleanup() {
  psql_ <<SQL >/dev/null
begin;
alter table financial_archive disable trigger user;
delete from financial_archive where household_id in (select id from households where name = 'CANCEL CONC');
alter table financial_archive enable trigger user;
delete from household_events where household_id in (select id from households where name = 'CANCEL CONC');
delete from expense_settlements where household_id in (select id from households where name = 'CANCEL CONC');
delete from expenses where household_id in (select id from households where name = 'CANCEL CONC');
delete from financial_operations where actor_id = '$A';
delete from households where name = 'CANCEL CONC';
delete from profiles where user_id = '$A';
delete from auth.users where id = '$A';
commit;
SQL
}
trap cleanup EXIT

psql_ <<SQL >/dev/null
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','cancelconc@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values ('$A','CCNC-1','CancelConc');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true);
select create_household('CANCEL CONC');
commit;
SQL
H=$(psql_ -c "select id from households where name = 'CANCEL CONC'")

E=$(psql_ <<SQL | grep -E '^[0-9a-f-]{36}$' | head -1
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
select create_equal_split_expense('$H','Race',1234,'EUR','$A',array['$A']::uuid[]);
commit;
SQL
)
echo "expense: $E"

rm -f /tmp/cancel_?.out
for i in 1 2 3 4 5 6; do
  (
    psql_ <<SQL > "/tmp/cancel_$i.out"
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
select (cancel_expense('$E', 'reason $i')).id;
commit;
SQL
  ) &
done
# A direct DELETE racing the RPCs must not create a second archive row either.
psql_ <<SQL >/dev/null || true
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
delete from expenses where id = '$E';
commit;
SQL
wait

IDS=$(cat /tmp/cancel_?.out | grep -E '^[0-9a-f-]{36}$' | sort -u | wc -l)
ROWS=$(psql_ -c "select count(*) from financial_archive where kind = 'expense' and record_id = '$E'")
LIVE=$(psql_ -c "select count(*) from expenses where id = '$E'")
EVENTS=$(psql_ -c "select count(*) from household_events where entity_id = '$E' and event_type = 'expense_deleted'")
echo "distinct archive ids=$IDS archive rows=$ROWS live rows=$LIVE delete events=$EVENTS"
[ "$ROWS" = 1 ] && [ "$LIVE" = 0 ] && [ "$EVENTS" = 1 ] && [ "$IDS" -le 1 ] \
  || { echo "FAIL: concurrent cancellations produced more than one archive record"; exit 1; }
echo "PASS: concurrent cancellations produced exactly one archive entry"
