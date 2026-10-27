#!/usr/bin/env bash
# Two-session concurrency test for financial operation idempotency (F13).
#
# Usage (local test database only):
#   DB_CONTAINER=supabase_db_hhsqltest bash supabase/tests/financial_idempotency_concurrency.sh
#
# Sequential calls in one transaction cannot prove concurrency safety, so this
# opens real parallel psql sessions with committed disposable data and removes
# that data afterwards. It refuses to run unless the container name contains
# "hhsqltest", so it can never target the old HouseHold stack.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac

psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }

A='f6000000-0000-0000-0000-00000000000a'
B='f6000000-0000-0000-0000-00000000000b'
KEY_EXP='bbbbbbbb-0000-4000-8000-000000000001'
KEY_SET='bbbbbbbb-0000-4000-8000-000000000002'
CLAIMS="{\"sub\":\"$A\",\"role\":\"authenticated\"}"

cleanup() {
  psql_ <<SQL >/dev/null
begin;
delete from expense_settlements where household_id in (select id from households where name = 'IDEM CONC');
delete from expenses where household_id in (select id from households where name = 'IDEM CONC');
delete from tasks where household_id in (select id from households where name = 'IDEM CONC');
alter table financial_archive disable trigger user;
delete from financial_archive where household_id in (select id from households where name = 'IDEM CONC');
alter table financial_archive enable trigger user;
delete from household_events where household_id in (select id from households where name = 'IDEM CONC');
delete from financial_operations where actor_id in ('$A','$B');
delete from households where name = 'IDEM CONC';
delete from profiles where user_id in ('$A','$B');
delete from auth.users where id in ('$A','$B');
commit;
SQL
}
trap cleanup EXIT

psql_ <<SQL >/dev/null
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous) values
 ('$A','conc1@test.local','authenticated','authenticated',now(),now(),true),
 ('$B','conc2@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values ('$A','CONC-1','Conc1'),('$B','CONC-2','Conc2');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true);
select create_household('IDEM CONC');
commit;
SQL
H=$(psql_ -c "select id from households where name = 'IDEM CONC'")
echo "household: $H"

CALL_EXP="select create_equal_split_expense('$H','Concurrent',2500,'EUR','$A',array['$A']::uuid[],'$KEY_EXP')"

echo "--- test 1: session B arrives while session A still holds its transaction open"
(
  psql_ <<SQL > /tmp/idem_a.out
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
$CALL_EXP;
select pg_sleep(4) \g /dev/null
commit;
SQL
) &
PID_A=$!
sleep 1.5
START=$(date +%s)
psql_ <<SQL > /tmp/idem_b.out
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
$CALL_EXP;
commit;
SQL
END=$(date +%s)
wait $PID_A
ID_A=$(grep -E '^[0-9a-f-]{36}$' /tmp/idem_a.out | head -1)
ID_B=$(grep -E '^[0-9a-f-]{36}$' /tmp/idem_b.out | head -1)
ROWS=$(psql_ -c "select count(*) from expenses where household_id = '$H' and title = 'Concurrent'")
OPS=$(psql_ -c "select count(*) from financial_operations where actor_id = '$A' and request_id = '$KEY_EXP'")
echo "A=$ID_A B=$ID_B waited=$((END-START))s expenses=$ROWS operations=$OPS"
[ "$ID_A" = "$ID_B" ] && [ -n "$ID_A" ] && [ "$ROWS" = 1 ] && [ "$OPS" = 1 ] && [ $((END-START)) -ge 2 ] \
  || { echo "FAIL: concurrent expense request was not serialized to one record"; exit 1; }
echo "PASS: second session waited for the first and returned the same expense"

echo "--- test 2: eight simultaneous settlement requests with the same key"
psql_ <<SQL >/dev/null
insert into household_members (household_id,user_id,role,status) values ('$H','$B','member','active') on conflict do nothing;
insert into household_membership_periods (household_id,user_id) values ('$H','$B') on conflict do nothing;
SQL
rm -f /tmp/idem_s?.out
for i in 1 2 3 4 5 6 7 8; do
  (
    psql_ <<SQL > "/tmp/idem_s$i.out"
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true) \g /dev/null
select (create_settlement('$H','$A','$B',700,'EUR','race','$KEY_SET')).id;
commit;
SQL
  ) &
done
wait
IDS=$(cat /tmp/idem_s?.out | grep -E '^[0-9a-f-]{36}$' | sort -u | wc -l)
SROWS=$(psql_ -c "select count(*) from expense_settlements where household_id = '$H' and amount_cents = 700")
SOPS=$(psql_ -c "select count(*) from financial_operations where actor_id = '$A' and request_id = '$KEY_SET'")
echo "distinct ids returned=$IDS settlements=$SROWS operations=$SOPS"
[ "$IDS" = 1 ] && [ "$SROWS" = 1 ] && [ "$SOPS" = 1 ] \
  || { echo "FAIL: parallel settlement requests created more than one record"; exit 1; }
echo "PASS: eight parallel requests produced one settlement"
