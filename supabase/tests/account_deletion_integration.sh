#!/usr/bin/env bash
# Local end-to-end test of account deletion (F7B): real Supabase Auth users,
# the real delete-account Edge Function and the real database.
#
# Usage (isolated local stack only; the Edge Function must be served, e.g.
# `supabase functions serve delete-account` in the local project):
#   SB_WORKDIR=<local supabase project dir> DB_CONTAINER=supabase_db_hhsqltest \
#     bash supabase/tests/account_deletion_integration.sh
#
# If the pg_cron job account-deletion-reconcile is active, pause it first (see
# account_reconciliation_scheduler.sh): it could finalize the orphaned account
# before the manual reconciliation step below.
#
# It creates DISPOSABLE anonymous users, never touches existing accounts, and
# removes everything it created. It refuses to run unless the database
# container name contains "hhsqltest" and the API URL is a loopback address.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
: "${SB_WORKDIR:?set SB_WORKDIR to the local supabase project directory}"

ENV_DUMP=$(cd "$SB_WORKDIR" && supabase status -o env 2>/dev/null)
ANON=$(echo "$ENV_DUMP" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
SERVICE=$(echo "$ENV_DUMP" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
# All HTTP goes through the local database container, straight to the local
# Kong gateway on the isolated Docker network (no host port needed).
API_URL="http://supabase_kong_${DB_CONTAINER#supabase_db_}:8000"
case "$API_URL" in
  http://supabase_kong_*hhsqltest*:8000) ;;
  *) echo "refusing to run against $API_URL" >&2; exit 2 ;;
esac
export MSYS_NO_PATHCONV=1
[ -n "$ANON" ] && [ -n "$SERVICE" ] || { echo "missing local keys" >&2; exit 2; }

cx() { docker exec -i "$DB_CONTAINER" curl "$@"; }
psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
jget() { python -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

USERS=()
cleanup() {
  for H in $(psql_ -c "select id from households where name like 'ACCINT %'" 2>/dev/null); do
    OWNER=$(psql_ -c "select user_id from household_members where household_id = '$H' and role = 'owner' and status = 'active' limit 1")
    [ -n "$OWNER" ] && psql_ <<SQL >/dev/null 2>&1 || true
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$OWNER","role":"authenticated"}', true);
select delete_household('$H');
commit;
SQL
  done
  psql_ -c "drop trigger if exists zz_block_auth_delete on auth.users" >/dev/null 2>&1 || true
  for U in "${USERS[@]}"; do
    psql_ <<SQL >/dev/null 2>&1 || true
delete from household_members where user_id = '$U';
delete from household_membership_periods where user_id = '$U';
delete from financial_operations where actor_id = '$U';
delete from profiles where user_id = '$U';
delete from auth.users where id = '$U';
SQL
  done
}
trap cleanup EXIT

new_user() { # prints "id token refresh"
  local resp
  resp=$(cx -s -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{}')
  local id token refresh
  id=$(echo "$resp" | jget "['user']['id']")
  token=$(echo "$resp" | jget "['access_token']")
  refresh=$(echo "$resp" | jget "['refresh_token']")
  [ -n "$id" ] && [ -n "$token" ] || fail "anonymous sign-in failed"
  USERS+=("$id")
  cx -s -o /dev/null -X POST "$API_URL/rest/v1/profiles" -H "apikey: $ANON" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -d "{\"user_id\":\"$id\",\"public_id\":\"INT-${id:0:8}\",\"display_name\":\"Int ${id:0:4}\"}"
  echo "$id $token $refresh"
}
rest() { # token method path [body]
  cx -s -X "$2" "$API_URL/rest/v1/$3" -H "apikey: $ANON" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" ${4:+-d "$4"}
}
del_account() { # token [body]
  cx -s -w '\n%{http_code}' -X POST "$API_URL/functions/v1/delete-account" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "${2:-{\"confirmation\":\"DELETE\"\}}"
}

read -r U1 T1 R1 <<<"$(new_user)"
read -r U2 T2 R2 <<<"$(new_user)"
read -r U3 T3 R3 <<<"$(new_user)"
# new_user runs in a subshell, so register the ids for cleanup here.
USERS+=("$U1" "$U2" "$U3")

H=$(rest "$T2" POST rpc/create_household '{"p_name":"ACCINT 1"}' | jget "['id']")
CODE=$(rest "$T2" POST rpc/create_household_invite "{\"p_household_id\":\"$H\"}" | jget "['code']")
rest "$T1" POST rpc/join_household_by_invite "{\"p_code\":\"$CODE\"}" >/dev/null
rest "$T1" POST rpc/create_equal_split_expense "{\"p_household_id\":\"$H\",\"p_title\":\"Int dinner\",\"p_amount_cents\":3000,\"p_currency\":\"EUR\",\"p_paid_by\":\"$U1\",\"p_participant_ids\":[\"$U1\",\"$U2\"]}" >/dev/null
[ "$(psql_ -c "select count(*) from expenses where household_id = '$H'")" = 1 ] || fail "fixture expense was not created"
BAL_BEFORE=$(psql_ -c "select string_agg(paid_by::text || amount_cents, ',') from expenses where household_id = '$H'")

echo "--- request validation"
OUT=$(cx -s -w '\n%{http_code}' -X POST "$API_URL/functions/v1/delete-account" -H "Content-Type: application/json" -d '{"confirmation":"DELETE"}')
[ "$(echo "$OUT" | tail -1)" = 401 ] || fail "a request without credentials was not refused"
OUT=$(del_account "$T1" '{"confirmation":"nope"}')
[ "$(echo "$OUT" | tail -1)" = 400 ] || fail "a wrong confirmation phrase was accepted"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U1'")" = active ] || fail "state changed on a refused request"
pass "no credentials -> 401, wrong phrase -> 400, nothing changed"

echo "--- the database step cannot be reached around the Edge Function"
OUT=$(rest "$T3" POST rpc/begin_account_deletion '{}')
echo "$OUT" | grep -q PGRST202 || fail "the removed zero-argument RPC is still reachable: $OUT"
OUT=$(rest "$T3" POST rpc/begin_account_deletion "{\"p_user_id\":\"$U3\"}")
echo "$OUT" | grep -q -i -e "permission denied" -e "42501" || fail "a signed-in user could call begin_account_deletion: $OUT"
OUT=$(rest "$T3" POST rpc/begin_account_deletion "{\"p_user_id\":\"$U2\"}")
echo "$OUT" | grep -q -i -e "permission denied" -e "42501" || fail "a signed-in user could target another account: $OUT"
OUT=$(rest "$ANON" POST rpc/begin_account_deletion "{\"p_user_id\":\"$U3\"}")
echo "$OUT" | grep -q -i -e "permission denied" -e "42501" || fail "anon could call begin_account_deletion: $OUT"
[ "$(psql_ -c "select count(*) from profiles where user_id in ('$U1','$U2','$U3') and account_state = 'active'")" = 3 ] \
  || fail "a refused direct call changed an account"
pass "old RPC is gone; new RPC is refused for authenticated and anon (own and foreign id); nothing changed"

echo "--- blocker: owners must hand over or delete their homes first"
OUT=$(del_account "$T2")
[ "$(echo "$OUT" | tail -1)" = 409 ] || fail "an owner was allowed to delete"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U2'")" = active ] || fail "owner state changed"
[ "$(cx -s -o /dev/null -w '%{http_code}' -H "apikey: $ANON" -H "Authorization: Bearer $T2" "$API_URL/auth/v1/user")" = 200 ] || fail "owner Auth user vanished"
pass "owner of a household is blocked with 409 and keeps a working account"

echo "--- Auth deletion fails: recoverable state"
psql_ <<SQL >/dev/null
create or replace function zz_block_auth_delete() returns trigger language plpgsql as \$f\$
begin raise exception 'blocked for test' using errcode = 'XX998'; end \$f\$;
create trigger zz_block_auth_delete before delete on auth.users for each row execute function zz_block_auth_delete();
SQL
OUT=$(del_account "$T1")
CODE_HTTP=$(echo "$OUT" | tail -1)
STATE=$(psql_ -c "select account_state from profiles where user_id = '$U1'")
echo "http=$CODE_HTTP state=$STATE"
[ "$CODE_HTTP" = 502 ] && [ "$STATE" = deleting ] || fail "a failed Auth deletion was not reported as recoverable"
MEM=$(psql_ -c "select count(*) from household_members where user_id = '$U1' and status = 'active'")
[ "$MEM" = 0 ] || fail "memberships still active while deleting"
[ "$(rest "$T1" GET "expenses?select=id" | jget ".__len__()")" = 0 ] || fail "a deleting account can still read expenses"
[ "$(rest "$T1" POST rpc/create_household '{"p_name":"ACCINT X"}' | grep -c AD003)" = 1 ] || fail "a deleting account can create a household"
pass "Auth failure -> 502, profile stays 'deleting', household access already revoked"

echo "--- retry completes the workflow"
psql_ -c "drop trigger zz_block_auth_delete on auth.users; drop function zz_block_auth_delete()" >/dev/null
OUT=$(del_account "$T1")
echo "$OUT" | tail -2 | tr '\n' ' '; echo
[ "$(echo "$OUT" | tail -1)" = 200 ] || fail "the retry did not succeed"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U1'")" = deleted ] || fail "profile not marked deleted"
[ "$(psql_ -c "select count(*) from auth.users where id = '$U1'")" = 0 ] || fail "Auth user still exists"
pass "retry deleted the Auth user and finalized the tombstone"

echo "--- the old credentials are useless"
[ "$(cx -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/token?grant_type=refresh_token" -H "apikey: $ANON" -H "Content-Type: application/json" -d "{\"refresh_token\":\"$R1\"}")" != 200 ] || fail "refresh token still works"
OUT=$(del_account "$T1"); [ "$(echo "$OUT" | tail -1)" = 401 ] || fail "the old JWT still passes the function check"
[ "$(rest "$T1" GET "expenses?select=id" | jget ".__len__()")" = 0 ] || fail "the old JWT still reads expenses"
[ "$(rest "$T1" POST rpc/create_household '{"p_name":"ACCINT Y"}' | grep -c -e AD003 -e HO000 -e 42501)" -ge 1 ] || fail "the old JWT can still create a household"
pass "refresh fails, the function rejects the old JWT, and the old JWT reaches no data"

echo "--- the other member is unaffected"
AFTER=$(psql_ -c "select string_agg(paid_by::text || amount_cents, ',') from expenses where household_id = '$H'")
[ "$AFTER" = "$BAL_BEFORE" ] || fail "financial rows changed"
[ "$(rest "$T2" GET "expenses?select=paid_by_display_name" | jget "[0]['paid_by_display_name']")" = "Deleted member" ] || fail "name not scrubbed for the other member's view"
[ "$(cx -s -o /dev/null -w '%{http_code}' -H "apikey: $ANON" -H "Authorization: Bearer $T2" "$API_URL/auth/v1/user")" = 200 ] || fail "the other user's account was affected"
[ "$(psql_ -c "select count(*) from auth.users where id in ('$U2','$U3')")" = 2 ] || fail "other Auth users were affected"
pass "the other member keeps the household, the unchanged expense and a working account"

echo "--- the function only ever deletes the caller, whatever the body says"
read -r U5 T5 R5 <<<"$(new_user)"
USERS+=("$U5")
OUT=$(del_account "$T5" "{\"confirmation\":\"DELETE\",\"user_id\":\"$U3\",\"target\":\"$U3\"}")
[ "$(echo "$OUT" | tail -1)" = 200 ] || fail "a self-deletion with extra body fields failed"
[ "$(psql_ -c "select count(*) from auth.users where id = '$U3'")" = 1 ] || fail "another user's Auth account was deleted"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U3'")" = active ] || fail "another user's profile changed"
[ "$(psql_ -c "select count(*) from auth.users where id = '$U5'")" = 0 ] || fail "the caller was not deleted"
pass "only the caller's account was deleted; the id in the body was ignored"

echo "--- Auth user deleted but finalization failed"
read -r U4 T4 R4 <<<"$(new_user)"
USERS+=("$U4")
CODE=$(rest "$T2" POST rpc/create_household_invite "{\"p_household_id\":\"$H\"}" | jget "['code']")
rest "$T4" POST rpc/join_household_by_invite "{\"p_code\":\"$CODE\"}" >/dev/null
rest "$T4" POST rpc/create_equal_split_expense "{\"p_household_id\":\"$H\",\"p_title\":\"U4 lunch\",\"p_amount_cents\":800,\"p_currency\":\"EUR\",\"p_paid_by\":\"$U4\",\"p_participant_ids\":[\"$U4\",\"$U2\"]}" >/dev/null
psql_ <<SQL >/dev/null
create or replace function zz_block_finalize() returns trigger language plpgsql as \$f\$
begin
  if new.account_state = 'deleted' then raise exception 'blocked for test' using errcode = 'XX997'; end if;
  return new;
end \$f\$;
create trigger zz_block_finalize before update on profiles for each row execute function zz_block_finalize();
SQL
OUT=$(del_account "$T4")
HTTP=$(echo "$OUT" | tail -1)
STATE=$(psql_ -c "select account_state from profiles where user_id = '$U4'")
AUTHROWS=$(psql_ -c "select count(*) from auth.users where id = '$U4'")
echo "http=$HTTP state=$STATE auth_rows=$AUTHROWS"
[ "$HTTP" = 502 ] && [ "$STATE" = deleting ] && [ "$AUTHROWS" = 0 ] || fail "the finalize failure did not leave the expected state"
[ "$(psql_ -c "select paid_by_display_name from expenses where title = 'U4 lunch'")" = "Deleted member" ] || fail "personal data was not scrubbed before the failure"
[ "$(rest "$T4" GET "expenses?select=id" | jget ".__len__()")" = 0 ] || fail "the half-deleted account can still read data"
OUT=$(del_account "$T4"); [ "$(echo "$OUT" | tail -1)" = 401 ] || fail "the user could retry with a deleted Auth identity"
pass "Auth user gone, finalize failed: profile stays 'deleting', data already scrubbed and unreachable, the user cannot retry"

echo "--- reconciliation is a trusted-only operation"
psql_ -c "drop trigger zz_block_finalize on profiles; drop function zz_block_finalize()" >/dev/null
OUT=$(rest "$T2" POST rpc/reconcile_account_deletions '{}')
echo "$OUT" | grep -q -i -e "permission denied" -e "42501" || fail "a signed-in user could call reconcile"
OUT=$(rest "$ANON" POST rpc/reconcile_account_deletions '{}')
echo "$OUT" | grep -q -i -e "permission denied" -e "42501" || fail "anon could call reconcile"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U4'")" = deleting ] || fail "client calls changed the state"
N=$(cx -s -X POST "$API_URL/rest/v1/rpc/reconcile_account_deletions" -H "apikey: $ANON" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d '{}' | tr -d '[:space:]')
[ "$N" = 1 ] || fail "service-role reconciliation closed $N accounts instead of 1"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U4'")" = deleted ] || fail "reconciliation did not finish the account"
N=$(cx -s -X POST "$API_URL/rest/v1/rpc/reconcile_account_deletions" -H "apikey: $ANON" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d '{}' | tr -d '[:space:]')
[ "$N" = 0 ] || fail "a repeated reconciliation changed $N accounts"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U2'")" = active ] || fail "reconciliation touched an active user"
pass "only the service role can reconcile; it closed exactly the orphaned account, repeatably, and no one else"

echo "--- email-linked accounts are refused until reauthentication exists (F1b)"
LMAIL="accint-linked-$$@example.test"
LRESP=$(cx -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" \
  -H "Content-Type: application/json" -d "{\"email\":\"$LMAIL\",\"password\":\"Accint-$$-pw-1\",\"email_confirm\":true}")
U5=$(echo "$LRESP" | jget "['id']")
[ -n "$U5" ] || fail "could not create the confirmed email user"
USERS+=("$U5")
TOK5=$(cx -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$LMAIL\",\"password\":\"Accint-$$-pw-1\"}" | jget "['access_token']")
[ -n "$TOK5" ] || fail "the email user could not sign in"
cx -s -o /dev/null -X POST "$API_URL/rest/v1/profiles" -H "apikey: $ANON" -H "Authorization: Bearer $TOK5" \
  -H "Content-Type: application/json" -d "{\"user_id\":\"$U5\",\"public_id\":\"INT-${U5:0:8}\",\"display_name\":\"Int linked\"}"
OUT=$(del_account "$TOK5")
[ "$(echo "$OUT" | tail -1)" = 403 ] && echo "$OUT" | grep -q reverification_required || fail "a linked account was not refused: $OUT"
[ "$(psql_ -c "select account_state from profiles where user_id = '$U5'")" = active ] || fail "the refused request changed the profile"
[ "$(psql_ -c "select count(*) from auth.users where id = '$U5'")" = 1 ] || fail "the linked Auth user was removed"
pass "linked account -> 403 reverification_required; profile still active, Auth user intact"
