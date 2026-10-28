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

echo "--- F1b: email-linked accounts need a fresh emailed code (real Auth + real Edge Function)"
MAIL_URL="${MAIL_URL:-http://127.0.0.1:55424}"
case "$MAIL_URL" in http://127.0.0.1:55424) ;; *) echo "refusing mail capture at $MAIL_URL" >&2; exit 2 ;; esac
# shellcheck source=lib_local_otp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_local_otp.sh"
if ! mail_available; then
  echo "SKIPPED: no mail capture at $MAIL_URL (needs the email-confirmation test config); the F1b cases below did NOT run"
  exit 0
fi
OTP_EXP=$(docker exec supabase_auth_hhsqltest env 2>/dev/null | sed -n 's/^GOTRUE_MAILER_OTP_EXP=//p')
body_of() { echo "$1" | sed '$d'; }
http_of() { echo "$1" | tail -1; }
state_of() { psql_ -c "select account_state from profiles where user_id = '$1'"; }
auth_rows() { psql_ -c "select count(*) from auth.users where id = '$1'"; }
auth_total() { psql_ -c "select count(*) from auth.users"; }
fresh_code() { # email -> a code issued just now
  clear_mail; sleep 1.5
  # Runs in a command substitution: report on stderr and exit, never print FAIL into a value.
  [ "$(send_code "$1")" = 200 ] || { echo "FAIL: could not request a code for $1" >&2; exit 1; }
  local c; c=$(code_for "$1"); [ ${#c} = 6 ] || { echo "FAIL: no code arrived for $1" >&2; exit 1; }
  echo "$c"
}
# Creates a confirmed email user with a profile; sets LID LEMAIL LTOKEN.
make_linked() { # tag
  LEMAIL="accint-$1-$$@example.test"
  LID=$(admin_create_user "$LEMAIL" "Accint-$$-pw-1"); [ -n "$LID" ] || fail "could not create linked user $1"
  USERS+=("$LID")
  LTOKEN=$(password_token "$LEMAIL" "Accint-$$-pw-1"); [ -n "$LTOKEN" ] || fail "linked user $1 cannot sign in"
  cx -s -o /dev/null -X POST "$API_URL/rest/v1/profiles" -H "apikey: $ANON" -H "Authorization: Bearer $LTOKEN" \
    -H "Content-Type: application/json" -d "{\"user_id\":\"$LID\",\"public_id\":\"INT-${LID:0:8}\",\"display_name\":\"Int $1\"}"
}

# Shared fixture: an anonymous owner, a bystander and one home.
read -r UO TO RO <<<"$(new_user)"; read -r UB TB RB <<<"$(new_user)"; USERS+=("$UO" "$UB")
HL=$(rest "$TO" POST rpc/create_household '{"p_name":"ACCINT L home"}' | jget "['id']")
[ -n "$HL" ] || fail "could not create the fixture home"
join_home() { # token -> joins HL
  local c; c=$(rest "$TO" POST rpc/create_household_invite "{\"p_household_id\":\"$HL\"}" | jget "['code']")
  rest "$1" POST rpc/join_household_by_invite "{\"p_code\":\"$c\"}" >/dev/null
}

echo "- no code, and forged request fields"
make_linked L1; L1=$LID; L1E=$LEMAIL; L1T=$LTOKEN
OUT=$(del_account "$L1T")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q reverification_required || fail "no code was not refused: $OUT"
OUT=$(del_account "$L1T" "{\"confirmation\":\"DELETE\",\"account_state\":\"deleting\",\"deleting\":true,\"verified\":true,\"user_id\":\"$UB\",\"email\":\"$L1E\"}")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q reverification_required || fail "forged fields changed the decision: $OUT"
[ "$(state_of "$L1")" = active ] && [ "$(state_of "$UB")" = active ] || fail "a refused request changed a profile"
pass "[real Auth+function] linked account without a code -> 403 reverification_required; forged state/user/email/verified fields are ignored; nothing changed"

echo "- wrong code, and the caller session survives"
C1=$(fresh_code "$L1E")
WRONG=$([ "$C1" = 000000 ] && echo 111111 || echo 000000)
OUT=$(del_account "$L1T" "{\"confirmation\":\"DELETE\",\"code\":\"$WRONG\"}")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q verification_failed || fail "a wrong code was not refused: $OUT"
OUT=$(del_account "$L1T" "{\"confirmation\":\"DELETE\",\"code\":\"12ab56\"}")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q verification_failed || fail "a malformed code was not refused: $OUT"
[ "$(state_of "$L1")" = active ] && [ "$(auth_rows "$L1")" = 1 ] || fail "a wrong code changed the account"
[ "$(cx -s -o /dev/null -w '%{http_code}' -H "apikey: $ANON" -H "Authorization: Bearer $L1T" "$API_URL/auth/v1/user")" = 200 ] || fail "the caller session was invalidated"
pass "[real Auth+function] wrong and malformed codes -> 403 verification_failed; account active; the caller session still works"

echo "- another user code"
make_linked L2; L2=$LID; L2E=$LEMAIL
C2=$(fresh_code "$L2E")
OUT=$(del_account "$L1T" "{\"confirmation\":\"DELETE\",\"code\":\"$C2\"}")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q verification_failed || fail "another user code was not refused: $OUT"
[ "$(state_of "$L1")" = active ] && [ "$(state_of "$L2")" = active ] || fail "a foreign code changed an account"
pass "[real Auth+function] a valid code issued to another user -> 403; both accounts untouched"

if [ "${OTP_EXP:-3600}" -le 60 ]; then
  echo "- expired code"
  make_linked L3; L3=$LID; L3E=$LEMAIL; L3T=$LTOKEN
  C3=$(fresh_code "$L3E"); sleep $((OTP_EXP + 3))
  OUT=$(del_account "$L3T" "{\"confirmation\":\"DELETE\",\"code\":\"$C3\"}")
  [ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q verification_failed || fail "an expired code was not refused: $OUT"
  [ "$(state_of "$L3")" = active ] || fail "an expired code changed the account"
  pass "[real Auth+function] a code older than otp_expiry (${OTP_EXP}s) -> 403; account active"
else
  echo "SKIPPED: expired-code case needs a short otp_expiry (stack has ${OTP_EXP:-unknown}s)"
fi

echo "- a code that was already used"
make_linked L4; L4=$LID; L4E=$LEMAIL; L4T=$LTOKEN
C4=$(fresh_code "$L4E")
[ "$(verify_status "$L4E" "$C4")" = 200 ] || fail "could not spend the code"
OUT=$(del_account "$L4T" "{\"confirmation\":\"DELETE\",\"code\":\"$C4\"}")
[ "$(http_of "$OUT")" = 403 ] && body_of "$OUT" | grep -q verification_failed || fail "a used code was not refused: $OUT"
[ "$(state_of "$L4")" = active ] || fail "a used code changed the account"
pass "[real Auth+function] a code verified earlier (sequentially) -> 403; account active"

echo "- owner: 409 before the code is spent"
make_linked L5; L5=$LID; L5E=$LEMAIL; L5T=$LTOKEN
rest "$L5T" POST rpc/create_household '{"p_name":"ACCINT L5 home"}' >/dev/null
C5=$(fresh_code "$L5E")
OUT=$(del_account "$L5T" "{\"confirmation\":\"DELETE\",\"code\":\"$C5\"}")
[ "$(http_of "$OUT")" = 409 ] && body_of "$OUT" | grep -q owns_households || fail "an owner was not refused with 409: $OUT"
[ "$(state_of "$L5")" = active ] || fail "the owner account changed"
[ "$(verify_status "$L5E" "$C5")" = 200 ] || fail "the code was consumed by a request that had to fail with 409"
pass "[real Auth+function] owner -> 409 owns_households; account active; the emailed code was NOT consumed"

echo "- valid code: the right account is deleted, history is preserved, nothing leaks"
make_linked L6; L6=$LID; L6E=$LEMAIL; L6T=$LTOKEN
join_home "$L6T"
rest "$L6T" POST rpc/create_equal_split_expense "{\"p_household_id\":\"$HL\",\"p_title\":\"L6 dinner\",\"p_amount_cents\":3000,\"p_currency\":\"EUR\",\"p_paid_by\":\"$L6\",\"p_participant_ids\":[\"$L6\",\"$UO\"]}" >/dev/null
EXP_BEFORE=$(psql_ -c "select string_agg(id::text || ':' || amount_cents::text, ',' order by id) from expenses where household_id = '$HL'")
TOTAL_BEFORE=$(auth_total)
C6=$(fresh_code "$L6E")
OUT=$(del_account "$L6T" "{\"confirmation\":\"DELETE\",\"code\":\"$C6\",\"user_id\":\"$UB\",\"email\":\"$L1E\"}")
[ "$(http_of "$OUT")" = 200 ] || fail "a valid code did not delete: $OUT"
[ "$(body_of "$OUT" | tr -d '[:space:]')" = '{"state":"deleted"}' ] || fail "the response carried more than the state"
body_of "$OUT" | grep -qi -e token -e session -e access -e refresh && fail "the response mentions a token or session"
[ "$(auth_rows "$L6")" = 0 ] && [ "$(state_of "$L6")" = deleted ] || fail "the caller was not deleted"
[ "$(auth_total)" = "$((TOTAL_BEFORE - 1))" ] || fail "more or fewer than one Auth user was removed"
[ "$(state_of "$UB")" = active ] && [ "$(state_of "$UO")" = active ] && [ "$(state_of "$L1")" = active ] || fail "an unrelated account changed (forged user_id/email used?)"
[ "$(psql_ -c "select string_agg(id::text || ':' || amount_cents::text, ',' order by id) from expenses where household_id = '$HL'")" = "$EXP_BEFORE" ] || fail "an expense changed"
[ "$(psql_ -c "select paid_by_display_name from expenses where title = 'L6 dinner'")" = "Deleted member" ] || fail "history was not anonymised"
[ "$(psql_ -c "select count(*) from household_members where user_id = '$L6' and status = 'active'")" = 0 ] || fail "memberships remain"
OUT=$(del_account "$L6T" "{\"confirmation\":\"DELETE\",\"code\":\"$C6\"}")
[ "$(http_of "$OUT")" = 401 ] || fail "the old JWT still passes the function check"
[ "$(rest "$L6T" GET "expenses?select=id" | jget ".__len__()")" = 0 ] || fail "the old JWT still reads expenses"
pass "[real Auth+function] valid code -> 200 {state:deleted} only; exactly the caller Auth user is gone; forged user_id/email ignored; unrelated accounts and expense amounts intact; old JWT is dead"

echo "- one valid code, three simultaneous requests"
make_linked L7; L7=$LID; L7E=$LEMAIL; L7T=$LTOKEN
join_home "$L7T"
rest "$L7T" POST rpc/create_equal_split_expense "{\"p_household_id\":\"$HL\",\"p_title\":\"L7 lunch\",\"p_amount_cents\":1800,\"p_currency\":\"EUR\",\"p_paid_by\":\"$L7\",\"p_participant_ids\":[\"$L7\",\"$UO\"]}" >/dev/null
EXP7=$(psql_ -c "select string_agg(id::text || ':' || amount_cents::text, ',' order by id) from expenses where household_id = '$HL'")
TOTAL7=$(auth_total)
C7=$(fresh_code "$L7E")
RACE=$(mktemp -d)
for i in 1 2 3; do
  (del_account "$L7T" "{\"confirmation\":\"DELETE\",\"code\":\"$C7\"}" > "$RACE/r$i" 2>&1) &
done
wait
OK=0; for i in 1 2 3; do [ "$(http_of "$(cat "$RACE/r$i")")" = 200 ] && OK=$((OK + 1)); done
SUMMARY=$(for i in 1 2 3; do http_of "$(cat "$RACE/r$i")"; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
echo "statuses: $SUMMARY"
STATE7=$(state_of "$L7"); AUTH7=$(auth_rows "$L7")
[ "$OK" -ge 1 ] || fail "no simultaneous request completed the deletion (state=$STATE7 auth=$AUTH7)"
[ "$STATE7" = deleted ] && [ "$AUTH7" = 0 ] || fail "a request reported success but the account is state=$STATE7 auth=$AUTH7"
[ "$(auth_total)" = "$((TOTAL7 - 1))" ] || fail "the simultaneous requests removed a different number of Auth users"
[ "$(state_of "$UB")" = active ] && [ "$(state_of "$UO")" = active ] || fail "a bystander changed"
[ "$(psql_ -c "select string_agg(id::text || ':' || amount_cents::text, ',' order by id) from expenses where household_id = '$HL'")" = "$EXP7" ] || fail "expenses changed or were duplicated"
[ "$(psql_ -c "select count(*) from expenses where title = 'L7 lunch'")" = 1 ] || fail "an expense was duplicated"
[ "$(psql_ -c "select count(*) from household_members where user_id = '$L7' and status = 'active'")" = 0 ] || fail "memberships remain"
[ "$(psql_ -c "select count(*) from profiles where user_id = '$L7'")" = 1 ] || fail "the tombstone was duplicated or lost"
rm -rf "$RACE"
pass "[real Auth+function] 3 simultaneous requests with one code ($OK succeeded): one account deleted, one Auth user removed, history intact and not duplicated, bystanders untouched, no success reported for a live account"

echo "- Auth deletion fails, then a retry WITHOUT a code"
make_linked L8; L8=$LID; L8E=$LEMAIL; L8T=$LTOKEN
psql_ <<SQL >/dev/null
create or replace function zz_block_auth_delete() returns trigger language plpgsql as \$f\$
begin raise exception 'blocked for test' using errcode = 'XX998'; end \$f\$;
create trigger zz_block_auth_delete before delete on auth.users for each row execute function zz_block_auth_delete();
SQL
C8=$(fresh_code "$L8E")
OUT=$(del_account "$L8T" "{\"confirmation\":\"DELETE\",\"code\":\"$C8\"}")
[ "$(http_of "$OUT")" = 502 ] && [ "$(state_of "$L8")" = deleting ] || fail "a failed Auth deletion was not left recoverable: $OUT"
psql_ -c "drop trigger zz_block_auth_delete on auth.users; drop function zz_block_auth_delete()" >/dev/null
OUT=$(del_account "$L8T")
[ "$(http_of "$OUT")" = 200 ] && [ "$(state_of "$L8")" = deleted ] && [ "$(auth_rows "$L8")" = 0 ] || fail "the resume without a code did not finish: $OUT"
pass "[real Auth+function] Auth deletion failure -> 502, profile 'deleting'; the retry without a code (already authorized) completes it"

echo "- a stolen JWT cannot start a deletion, with or without a forged deleting flag"
make_linked L9; L9=$LID; L9T=$LTOKEN
OUT=$(del_account "$L9T" "{\"confirmation\":\"DELETE\",\"account_state\":\"deleting\"}")
[ "$(http_of "$OUT")" = 403 ] && [ "$(state_of "$L9")" = active ] || fail "an active linked account was prepared without a code: $OUT"
OUT=$(del_account "$L9T" "{\"confirmation\":\"nope\",\"code\":\"123456\"}")
[ "$(http_of "$OUT")" = 400 ] || fail "the typed confirmation is no longer required"
pass "[real Auth+function] an active linked account needs a verified code whatever the body says; the typed phrase is still required"

echo "- finalization fails after the Auth user is gone; reconciliation closes it"
make_linked L10; L10=$LID; L10E=$LEMAIL; L10T=$LTOKEN
psql_ <<SQL >/dev/null
create or replace function zz_block_finalize() returns trigger language plpgsql as \$f\$
begin
  if new.account_state = 'deleted' then raise exception 'blocked for test' using errcode = 'XX997'; end if;
  return new;
end \$f\$;
create trigger zz_block_finalize before update on profiles for each row execute function zz_block_finalize();
SQL
C10=$(fresh_code "$L10E")
OUT=$(del_account "$L10T" "{\"confirmation\":\"DELETE\",\"code\":\"$C10\"}")
[ "$(http_of "$OUT")" = 502 ] && [ "$(state_of "$L10")" = deleting ] && [ "$(auth_rows "$L10")" = 0 ] || fail "finalize failure not left in the expected state: $OUT"
psql_ -c "drop trigger zz_block_finalize on profiles; drop function zz_block_finalize()" >/dev/null
N=$(cx -s -X POST "$API_URL/rest/v1/rpc/reconcile_account_deletions" -H "apikey: $ANON" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d '{}' | tr -d '[:space:]')
[ "$N" -ge 1 ] && [ "$(state_of "$L10")" = deleted ] || fail "reconciliation did not close the account (closed $N)"
[ "$(state_of "$L1")" = active ] || fail "reconciliation touched an active account"
pass "[real Auth+function] finalize failure -> 502, Auth user gone; trusted reconciliation closes exactly the orphaned account"
